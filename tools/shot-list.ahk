#Requires AutoHotkey v2.0
; ============================================================================
;  shot-list.ahk —— 给 README 拍一张列表窗口的截图（写到 assets\shot-list.png）
;
;  单独做一个脚本而不是塞进 note.ahk：列表窗口是独立单例，起整个程序再让它
;  显示"置顶按钮亮着"反而更绕。这里用临时库（data\_shotlist.db）摆几条样例
;  便签，拍完就删。
;
;  截图走 WebView2 的 CapturePreviewAsync（不抓桌面），所以在锁屏/远程桌面下
;  也能出图。
; ============================================================================

#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk
#Include ..\lib\list-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_shot-list.log"
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
    ; 列表窗口要读/写 config.ini（置顶偏好），截图时用内存版
    static CfgStore := Map()
    static Cfg(sec, key, def) {
        k := sec "." key
        return App.CfgStore.Has(k) ? App.CfgStore[k] : def
    }
    static SetCfg(sec, key, val) => App.CfgStore[sec "." key] := val
}

if FileExist(App.LogPath)
    FileDelete App.LogPath
try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

dataDir := A_ScriptDir "\..\data"
dbFiles := [dataDir "\_shotlist.db", dataDir "\_shotlist.db-wal", dataDir "\_shotlist.db-shm"]
for f in dbFiles
    if FileExist(f)
        FileDelete f

st := Store(dataDir "\_shotlist.db")
st.Create(Map("title", "买菜清单", "body_text", "鸡蛋 牛奶 面包", "color", "yellow"))
st.Create(Map("title", "工作周报", "body_text", "本周完成了搜索功能，顺手修了三个 bug"
    , "color", "blue", "pinned", 1))
hkId := st.Create(Map("title", "想法碎片", "body_text", "给便签加个语法着色？", "color", "purple"))
; 给一条设个快捷键：列表角标（Ctrl+Alt+1）也要出现在文档截图里
st.SetHotkey(hkId, "^!1")
st.Create(Map("title", "后台维护", "body_text", "每月清理一次图片缓存", "color", "gray", "hidden", 1))

ListWindow.Store := st
ListWindow.Ctx := {
    uiDir: A_ScriptDir "\..\ui",
    dllPath: A_ScriptDir "\..\lib\WebView2Loader.dll",
    dataDir: dataDir "\webview2",
    imagesDir: dataDir "\images",
    devtools: 0,
    appearance: { transparent: 0, fontSize: 15, drag: "manual" }
}
ListWindow.Open()
Sleep 1800

; 拍"置顶开着"的样子：图钉点亮，一眼能看出这个功能在哪儿
ListWindow.SetTopmost(1)
Sleep 800

w := ListWindow.Win
if !w {
    App.Log("列表窗口没建起来")
    ExitApp 1
}

pStream := 0
DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", 1, "ptr*", &pStream, "int")
w.wv.CapturePreviewAsync(0, pStream).await()
hGlobal := 0
DllCall("ole32\GetHGlobalFromStream", "ptr", pStream, "ptr*", &hGlobal)
size := DllCall("kernel32\GlobalSize", "ptr", hGlobal, "uptr")
p := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
data := Buffer(size)
DllCall("RtlMoveMemory", "ptr", data, "ptr", p, "uptr", size)
DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)

out := A_ScriptDir "\..\assets\shot-list.png"
if FileExist(out)
    FileDelete out
f := FileOpen(out, "w")
f.RawWrite(data, size)
f.Close()
App.Log("SHOT list=" (FileExist(out) ? 1 : 0) " " size " 字节")

Sleep 200
ListWindow.Close()
st.Close()
Sleep 200
for f in dbFiles
    if FileExist(f)
        FileDelete f
ExitApp 0
