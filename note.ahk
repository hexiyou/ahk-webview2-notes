#Requires AutoHotkey v2.0
#SingleInstance Off
#ErrorStdOut UTF-8
; ============================================================================
;  QuickNote —— 桌面便签（AHK v2 + WebView2 + SQLite）
;
;  跑起来：双击 note.ahk，或用 runtime\AutoHotkey64.exe note.ahk
;
;  进程模型：
;    · 单实例。再次启动不会开第二个进程，而是把已收起的便签全部显示出来。
;    · 一张便签 = 一个顶层窗口 + 一个 WebView2 controller（各自一个渲染进程）。
;    · 所有 WebView2 共用一个 user data folder，浏览器进程组只付一次内存。
;    · 数据库只由本进程（AHK 主线程）写，页面永远通过消息桥提交。
;
;  快捷键（可在 config.ini 改）：
;    Ctrl+Alt+N  新建便签
;    Ctrl+Alt+L  便签列表
;    Ctrl+Alt+H  全部收起 / 再按全部显示
; ============================================================================

#Include lib\json.ahk
#Include lib\sqlite.ahk
#Include lib\store.ahk
#Include lib\win.ahk
#Include lib\WebView2\WebView2.ahk
#Include lib\note-window.ahk
#Include lib\list-window.ahk

class App {
    static Name := "QuickNote"
    static DataDir := ""
    static Store := 0
    static Ctx := 0
    static LogPath := ""
    static Anchor := 0
    static Queue := []
    static QueueIdx := 0
    static InstanceLock := 0

    ; ========================================================================
    ;  启动
    ; ========================================================================

    static Main() {
        ; 任何未捕获异常都别弹模态框（单 UI 线程，弹了就全卡死），写日志就好
        OnError(NoteOnError)
        OnExit(NoteOnExit)

        ; 1) 单实例：抢到锁的继续，抢不到的唤出已有实例后退出
        App.InstanceLock := DllCall("CreateMutexW", "ptr", 0, "int", 0, "wstr", "Local\QuickNote.SingleInstance", "ptr")
        if (A_LastError = 183) {                 ; ERROR_ALREADY_EXISTS
            App.PokeRunningInstance()
            ExitApp()
        }

