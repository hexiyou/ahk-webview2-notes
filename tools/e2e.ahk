#Requires AutoHotkey v2.0
#ErrorStdOut UTF-8
; 端到端：真窗口 + 真 WebView2 + 真 SQLite，走一遍"输入→防抖→落库→切模式→改色→几何→重开"。
#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_e2e.log"
    static Log(m) => FileAppend(m "`n", App.LogPath, "UTF-8-RAW")
    static Toast(t) => App.Log("toast: " t)
    static NewNote() => 0
    static ShowList() => 0
    static RefreshTray() => 0
    static OpenExternal(u) => 0
}

global PassN := 0, FailN := 0

Check(name, cond, detail := "") {
    global PassN, FailN
    if cond {
        PassN++
        App.Log("PASS  " name (detail != "" ? "  [" detail "]" : ""))
    } else {
        FailN++
        App.Log("FAIL  " name (detail != "" ? "  [" detail "]" : ""))
    }
}

if FileExist(App.LogPath)
    FileDelete App.LogPath

try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

dataDir := A_ScriptDir "\..\data"
for f in [dataDir "\_e2e.db", dataDir "\_e2e.db-wal", dataDir "\_e2e.db-shm"]
    if FileExist(f)
        FileDelete f

st := Store(dataDir "\_e2e.db")
NoteWindow.Store := st
NoteWindow.Ctx := {
    uiDir: A_ScriptDir "\..\ui",
    dllPath: A_ScriptDir "\..\lib\WebView2Loader.dll",
    dataDir: dataDir "\webview2",
    devtools: 0,
    appearance: { transparent: 1, fontSize: 15, drag: "native" }
}

id := st.Create(Map("x", 240, "y", 180, "w", 340, "h", 320))
n := st.Get(id)
App.Log("=== e2e 开始，id=" id)

w := NoteWindow(n)
Sleep 1800

; ---- 1. 页面就绪 ----
Check("页面就绪", w.ready = 1)

; ---- 2. 输入 -> 防抖 -> 落库 ----
w.wv.ExecuteScript("document.getElementById('editor').innerHTML='<p>端到端 <b>测试</b> 正文</p>';document.getElementById('editor').dispatchEvent(new Event('input',{bubbles:true}));1")
Sleep 1000

row := st.Get(id)
Check("正文已落库(html)", InStr(row.body_html, "端到端") > 0, SubStr(row.body_html, 1, 60))
Check("正文已落库(text)", InStr(row.body_text, "端到端") > 0)
Check("md 已生成", InStr(row.body_md, "**测试**") > 0, SubStr(row.body_md, 1, 60))
Check("标题自动提取", row.title = "端到端 测试 正文", "title=" row.title)

; ---- 3. 切 Markdown 源码 ----
w.wv.ExecuteScript("document.getElementById('btnMd').click();1")
Sleep 900
row := st.Get(id)
Check("切到 md 模式", row.mode = "md", "mode=" row.mode)
srcval := w.wv.ExecuteScript("document.getElementById('source').value")
Check("md 源码有内容", InStr(srcval, "端到端") > 0, SubStr(srcval, 1, 60))

; ---- 4. 在源码里改字，确认 html 同步重算 ----
w.wv.ExecuteScript("var s=document.getElementById('source');s.value='# 新标题\n\n- [x] 做完了\n- [ ] 还没做';s.dispatchEvent(new Event('input',{bubbles:true}));1")
Sleep 900
row := st.Get(id)
Check("md 模式正文更新", InStr(row.body_md, "新标题") > 0)
Check("md 转 html 生效", InStr(row.body_html, "<h1>") > 0, SubStr(row.body_html, 1, 80))
Check("任务列表渲染", InStr(row.body_html, 'data-checked="1"') > 0)
Check("标题跟随 md", row.title = "新标题", "title=" row.title)

; ---- 5. 切回富文本 ----
w.wv.ExecuteScript("document.getElementById('btnMd').click();1")
Sleep 900
row := st.Get(id)
Check("切回 rich", row.mode = "rich", "mode=" row.mode)
h1 := w.wv.ExecuteScript("document.querySelectorAll('#editor h1').length")
Check("富文本里有 h1", h1 = "1", "count=" h1)

; ---- 6. 置顶 / 颜色 ----
w.DoPin(1)
Sleep 150
Check("置顶落库", st.Get(id).pinned = 1)
ex := WinGetExStyle("ahk_id " w.gui.Hwnd)
Check("WS_EX_TOPMOST 已加", (ex & 0x8) != 0, Format("{:#x}", ex))

w.DoColor("blue")
Sleep 150
Check("颜色落库", st.Get(id).color = "blue", "color=" st.Get(id).color)
Check("页面颜色同步", w.wv.ExecuteScript("document.body.dataset.color") = '"blue"')

; ---- 7. 几何：移动窗口后写回 ----
WinMove(300, 220, 400, 360, "ahk_id " w.gui.Hwnd)
Sleep 200
w.SaveGeometryNow()
g := st.Get(id)
Check("几何写回", g.x = 300 && g.y = 220 && g.w = 400 && g.h = 360
    , g.x "," g.y "," g.w "," g.h)

; ---- 8. 收起 / 再显示 ----
hwnd := w.gui.Hwnd
w.Hide()
Sleep 200
Check("收起后 hidden=1", st.Get(id).hidden = 1)
Check("收起后窗口不可见", !DllCall("user32\IsWindowVisible", "ptr", hwnd))
w.Show()
Sleep 300
Check("再显示 hidden=0", st.Get(id).hidden = 0)

; ---- 9. 销毁 ----
w.Destroy()
Sleep 400
Check("销毁后从 All 移除", !NoteWindow.All.Has(id))
Check("销毁后窗口已不存在", !DllCall("user32\IsWindow", "ptr", hwnd))

; ---- 10. 重开读回 ----
w2 := NoteWindow(st.Get(id))
Sleep 1600
Check("重开后 ready", w2.ready = 1)
body := w2.wv.ExecuteScript("document.getElementById('editor').innerText")
Check("重开后内容还原", InStr(body, "新标题") > 0, SubStr(body, 1, 80))
col := w2.wv.ExecuteScript("document.body.dataset.color")
Check("重开后颜色还原", col = '"blue"', col)
w2.Destroy()

st.Close()
App.Log("=== 结束：PASS " PassN " / FAIL " FailN)
ExitApp
