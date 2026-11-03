#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
; 单窗口冒烟测试：不启动托盘/热键，只建一张便签，看页面是否真的活起来。
#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_win.log"
    static Log(m) => FileAppend(m "`n", App.LogPath, "UTF-8-RAW")
    static Toast(t) => App.Log("toast: " t)
    static NewNote() => 0
    static ShowList() => 0
    static ZoomFont(step) => 0
    static RenameNote(id) => 0
    static ExportNote(id, fmt) => 0
    static SaveImage(raw, id) => 0
    static SetFontSize(px) => 0
    static RefreshTray() => 0
    static OpenExternal(u) => 0
    static GetNote(id) => 0
}

if FileExist(App.LogPath)
    FileDelete App.LogPath
App.Log("=== probe-window 开始")

try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

dataDir := A_ScriptDir "\..\data"
for f in [dataDir "\_win.db", dataDir "\_win.db-wal", dataDir "\_win.db-shm"]
    if FileExist(f)
        FileDelete f

st := Store(dataDir "\_win.db")
NoteWindow.Store := st
NoteWindow.Ctx := {
    uiDir: A_ScriptDir "\..\ui",
    dllPath: A_ScriptDir "\..\lib\WebView2Loader.dll",
    dataDir: dataDir "\webview2",
    imagesDir: dataDir "\images",
    devtools: 0,
    appearance: { transparent: 1, fontSize: 15, drag: "native" }
}

id := st.Create(Map("title", "冒烟测试", "body_html", "<p>你好，<b>便签</b>。</p>"
    , "body_text", "你好，便签。", "body_md", "你好，**便签**。", "x", 200, "y", 160, "w", 320, "h", 300))
n := st.Get(id)
App.Log("created id=" id)

w := NoteWindow(n)
App.Log("window created hwnd=" w.gui.Hwnd)

SetTimer(Check, -2600)
SetTimer(Finish, -4200)

Check() {
    global w
    App.Log("ready=" w.ready " wv=" (w.wv ? "ok" : "null") " wvc=" (w.wvc ? "ok" : "null"))
    try {
        r := w.wv.ExecuteScript("JSON.stringify({t:document.body.innerText.slice(0,60),color:document.body.dataset.color,fs:document.documentElement.style.getPropertyValue('--fs'),cls:document.body.className,transparent:document.body.classList.contains('transparent')})")
        App.Log("page=" r)
    } catch as e {
        App.Log("exec 失败：" CleanComError(e.Message))
    }
}

Finish() {
    global w, st
    App.Log("收尾，几何=" (w.gui ? Win.Rect(w.gui.Hwnd).w : "?") )
    if IsObject(w) && IsSet(w)
        w.Destroy()
    st.Close()
    App.Log("=== 结束")
    ExitApp
}