        ; 2) 进程级 DPI：PerMonitorV2。必须在建窗口前设，否则拔插副屏会糊
        try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

        ; 3) 路径与配置
        App.DataDir := App.ResolveDataDir()
        App.EnsureConfig()
        App.LogPath := App.DataDir "\app.log"
        App.MigrateCfg()
        if !DirExist(App.DataDir "\webview2")
            DirCreate App.DataDir "\webview2"
        App.Ctx := {
            uiDir: A_ScriptDir "\ui",
            dllPath: A_ScriptDir "\lib\WebView2Loader.dll",
            dataDir: App.DataDir "\webview2",
            devtools: App.Cfg("debug", "devtools", 0),
            appearance: {
                transparent: App.Cfg("appearance", "transparent", 1),
                fontSize: App.Cfg("appearance", "fontSize", 15),
                drag: App.Cfg("appearance", "drag", "manual")
            }
        }

        ; 4) 数据库
        try {
            App.Store := Store(App.DataDir "\notes.db")
        } catch as e {
            MsgBox("数据库打开失败：`n" CleanComError(e.Message) "`n`n路径：" App.DataDir "\notes.db", App.Name, "Icon!")
            ExitApp()
        }
        NoteWindow.Store := App.Store
        NoteWindow.Ctx := App.Ctx

        ; 5) 托盘与热键
        App.BuildTray()
        App.BindHotkeys()

        ; 6) 锚点窗口：单实例唤醒、以及给脚本一个稳定的消息入口
        g := Gui("+ToolWindow -Caption", App.Name "Anchor")
        g.MarginX := 0
        g.MarginY := 0
        g.Show("x-32000 y-32000 w1 h1")
        App.Anchor := g

        ; 唤醒消息：WM_APP + 1
        OnMessage(0x8001, (*) => App.ShowAll())

        ; 7) 装载便签（分批，见 BootTick）
        App.Log("启动，数据目录 " App.DataDir "，SQLite " Sqlite.Version())
        App.Log("托盘/热键/锚点就绪，开始装载便签")
        App.Boot()
        App.Log("Boot 返回，窗口数=" NoteWindow.All.Count)

        ; 命令行 --list：启动后直接把列表面板打开（做快捷方式时很有用）
        if App.HasArg("--list")
            App.ShowList()

        ; 8) 几何变化巡检：拖动/缩放结束后把位置写回库
        SetTimer(NoteGeoTick, 800)
    }

    ; 数据目录：优先便携模式（程序目录下能写就用程序目录\data），否则 %APPDATA%
    static ResolveDataDir() {
        portable := A_ScriptDir "\portable.txt"
        if FileExist(portable) {
            dir := A_ScriptDir "\data"
            if !DirExist(dir)
                DirCreate dir
            return dir
        }
        dir := A_AppData "\" App.Name
        if !DirExist(dir)
            DirCreate dir
        ; 能写才算数
        probe := dir "\.write-test"
        try {
            FileAppend "1", probe
            FileDelete probe
            return dir
        }
        return A_ScriptDir "\data"
    }

    ; ========================================================================
    ;  便签的创建 / 装载
    ; ========================================================================

    static Boot() {
        notes := App.Store.Visible()
        if !notes.Length {
            App.NewNote()
            return
        }
        App.Queue := notes
        App.QueueIdx := 0
        App.BootTick()                      ; 第一张立即建，其余错峰
    }

    /* 一次性把 N 个 WebView2 全建出来会阻塞消息循环好几秒（每张 200~500ms），
       期间所有窗口都是白板。所以隔 70ms 建一张，先出的窗口马上就活。 */
    static BootTick() {
        if (App.QueueIdx >= App.Queue.Length) {
            SetTimer(NoteBootTick, 0)
            return
        }
        App.QueueIdx++
        n := App.Queue[App.QueueIdx]
        try NoteWindow(n)
        catch as e
            App.Log("创建便签 " n.id " 失败：" CleanComError(e.Message))
        if (App.QueueIdx >= App.Queue.Length)
            SetTimer(NoteBootTick, 0)
        else
            SetTimer(NoteBootTick, 70)
    }

    static NewNote() {
        count := App.Store.Count()
        geo := Win.Cascade(count, App.Cfg("window", "width", 300), App.Cfg("window", "height", 280))
        color := App.Cfg("window", "color", "yellow")
        id := App.Store.Create(Map(
            "color", color,
            "x", geo.x, "y", geo.y, "w", geo.w, "h", geo.h))
        n := App.Store.Get(id)
        w := NoteWindow(n)
        w.ToFront()
        return w
    }

    static OpenNote(id) {
        if NoteWindow.All.Has(id) {
            w := NoteWindow.All[id]
            w.Show()
            w.ToFront()
            return w
        }
        n := App.Store.Get(id)
        if !n {
            App.Toast("这张便签已经不在了")
            return 0
        }
        w := NoteWindow(n)
        w.ToFront()
        return w
    }

    static ShowAll() {
        for n in App.Store.Visible()
            App.OpenNote(n.id)
        App.RefreshTray()
    }

    static HideAll() {
        for id, w in NoteWindow.All.Clone()
            w.Hide()
        App.RefreshTray()
    }

    ; 拖动/缩放后写回：这里只处理"程序自己动过窗口"以外的情况
    static GeoTick() {
        for id, w in NoteWindow.All
            w.SaveGeometryNow()
    }

    ; ========================================================================
    ;  列表窗口
    ; ========================================================================

    static ShowList() {
        ListWindow.Store := App.Store
        ListWindow.Ctx := App.Ctx
        ListWindow.Hooks := Map(
            "onNew", NoteNew,
            "onOpen", NoteOpen,
            "onDelete", NoteDelete,
            "onHide", NoteHide,
            "onClose", NoteListClosed)
        ListWindow.Open()
    }

    static CloseList() => ListWindow.Close()

    static DeleteNote(id) {
        if NoteWindow.All.Has(id)
            NoteWindow.All[id].Destroy()
        App.Store.Delete(id)
        App.RefreshTray()
    }

    static HideNote(id) {
        if NoteWindow.All.Has(id)
            NoteWindow.All[id].Hide()
    }

    ; ========================================================================
    ;  托盘 / 热键
    ; ========================================================================

    static BuildTray() {
        t := A_TrayMenu
        t.Delete()
        t.Add("便签列表…`tCtrl+Alt+L", (*) => App.ShowList())
        t.Add("新建便签`tCtrl+Alt+N", (*) => App.NewNote())
        t.Add()
        t.Add("全部显示", (*) => App.ShowAll())
        t.Add("全部收起", (*) => App.HideAll())
        t.Add("透明外观", (*) => App.ToggleAppearance())
        t.Add()
        t.Add("数据目录…", (*) => Run(App.DataDir))
        t.Add("打开日志", (*) => App.OpenLog())
        t.Add("重新加载全部", (*) => App.ReloadAll())
        t.Add()
        t.Add("退出", (*) => App.Quit())
        t.Default := "便签列表…`tCtrl+Alt+L"
        ico := A_ScriptDir "\assets\note.ico"
        if FileExist(ico)
            try TraySetIcon(ico)
        A_IconTip := App.Name " —— 双击打开列表"
        App.RefreshTray()
    }

    static RefreshTray() {
        ; 托盘提示里带上"桌面几张 / 共几张"，收起时也看得出还有活着的
        try {
            total := App.Store ? App.Store.Count() : 0
            shown := 0
            for id, w in NoteWindow.All
                shown++
            A_IconTip := App.Name " —— 桌面 " shown " 张 / 共 " total " 张"
            if App.Ctx && App.Ctx.appearance.transparent
                A_TrayMenu.Check("透明外观")
            else
                A_TrayMenu.Uncheck("透明外观")
        }
    }

    /* 不用 Map 装"热键->回调"：箭头函数写在 Map(...) 的参数里时配对极易出错，
       报错是 "Invalid callback function"（拿到的其实是字符串键）。顺序写清楚最稳。 */
    static BindHotkeys() {
        App.BindOne(App.Cfg("hotkey", "new", "^!n"), App.NewNote)
        App.BindOne(App.Cfg("hotkey", "list", "^!l"), App.ShowList)
        App.BindOne(App.Cfg("hotkey", "toggle", "^!h"), App.ToggleAll)
    }

    static BindOne(key, fn) {
        if (key = "")
            return
        try Hotkey(key, fn, "On")
        catch as e
            App.Log("热键 " key " 注册失败：" CleanComError(e.Message))
    }

    ; 透明外观开关：改配置后整体重建窗口（DefaultBackgroundColor 只在建窗口时设得进去）
    static ToggleAppearance() {
        want := App.Ctx.appearance.transparent ? 0 : 1
        App.Ctx.appearance.transparent := want
        App.SetCfg("appearance", "transparent", want)
        App.ReloadAll()
        App.Toast(want ? "已切换到透明外观" : "已切换到不透明外观")
    }

    static ToggleAll() {
        shown := 0
        for id, w in NoteWindow.All
            shown++
        if (shown > 0)
            App.HideAll()
        else
            App.ShowAll()
    }

    static ReloadAll() {
        for id, w in NoteWindow.All.Clone()
            w.Destroy()
        App.Queue := []
        App.QueueIdx := 0
        App.Boot()
    }

    static Quit() {
        for id, w in NoteWindow.All.Clone()
            w.Destroy()
        if ListWindow.IsOpen()
            ListWindow.Close()
        if App.Store
            App.Store.Close()
        ExitApp()
    }

    ; ========================================================================
    ;  杂项
    ; ========================================================================

    static Toast(text) {
        try TrayTip(text, App.Name)
    }

    static OpenExternal(url) {
        if RegExMatch(url, "i)^(https?|mailto):")
            Run url
    }

    ; 直接开日志：编译版出问题时至少有个能看的地方
    static OpenLog() {
        if FileExist(App.LogPath) {
            try Run(App.LogPath)
            return
        }
        if FileExist(A_ScriptDir "\crash.log") {
            try Run(A_ScriptDir "\crash.log")
            return
        }
        App.Toast("还没有日志")
    }

    static Log(msg) {
        if (App.LogPath = "")
            return
        try {
            if FileExist(App.LogPath) && (FileGetSize(App.LogPath) > 512000)
                FileDelete App.LogPath
            FileAppend FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", App.LogPath, "UTF-8-RAW"
        }
    }

    ; 读配置：config.ini 放数据目录，缺项用默认
    static Cfg(section, key, def) {
        if (App.DataDir = "")
            App.DataDir := App.ResolveDataDir()
        path := App.DataDir "\config.ini"
        v := IniRead(path, section, key, "__none__")
        if (v = "__none__") {
            ; 数值型默认值原样返回数字，其余当字符串
            return def
        }
        if (def is Integer)
            return Integer(v)
        return v
    }

    static OnError(e, mode) {
        App.Log("未处理异常 [" e.What "] " CleanComError(e.Message) " @" e.Line (e.HasProp("File") ? " " e.File : ""))
        return 1        ; 1 = 已处理，不要再弹框
    }

    static OnExit(reason, code) {
        App.Log("退出：reason=" reason " code=" code)
    }

    /* 早期版本默认 drag=native，但真机上原生 app-region 根本拖不动
       （能点、不跟手，用户在实机验证过），所以老配置里残留的 native 一律
       改回 manual。只改一次，用 dragVersion 打标，之后尊重用户手写。 */
    static MigrateCfg() {
        path := App.DataDir "\config.ini"
        if !FileExist(path)
            return
        if (IniRead(path, "appearance", "dragVersion", "0") = "1")
            return
        try {
            IniWrite "manual", path, "appearance", "drag"
            IniWrite "1", path, "appearance", "dragVersion"
            App.Log("配置迁移：drag 改为 manual（原生拖动在实机上不生效）")
        }
    }

    ; 首次运行写一份带注释的配置，省得用户去翻 README
    static EnsureConfig() {
        if !DirExist(App.DataDir)
            DirCreate App.DataDir
        path := App.DataDir "\config.ini"
        if FileExist(path)
            return
        text := ""
        text .= "; QuickNote 配置（改完重启程序生效）`r`n"
        text .= "; 托盘菜单「重新加载全部」可以只重建窗口，不用退出`r`n`r`n"
        text .= "[appearance]`r`n"
        text .= "; 1 = 半透明卡片，能透出桌面；0 = 不透明实色`r`n"
        text .= "; 如果透明模式下窗口是黑底或者空白，把它改成 0`r`n"
        text .= "transparent=1`r`n"
        text .= "; 正文字号（像素）`r`n"
        text .= "fontSize=15`r`n"
        text .= "; 拖动方式：manual = 顶栏按下后交给系统移动循环（默认，实机可靠）`r`n"
        text .= "; native = 用 -webkit-app-region 让 WebView2 自己处理；实测在透明`r`n"
        text .= ";          窗口和带边框的窗口上都拖不动，只留作排查用`r`n"
        text .= "drag=manual`r`n"
        text .= "; 内部标记：用于判断老配置要不要迁移，别删`r`n"
        text .= "dragVersion=1`r`n`r`n"
        text .= "[window]`r`n"
        text .= "; 新建便签的默认尺寸`r`n"
        text .= "width=300`r`n"
        text .= "height=280`r`n"
        text .= "; 默认颜色：yellow / pink / blue / green / purple / gray`r`n"
        text .= "color=yellow`r`n`r`n"
        text .= "[hotkey]`r`n"
        text .= "; 留空表示不注册该热键`r`n"
        text .= "new=^!n`r`n"
        text .= "list=^!l`r`n"
        text .= "toggle=^!h`r`n`r`n"
        text .= "[debug]`r`n"
        text .= "; 1 = 允许 F12 打开开发者工具（排查页面问题用）`r`n"
        text .= "devtools=0`r`n"
        try {
            f := FileOpen(path, "w", "UTF-16")
            f.Write(text)
            f.Close()
        }
    }

    static HasArg(flag) {
        for a in A_Args
            if (a = flag)
                return true
        return false
    }

    static SetCfg(section, key, value) {
        try IniWrite String(value), App.DataDir "\config.ini", section, key
    }

    static PokeRunningInstance() {
        if hwnd := WinExist(App.Name "Anchor") {
            PostMessage(0x8001, 0, 0, , "ahk_id " hwnd)
            return
        }
        ; 找不到锚点（极少见）就退而求其次：提示一下
        MsgBox("便签已经在运行了。`n在托盘图标上双击可以打开列表。", App.Name, "Icon! T2")
    }
}

