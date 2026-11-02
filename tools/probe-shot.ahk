#Requires AutoHotkey v2.0
#ErrorStdOut UTF-8
; 渲染截图：把便签页/列表页的合成结果存成 PNG（不含窗口边框，仅页面内容）。
; 本机没有物理显示器时，这是唯一能"看到"界面的办法。
#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk
#Include ..\lib\list-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_shot.log"
    static Log(m) => FileAppend(m "`n", App.LogPath, "UTF-8-RAW")
    static Toast(t) => 0
    static NewNote() => 0
    static ShowList() => 0
    static ZoomFont(step) => 0
    static RenameNote(id) => 0
    static SaveImage(raw, id) => 0
    static SetFontSize(px) => 0
    static RefreshTray() => 0
    static OpenExternal(u) => 0
}

if FileExist(App.LogPath)
    FileDelete App.LogPath

Shot(wv, outPath) {
    pStream := 0
    hr := DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", 1, "ptr*", &pStream, "int")
    if (hr != 0 || !pStream) {
        App.Log("CreateStreamOnHGlobal 失败 " hr)
        return false
    }
    try {
        wv.CapturePreviewAsync(0, pStream).await()      ; 0 = PNG
        hGlobal := 0
        DllCall("ole32\GetHGlobalFromStream", "ptr", pStream, "ptr*", &hGlobal)
        size := DllCall("kernel32\GlobalSize", "ptr", hGlobal, "uptr")
        p := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
        if (!p || !size) {
            App.Log("取不到图像数据")
            return false
        }
        data := Buffer(size)
        DllCall("RtlMoveMemory", "ptr", data, "ptr", p, "uptr", size)
        DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        if FileExist(outPath)
            FileDelete outPath
        f := FileOpen(outPath, "w")
        f.RawWrite(data, size)
        f.Close()
        App.Log("已写出 " outPath " size=" size)
        return true
    } finally {
        ObjRelease(pStream)
    }
}

try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

dataDir := A_ScriptDir "\..\data"
for f in [dataDir "\_shot.db", dataDir "\_shot.db-wal", dataDir "\_shot.db-shm"]
    if FileExist(f)
        FileDelete f

st := Store(dataDir "\_shot.db")
NoteWindow.Store := st
NoteWindow.Ctx := {
    uiDir: A_ScriptDir "\..\ui",
    dllPath: A_ScriptDir "\..\lib\WebView2Loader.dll",
    dataDir: dataDir "\webview2",
    imagesDir: dataDir "\images",
    devtools: 0,
    appearance: { transparent: 0, fontSize: 15, drag: "native" }
}

id := st.Create(Map("x", 200, "y", 150, "w", 380, "h", 460))
n := st.Get(id)
w := NoteWindow(n)
Sleep 1600

; 用 Markdown 灌内容：全程没有双引号，避开 AHK/JS 双重转义的坑
md := ""
md .= "## 今天的便签`n`n"
md .= "把想到的事随手记下来，**不用打开大软件**。`n`n"
md .= "- 买菜：鸡蛋、牛奶`n"
md .= "- 给老王回电话`n`n"
md .= "- [ ] 改一版登录页`n"
md .= "- [x] 把周报发出去`n`n"
md .= "> 记得关灯。`n`n"
md .= "命令：``git status```n"

w.wv.ExecuteScript("document.getElementById('btnMd').click();1")
Sleep 500
w.wv.ExecuteScript("var s=document.getElementById('source');s.value=" JsonQuote(md) ";s.dispatchEvent(new Event('input',{bubbles:true}));1")
Sleep 700
w.wv.ExecuteScript("document.getElementById('btnMd').click();1")
Sleep 900

Shot(w.wv, A_ScriptDir "\..\assets\shot-note.png")

; 换蓝色再截一张，确认配色变量生效
App.Log("改色前")
w.DoColor("blue")
App.Log("改色后")
Sleep 900
Shot(w.wv, A_ScriptDir "\..\assets\shot-note-blue.png")
App.Log("第二张结束")

; 列表页
st.Create(Map("title", "买菜清单", "body_text", "鸡蛋 牛奶 面包 生抽", "color", "yellow"))
st.Create(Map("title", "周报要点", "body_text", "本周完成了便签的多窗口与搜索", "color", "blue", "pinned", 1))
st.Create(Map("title", "读书笔记", "body_text", "把复杂留给实现，把简单留给使用", "color", "green", "hidden", 1))

ListWindow.Store := st
ListWindow.Ctx := NoteWindow.Ctx
ListWindow.Hooks := Map()
ListWindow.Open()
Sleep 1600
Shot(ListWindow.Win.wv, A_ScriptDir "\..\assets\shot-list.png")

w.Destroy()
ListWindow.Close()
st.Close()
App.Log("done")
ExitApp
