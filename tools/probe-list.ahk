#Requires AutoHotkey v2.0
#ErrorStdOut UTF-8
#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk
#Include ..\lib\list-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_list.log"
    static Log(m) => FileAppend(m "`n", App.LogPath, "UTF-8-RAW")
    static Toast(t) => 0
    static NewNote() => 0
    static ShowList() => 0
    static ZoomFont(step) => 0
    static RenameNote(id) => 0
    static ExportNote(id, fmt) => 0
    static SaveImage(raw, id) => 0
    static SetFontSize(px) => 0
    static RefreshTray() => 0
    static OpenExternal(u) => 0
    ; 列表窗口要读/写 config.ini（置顶偏好），测试里用内存版的够用了
    static CfgStore := Map()
    static Cfg(sec, key, def) {
        k := sec "." key
        return App.CfgStore.Has(k) ? App.CfgStore[k] : def
    }
    static SetCfg(sec, key, val) => App.CfgStore[sec "." key] := val
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
for f in [dataDir "\_list.db", dataDir "\_list.db-wal", dataDir "\_list.db-shm"]
    if FileExist(f)
        FileDelete f

st := Store(dataDir "\_list.db")
id1 := st.Create(Map("title", "买菜", "body_text", "鸡蛋 牛奶 面包", "color", "yellow"))
id2 := st.Create(Map("title", "工作周报", "body_text", "本周完成了搜索功能", "color", "blue", "pinned", 1))
id3 := st.Create(Map("title", "已收起的", "body_text", "后台维护任务", "color", "gray", "hidden", 1))
App.Log("=== probe-list 开始，三条 id=" id1 "," id2 "," id3)

openId := 0
ListWindow.Store := st
ListWindow.Ctx := {
    uiDir: A_ScriptDir "\..\ui",
    dllPath: A_ScriptDir "\..\lib\WebView2Loader.dll",
    dataDir: dataDir "\webview2",
    imagesDir: dataDir "\images",
    devtools: 0,
    appearance: { transparent: 0, fontSize: 15, drag: "native" }
}
ListWindow.Hooks := Map(
    "onNew", NoteHookNew,
    "onOpen", NoteHookOpen,
    "onDelete", NoteHookDelete,
    "onHide", NoteHookHide,
    "onClose", NoteHookClose)
NoteHookNew() => App.Log("hook:new")
NoteHookClose() => App.Log("hook:close")
NoteHookOpen(id) {
    global openId
    openId := id
    App.Log("hook:open " id)
}
NoteHookDelete(id) => App.Log("hook:delete " id)
NoteHookHide(id) => App.Log("hook:hide " id)

ListWindow.Open()
App.Log("Open 返回，Win=" (ListWindow.Win ? "ok" : "null"))
Sleep 1600
App.Log("等待结束，Win=" (ListWindow.Win ? "ok" : "null"))

if !ListWindow.Win {
    App.Log("Win 为空，中止")
    ExitApp
}
cnt := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("列表渲染 3 条", cnt = "3", "count=" cnt)

first := ListWindow.Win.wv.ExecuteScript("document.querySelector('#list .item .name').textContent")
Check("第一条是置顶的工作周报", first = '"工作周报"', first)

badge := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .badge').length")
Check("已收起有标记", badge = "1", "badge=" badge)

pin := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .pin').length")
Check("置顶有标记", pin = "1", "pin=" pin)

cntText := ListWindow.Win.wv.ExecuteScript("document.getElementById('count').textContent")
Check("底部计数正确", InStr(cntText, "3") > 0, cntText)

; 搜索走宿主 SQL
ListWindow.Push("面包")
Sleep 500
cnt2 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("搜面包命中 1 条", cnt2 = "1", "count=" cnt2)

ListWindow.Push("后台维护")
Sleep 500
cnt3 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("能搜到已收起的", cnt3 = "1", "count=" cnt3)

ListWindow.Push("")
Sleep 400
cnt4 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("清空关键字回到 3 条", cnt4 = "3", "count=" cnt4)

; 点击第一行应回调 onOpen
ListWindow.Win.wv.ExecuteScript("document.querySelector('#list .item').click();1")
Sleep 400
Check("点击回调 onOpen", openId != 0, "id=" openId)

; 点删除按钮应回调 onDelete
ListWindow.Win.wv.ExecuteScript("document.querySelector('#list .item .ops button.del').click();1")
Sleep 400
Check("删除按钮回调", InStr(FileRead(App.LogPath, "UTF-8"), "hook:delete") > 0)

; ---- 窗口置顶：按钮 → 宿主改窗口 → 回消息点亮按钮 -----------------------
hwnd := ListWindow.Win.gui.Hwnd
on0 := ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').classList.contains('on')")
Check("置顶按钮初始是熄的", on0 = "false", on0)
Check("初始窗口不带 WS_EX_TOPMOST", (WinGetExStyle("ahk_id " hwnd) & 0x8) = 0
    , WinGetExStyle("ahk_id " hwnd))

ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').click();1")
Sleep 700
Check("点图钉后窗口真的置顶了", (WinGetExStyle("ahk_id " hwnd) & 0x8) ? 1 : 0
    , WinGetExStyle("ahk_id " hwnd))
on1 := ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').classList.contains('on')")
Check("按钮跟着点亮", on1 = "true", on1)
Check("置顶偏好写进了配置", App.Cfg("window", "listTopmost", 0) ? 1 : 0,
    App.Cfg("window", "listTopmost", "?"))

ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').click();1")
Sleep 700
Check("再点一次取消置顶", (WinGetExStyle("ahk_id " hwnd) & 0x8) = 0
    , WinGetExStyle("ahk_id " hwnd))
on2 := ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').classList.contains('on')")
Check("按钮跟着熄掉", on2 = "false", on2)

ListWindow.Close()
Sleep 300
Check("关闭后 Win=0", !ListWindow.IsOpen())

st.Close()
App.Log("=== 结束：PASS " PassN " / FAIL " FailN)
Sleep 200
ExitApp