; ---- 顶层包装：SetTimer / OnError 传类静态方法引用会踩坑，统一走这里 ----------
NoteBootTick() => App.BootTick()
NoteNew() => App.NewNote()
NoteOpen(id) => App.OpenNote(id)
NoteDelete(id) => App.DeleteNote(id)
NoteHide(id) => App.HideNote(id)
NoteListClosed() => App.RefreshTray()
NoteGeoTick() => App.GeoTick()

NoteOnError(e, mode) {
    msg := "未处理异常 [" e.What "] " CleanComError(e.Message) " @" e.Line
    App.Log(msg)
    if (App.LogPath = "")           ; 还没走到设日志那步，直接落程序目录
        NoteCrash(msg)
    return 1        ; 1 = 已处理，不弹模态框（弹了整个 UI 线程就冻住了）
}

NoteOnExit(reason, code) {
    App.Log("退出：reason=" reason " code=" code)
}

/* 编译版没有控制台，也没有 AHK 的语法错误框，出问题必须自己留痕。
   crash.log 固定写在程序目录，和数据目录是否可写无关。 */
NoteCrash(msg) {
    line := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  " msg "`n"
    try FileAppend line, A_ScriptDir "\crash.log", "UTF-8-RAW"
}

/* 启动阶段包一层：这时还没有窗口和托盘，弹框是安全的，也是编译版唯一
   能看到错误内容的机会。跑起来之后的异常交给 NoteOnError 静默记日志。 */

/* --check：只做语法/加载检查，立刻退出。打包脚本编译前会先跑一遍，
   免得把"编出来一启动就退"的 exe 交付出去。 */
if App.HasArg("--check")
    ExitApp 0

try App.Main()
catch as e {
    msg := "启动失败：" CleanComError(e.Message)
    if e.HasProp("File")
        msg .= "`n位置：" e.File " 第 " e.Line " 行"
    NoteCrash(msg)
    tip := ""
    if A_IsCompiled
        tip := "`n`n编译版看不到详细报错，可以改用项目根目录的 run.bat 跑脚本版定位。"
    MsgBox(msg tip "`n`n崩溃日志：" A_ScriptDir "\crash.log", "QuickNote 启动失败", "Icon!")
    ExitApp 1
}
