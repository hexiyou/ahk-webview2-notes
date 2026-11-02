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
    ; 字号范围：太小看不清，太大一张便签里放不下几个字
    static FONT_MIN := 10
    static FONT_MAX := 32
    static FONT_DEFAULT := 15

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
            imagesDir: App.DataDir "\images",
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
        ; 走定时器而不是直接调：ShowAll 要建窗，OnMessage 线程里 await 有风险
        OnMessage(0x8001, (*) => NoteShowAllSoon())

        ; 7) 装载便签（分批，见 BootTick）
        App.Log("启动，数据目录 " App.DataDir "，SQLite " Sqlite.Version())
        App.Log("托盘/热键/锚点就绪，开始装载便签")
        App.Boot()
        App.Log("Boot 返回，窗口数=" NoteWindow.All.Count)

        ; 命令行 --list：启动后直接把列表面板打开（做快捷方式时很有用）
        if App.HasArg("--list")
            App.ShowList()

        if App.HasArg("--selftest-showall")
            SetTimer(SelfTestShowAll, -2500)
        if App.HasArg("--selftest-menu")
            SetTimer(SelfTestMenu, -2500)
        if App.HasArg("--selftest-keys")
            SetTimer(SelfTestKeys, -2500)
        if App.HasArg("--selftest-list")
            SetTimer(SelfTestList, -2500)
        if App.HasArg("--selftest-font")
            SetTimer(SelfTestFont, -2500)
        if App.HasArg("--selftest-rich")
            SetTimer(SelfTestRich, -2500)

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
        App.RefreshList()
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
        /* 重新建窗也要把 hidden 复位：否则"全部显示"只是把窗口画出来，
           库里还标着已收起，下次启动又不见了（自检抓到过）。 */
        if (n.hidden)
            App.Store.SetHidden(id, 0)
        w.ToFront()
        return w
    }

    /* 全部显示：必须遍历 All() 而不是 Visible()。
       Visible() 只返回 hidden=0 的，而"收起的便签"恰好都是 hidden=1 —— 之前
       用 Visible() 的结果就是：一收起就再也点不出来，点菜单毫无反应。 */
    static ShowAll() {
        for n in App.Store.All()
            App.OpenNote(n.id)
        App.RefreshTray()
        App.RefreshList()
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
            "onRename", NoteRename,
            "onPin", NotePin,
            "onColor", NoteColor,
            "onShowAll", NoteShowAll,
            "onHideAll", NoteHideAll,
            "onDataDir", NoteDataDir,
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

    /* 列表窗口发起的改动：先写库，再让开着的那张便签同步外观
       （Apply* 只管外观，不做持久化 —— 持久化由这里负责，避免写两遍）。 */
    static SetPin(id, on) {
        App.Store.SetPinned(id, on)
        if NoteWindow.All.Has(id)
            NoteWindow.All[id].ApplyPin(on)
        App.RefreshTray()
    }

    static SetColor(id, color) {
        if !NoteWindow.IsColor(color)
            return
        App.Store.SetColor(id, color)
        if NoteWindow.All.Has(id)
            NoteWindow.All[id].ApplyColor(color)
    }

    /* ---- 标题 ---------------------------------------------------------------
       标题默认是"正文第一行的前 60 字"自动派生的，所以以前根本没有改名字的入口。
       手动指定后 Store 会把 title_locked 置 1，之后正文怎么变都不再覆盖它；
       再想交回自动，就把输入框清空。 */
    static RenameNote(id) {
        n := App.Store.Get(id)
        if !n {
            App.Toast("这张便签已经不在了")
            return
        }
        hintText := n.title_locked ? "留空 = 恢复按正文第一行自动取标题"
            : "留空 = 保持现在的自动标题"
        r := InputBox("给这张便签起个名字（列表里就显示这个）`n`n" hintText
            , "重命名便签", "w420 h170", n.title)
        if (r.Result = "Cancel")
            return
        name := Trim(r.Value)
        if (name = "") {
            t := App.Store.ClearTitle(id)
            App.Toast(t = "" ? "已恢复自动标题" : "已恢复自动标题：" t)
        } else {
            App.Store.SetTitle(id, name)
            App.Toast("标题已改为「" name "」")
        }
        if NoteWindow.All.Has(id)
            NoteWindow.All[id].note := App.Store.Get(id)
        App.RefreshList()
        App.RefreshTray()
    }

    /* ---- 字号 ---------------------------------------------------------------
       字号是全局的（config.ini 的 [appearance] fontSize），不是每张便签一份：
       Ctrl+滚轮 的手感应该像浏览器缩放，所有便签一起变，不需要用户逐张去调。
       入口有两个：页面里的 Ctrl+滚轮（发 font 消息过来）、便签右键菜单的「字号」，
       都收口到 ZoomFont / SetFontSize。 */
    static ZoomFont(step) {
        cur := App.Ctx ? App.Ctx.appearance.fontSize : 15
        App.SetFontSize(step = 0 ? App.FONT_DEFAULT : cur + (step > 0 ? 1 : -1))
    }

    static SetFontSize(px) {
        px := Max(App.FONT_MIN, Min(App.FONT_MAX, Integer(px)))
        if !App.Ctx
            return
        if (App.Ctx.appearance.fontSize = px)
            return
        App.Ctx.appearance.fontSize := px
        ; 广播给所有开着的便签：页面把 --fs 变量一改，正文和源码视图一起变
        for id, w in NoteWindow.All
            w.Send('{"type":"font","size":' px '}')
        /* 合并写盘：按住滚轮连续滚会一秒触发几十次，每次 IniWrite 都要重写整个
           文件。延后 400ms 只写最后一次，中间的内存值始终是最新的。 */
        SetTimer(NoteFontSave, -400)
    }

    static SaveFontSize() {
        if App.Ctx
            App.SetCfg("appearance", "fontSize", App.Ctx.appearance.fontSize)
    }

    /* 在便签页面里跑一段 JS 并把结果当数字取回（只给自检用）。
       ExecuteScriptAsync 的返回值是 JSON 编码过的文本（"15" 会变成 "\"15\""，
       取不到值时是 "NaN"/"undefined"/"{}"），所以这里用正则抠第一个数字，
       抠不到就返回 -1，让断言自然失败。不要写 r+0：字符串一旦不是纯数字，
       AHK v2 会抛 "Expected a Number but got a String"，把整个自检线程带走。 */
    static EvalNum(w, js) {
        r := ""
        try r := w.wv.ExecuteScriptAsync(js).await()
        catch as e {
            App.Log("ExecuteScript 失败：" CleanComError(e.Message))
            return -1
        }
        if !RegExMatch(r, "-?\d+(?:\.\d+)?", &m) {
            App.Log("ExecuteScript 取不到数字，原始返回：" r)
            return -1
        }
        return Round(m[0] + 0)
    }

    static RefreshList() {
        if ListWindow.IsOpen()
            ListWindow.Push(ListWindow.Query)
    }

    static OpenDataDir() {
        try Run(App.DataDir)
    }

    ; ========================================================================
    ;  托盘 / 热键
    ; ========================================================================

    static BuildTray() {
        t := A_TrayMenu
        t.Delete()
        t.Add("便签列表…`tCtrl+Alt+L", (*) => NoteDeferList())
        t.Add("新建便签`tCtrl+Alt+N", (*) => NoteDeferNew())
        t.Add()
        t.Add("全部显示", (*) => NoteShowAllSoon())
        t.Add("全部收起", (*) => App.HideAll())
        t.Add("透明外观", (*) => App.ToggleAppearance())
        t.Add()
        t.Add("数据目录…", (*) => Run(App.DataDir))
        t.Add("打开日志", (*) => App.OpenLog())
        t.Add("重新加载全部", (*) => SetTimer(NoteReloadTick, -10))
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
        App.BindOne(App.Cfg("hotkey", "new", "^!n"), NoteDeferNew)
        App.BindOne(App.Cfg("hotkey", "list", "^!l"), NoteDeferList)
        App.BindOne(App.Cfg("hotkey", "toggle", "^!h"), NoteToggle)
        App.BindListKeys()
    }

    /* 列表窗口里的 Ctrl+N。
       页面里也写了一份（list.js），但 WebView2 默认把 Ctrl+N 当"新建窗口"这类
       浏览器快捷键吃掉，页面收不到 —— 用户按下去就是"毫无反应"。所以这里用条件
       热键直接接管（只在列表窗口是前台时生效，不干扰别的程序）。

       注意传的是 NoteDeferNew 而不是 App.NewNote：热键线程里直接建窗虽然目前能过，
       但建窗要 await WebView2，一律走独立线程最稳。 */
    static BindListKeys() {
        try {
            HotIf(ListHotkeyCond)
            Hotkey("^n", (*) => NoteDeferNew(), "On")
            HotIf()
            App.Log("列表 Ctrl+N 已注册（仅在列表窗口激活时生效）")
        } catch as e {
            App.Log("列表 Ctrl+N 注册失败：" CleanComError(e.Message))
        }
    }

    /* 热键回调会被传入"触发的热键名"这一个参数，而 AHK 在调用点严格检查个数。
       所以统一套一层变参箭头吃掉它（和菜单的 MB 是同一个坑）。 */
    static BindOne(key, fn) {
        if (key = "")
            return
        try Hotkey(key, (*) => fn.Call(), "On")
        catch as e
            App.Log("热键 " key " 注册失败：" CleanComError(e.Message))
    }

    ; 透明外观开关：改配置后整体重建窗口（DefaultBackgroundColor 只在建窗口时设得进去）
    static ToggleAppearance() {
        want := App.Ctx.appearance.transparent ? 0 : 1
        App.Ctx.appearance.transparent := want
        App.SetCfg("appearance", "transparent", want)
        SetTimer(NoteReloadTick, -10)       ; 重建窗口是重活，别在菜单回调里做
        App.Toast(want ? "已切换到透明外观" : "已切换到不透明外观")
    }

    static ToggleAll() {
        shown := 0
        for id, w in NoteWindow.All
            shown++
        if (shown > 0)
            App.HideAll()
        else
            NoteShowAllSoon()       ; 显示要建窗，一样走独立线程
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
        text .= "; 正文字号（像素，10~32）。编辑区里 Ctrl+滚轮 也能调，会写回这里`r`n"
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

/* 自检收尾：一律走 App.Quit()，不要裸写 ExitApp。
   裸退出会跳过 WebView2 controller 的 Close，进程会在后台滞留几十秒
   （实测 timeout 45s 都等不到它退），同时还占着单实例互斥锁 —— 紧跟着跑
   下一个自检就会被"已经有一个实例在跑"顶掉，症状是测试莫名没反应。 */
SelfTestDone() {
    App.Quit()
}

/* 自检：收起全部 -> 全部显示，确认窗口真的回到屏幕上。
   只在带 --selftest-showall 启动时跑一次，用于回归"全部显示没反应"这个 bug。 */
SelfTestShowAll() {
    total := 0
    for id, w in NoteWindow.All
        total++
    App.Log("SELFTEST 起始：窗口对象 " total " 个")
    for id, w in NoteWindow.All.Clone()
        w.Hide()
    hid := 0
    shown := 0
    for id, w in NoteWindow.All
        hid += DllCall("IsWindowVisible", "ptr", w.gui.Hwnd) ? 1 : 0
    hiddenRows := 0
    for n in App.Store.All()
        hiddenRows += n.hidden ? 1 : 0
    App.Log("SELFTEST 收起后：仍可见窗口 " hid " 个，库里 hidden=1 共 " hiddenRows " 张")
    App.ShowAll()
    Sleep 1500
    for id, w in NoteWindow.All
        shown += DllCall("IsWindowVisible", "ptr", w.gui.Hwnd) ? 1 : 0
    hiddenLeft := 0
    for n in App.Store.All()
        hiddenLeft += n.hidden ? 1 : 0
    App.Log("SELFTEST 全部显示后：可见窗口 " shown " 个，库里仍未显示的 " hiddenLeft " 张")
    App.Log("SELFTEST 结论：" (shown = App.Store.Count() && hiddenLeft = 0 ? "通过" : "未通过"))
    SelfTestDone()
}

/* 自检：把第一张便签的菜单弹出来（会阻塞到菜单关闭）。
   只用来确认"从 WebView2 消息回调退出来之后仍能正常弹原生菜单"，
   日志里没有"未处理异常"就算过。 */
SelfTestMenu() {
    for id, w in NoteWindow.All {
        App.Log("SELFTEST 准备弹菜单（便签 " id "）")
        w.ShowMenu()
        App.Log("SELFTEST 菜单已关闭，没有抛异常")
        break
    }
    SelfTestDone()
}

/* 自检：列表窗口的 Ctrl+N 链路。
   本机沙箱里注入键盘会卡死，所以验不到"按下键"这一步，只验：
     1) ^n 注册时没抛异常（BindListKeys 会留一条日志）
     2) 条件热键的判定函数随窗口开关正确翻转
     3) 热键真正调用的那个函数能在不卡死的前提下建出便签 */
SelfTestKeys() {
    /* 注意：AHK 2.0.31 的 Hotkey(KeyName) 恒返回空串，查不到"注册了没有"，
       所以注册状态只能靠 BindListKeys 的日志（没有"注册失败"就是成功）。 */
    App.Log("SELFTEST 开始：热键日志见 BindListKeys")
    App.Log("SELFTEST 列表未开时 IsActive=" ListWindow.IsActive())
    App.ShowList()
    Sleep 1500
    App.Log("SELFTEST 列表打开后 IsActive=" ListWindow.IsActive())
    maxId := 0
    for n in App.Store.All()
        maxId := Max(maxId, n.id)
    before := App.Store.Count()
    NoteDeferNew()
    Sleep 2500
    App.Log("SELFTEST 调 NoteDeferNew 后：窗口 " NoteWindow.All.Count . " 个，库里 " App.Store.Count() . " 张")
    ok := (App.Store.Count() = before + 1 && NoteWindow.All.Count >= 1)
    App.Log("SELFTEST 结论：" (ok ? "通过" : "未通过"))
    ; 自检自己造出来的那张要删掉，别在用户库里留空白便签
    for n in App.Store.All()
        if (n.id > maxId)
            App.DeleteNote(n.id)
    SelfTestDone()
}

/* 自检：列表窗口的"延迟入口"。
   上一版把 NoteDeferList 写成了 SetTimer(Func("NoteShowList"), -10)，而 AHK v2
   里 Func 是内置类，Func("名字") 返回残缺对象，SetTimer 调它的 .Call() 抛
   "Invalid base."；异常又被 NoteOnError 静默吞掉，界面上就是"点托盘菜单、
   点便签菜单，全都没反应"。这条自检专门钉住这个入口，顺便验字号链路。 */
SelfTestList() {
    App.Log("SELFTEST 延迟入口调用前：列表开着=" ListWindow.IsOpen())
    NoteDeferList()
    Sleep 2000
    open := ListWindow.IsOpen()
    App.Log("SELFTEST 调 NoteDeferList 后：列表开着=" open)

    before := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    App.SetFontSize(before + 1)
    Sleep 700
    got := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    App.Log("SELFTEST 字号写入：库里 " got "（期望 " (before + 1) "）")
    App.SetFontSize(before)                 ; 别把用户配置改坏
    Sleep 700
    back := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    App.Log("SELFTEST 字号已恢复为 " back)
    App.Log("SELFTEST 结论：" (open && got = before + 1 && back = before ? "通过" : "未通过"))
    SelfTestDone()
}

/* 自检：Ctrl+滚轮 字号链路。
   这台机器上注入键盘/滚轮会直接把脚本卡死（已确认），所以改用
   ExecuteScriptAsync 在页面里合成 ctrlKey:true 的 WheelEvent —— 走的是和真滚轮
   完全相同的 window.addEventListener('wheel') 那条路，只是省掉了物理输入。
   验四件事：能放大、下限 10、上限 32、宿主把最终值写进了 config.ini。 */
SelfTestFont() {
    w := 0
    for id, x in NoteWindow.All {
        w := x
        break
    }
    if !w {
        App.Log("SELFTEST 字号：没有便签窗口，跳过")
        SelfTestDone()
        return
    }
    Loop 30 {
        if w.ready
            break
        Sleep 100
    }
    before := App.EvalNum(w, "String(parseFloat(getComputedStyle(document.body).fontSize))")
    ; dispatchEvent 的返回值是"事件有没有被取消"，取回来会让日志变吵，末尾补个 1
    js := "window.dispatchEvent(new WheelEvent('wheel',{ctrlKey:true,deltaY:120,bubbles:true,cancelable:true}));1;"
    jsUp := "window.dispatchEvent(new WheelEvent('wheel',{ctrlKey:true,deltaY:-120,bubbles:true,cancelable:true}));1;"
    App.EvalNum(w, jsUp)
    App.EvalNum(w, jsUp)
    Sleep 500
    up := App.EvalNum(w, "String(parseFloat(getComputedStyle(document.body).fontSize))")
    App.EvalNum(w, "for(let i=0;i<40;i++){" js "}")
    Sleep 700
    low := App.EvalNum(w, "String(parseFloat(getComputedStyle(document.body).fontSize))")
    App.EvalNum(w, "for(let i=0;i<40;i++){" jsUp "}")
    Sleep 900
    high := App.EvalNum(w, "String(parseFloat(getComputedStyle(document.body).fontSize))")
    cfg := App.Cfg("appearance", "fontSize", 0)
    App.Log("SELFTEST 字号：" before " → 放大两格 " up " → 缩到底 " low " → 放到底 " high "，config 里是 " cfg)
    ok := (up = before + 2) && (low = App.FONT_MIN) && (high = App.FONT_MAX) && (cfg = App.FONT_MAX)
    App.Log("SELFTEST 结论：" (ok ? "通过" : "未通过"))
    App.SetFontSize(App.FONT_DEFAULT)       ; 别把用户配置留在 32
    Sleep 600
    SelfTestDone()
}

/* 自检：富文本工具条 / Markdown 往返 / 图片插入。
   为什么写在这里而不是另开一个 tools\probe-*.ahk：那套写法要 include 整套库，
   实测在这个环境里会诡异地在加载期就卡死（连第一行 FileAppend 都不执行），
   而主程序本身一切正常。直接在真窗口里点真按钮，验的也正是用户实际走的路。
   测完会把自己新建的那张便签删掉。

   注意这里刻意**没有**用嵌套函数（在 SelfTestRich 里再 def 一个函数）：
   AHK v2 对嵌套函数的支持有坑，实测触发了一个不弹不报、直接把加载卡死的
   状态，排查花了很久。统一改成顶层函数，把窗口对象当参数传进来。 */
SelfTestRich() {
    /* 包一层 try：自检线程一旦抛异常就会静默死掉，进程留在后台不退
       （表现是测试命令一直等到超时）。失败也必须走到 SelfTestDone。 */
    try SelfTestRichRun()
    catch as e {
        App.Log("SELFTEST RICH 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST RICH 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestRichRun() {
    w := App.NewNote()
    if !w {
        App.Log("SELFTEST RICH 没能建出便签")
        SelfTestDone()
        return
    }
    id := w.id
    Loop 40 {
        if w.ready
            break
        Sleep 100
    }
    App.Log("SELFTEST RICH 页面就绪=" (w.ready ? 1 : 0))
    Global RICH_PASS := 0, RICH_FAIL := 0

    ; 页面里的测试脚手架：切内容 / 全选 / 点工具条按钮 / 取 html、md
    RichEval(w, "
    ( LTrim Join
    window.__t = {
      ed: () => document.getElementById('editor'),
      put(h) { this.ed().innerHTML = h; },
      all() {
        const r = document.createRange();
        r.selectNodeContents(this.ed());
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
      },
      click(c) { document.querySelector('[data-cmd=\"' + c + '\"]').click(); },
      html() { return this.ed().innerHTML; },
      md() { return window.MD.toMarkdown(this.ed().innerHTML); }
    };
    1;
    )")

    RichStyle(w, "bold", "b", "**abcdef**", "加粗")
    RichStyle(w, "italic", "i", "*abcdef*", "斜体")
    RichStyle(w, "strikeThrough", "strike", "~~abcdef~~", "删除线")
    RichStyle(w, "formatBlock:h2", "h2", "## abcdef", "二级标题")
    RichStyle(w, "insertUnorderedList", "ul", "- abcdef", "无序列表")
    RichStyle(w, "insertOrderedList", "ol", "1. abcdef", "有序列表")
    RichStyle(w, "codeblock", "pre", "``````", "代码块")
    RichStyle(w, "insertHorizontalRule", "hr", "---", "分割线")

    ; 行内代码是自定义实现
    RichEval(w, "__t.put('<p>abcdef</p>');__t.all();1")
    Sleep 120
    RichEval(w, "__t.click('code');1")
    Sleep 220
    RichSay("行内代码 DOM 有 code", Trim(RichEval(w, "document.querySelector('#editor code') ? 1 : 0")) = "1")
    RichSay("行内代码 能存成 Markdown", InStr(RichEval(w, "__t.md()"), "``abcdef``") > 0, RichEval(w, "__t.md()"))

    ; 待办
    RichEval(w, "__t.put('<p>买牛奶</p>');__t.all();1")
    Sleep 120
    RichEval(w, "__t.click('task');1")
    Sleep 220
    h := RichEval(w, "__t.html()")
    RichSay("待办 DOM 有 task-line/chk", InStr(h, "task-line") > 0 && InStr(h, "chk") > 0, SubStr(h, 1, 90))
    RichSay("待办 能存成 - [ ]", InStr(RichEval(w, "__t.md()"), "- [ ] 买牛奶") > 0, RichEval(w, "__t.md()"))
    RichSay("待办 勾选框走 flex 对齐", InStr(RichEval(w, "getComputedStyle(document.querySelector('.task-line')).display"), "flex") > 0)

    ; 链接（prompt 会挡住自动化，先在页面里把它换掉）
    RichEval(w, "window.prompt = () => 'https://example.com';__t.put('<p>官网</p>');__t.all();1")
    Sleep 120
    RichEval(w, "__t.click('link');1")
    Sleep 260
    h := RichEval(w, "__t.html()")
    RichSay("链接 DOM 有 a[href]", Trim(RichEval(w, "document.querySelector('#editor a[href]') ? 1 : 0")) = "1")
    RichSay("链接 能存成 Markdown", InStr(RichEval(w, "__t.md()"), "[官网](https://example.com)") > 0, RichEval(w, "__t.md()"))

    ; ---- 图片：paste 一张 8x8 PNG，走完整的"页面 → 宿主存盘 → URL"链路 ----
    imgDir := App.DataDir "\images"
    imgBefore := 0
    Loop Files (imgDir "\*.*")
        imgBefore++

    RichEval(w, "
    ( LTrim Join
    __t.put('<p>图：</p>');__t.all();
    var c = document.createElement('canvas'); c.width = 8; c.height = 8;
    var g = c.getContext('2d'); g.fillStyle = '#e04040'; g.fillRect(0, 0, 8, 8);
    var bin = atob(c.toDataURL('image/png').split(',')[1]);
    var arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    var dt = new DataTransfer();
    dt.items.add(new File([arr], 'dot.png', { type: 'image/png' }));
    __t.ed().dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    1;
    )")
    Sleep 2200

    src := RichEval(w, "(function(){var i=document.querySelector('#editor img');return i?(i.getAttribute('src')||''):'NONE';})()")
    imgAfter := 0
    Loop Files (imgDir "\*.*")
        imgAfter++
    RichSay("图片 页面出现 <img>", InStr(src, "NONE") = 0, SubStr(src, 1, 80))
    RichSay("图片 src 是 file:// 链接", InStr(src, "file:///") > 0, SubStr(src, 1, 80))
    RichSay("图片 落盘到 data\images", imgAfter = imgBefore + 1, imgBefore " -> " imgAfter)
    RichSay("图片 正文不留 base64", InStr(RichEval(w, "__t.html()"), "base64,") = 0)
    mdImg := RichEval(w, "__t.md()")
    RichSay("图片 能存成 ![...](file://...)", InStr(mdImg, "](file:///") > 0, SubStr(mdImg, 1, 90))

    Sleep 700
    row := App.Store.Get(id)
    RichSay("图片 落库后仍是链接", InStr(row.body_html, "file:///") > 0, SubStr(row.body_html, 1, 90))

    /* ---- Markdown 源码模式下插图 ----
       这条路径和富文本完全分开：源码模式里没有 DOM 插入点，页面先往 textarea
       写一个 ![](qnote-pending:N) 占位，等宿主回 URL 再替换。曾经只给 #editor
       挂了 drop/paste，源码模式下拖图粘图毫无反应，所以专门验一遍。 */
    w.SendType("toggle-md")
    Sleep 500
    inMd := RichEval(w, "document.getElementById('source').offsetParent ? 1 : 0")
    RichSay("源码模式已切换", Trim(inMd) = "1", inMd)

    imgBefore := 0
    Loop Files (imgDir "\\*.*")
        imgBefore++

    RichEval(w, "
    ( LTrim Join
    (function(){
      var c = document.createElement('canvas'); c.width = 6; c.height = 6;
      var g = c.getContext('2d'); g.fillStyle = '#2060d0'; g.fillRect(0, 0, 6, 6);
      var bin = atob(c.toDataURL('image/png').split(',')[1]);
      var arr = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      var dt = new DataTransfer();
      dt.items.add(new File([arr], 'dot2.png', { type: 'image/png' }));
      var s = document.getElementById('source');
      s.focus();
      s.selectionStart = s.selectionEnd = s.value.length;
      s.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    })();
    1;
    )")
    Sleep 2200

    srcMd := RichEval(w, "document.getElementById('source').value")
    imgAfter := 0
    Loop Files (imgDir "\\*.*")
        imgAfter++
    RichSay("源码模式 占位符已被替换成真链接", InStr(srcMd, "qnote-pending") = 0 && InStr(srcMd, "](file:///") > 0, SubStr(srcMd, 1, 100))
    RichSay("源码模式 图片也落盘", imgAfter = imgBefore + 1, imgBefore " -> " imgAfter)

    w.SendType("toggle-md")
    Sleep 500

    App.Log("SELFTEST RICH 结论：" (RICH_FAIL = 0 ? "通过" : "未通过") "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    ; 别在用户库里留测试便签
    App.DeleteNote(id)
}

; ---- 富文本自检的辅助（一律顶层函数，别写成嵌套函数） ---------------------
RichEval(w, js) {
    try
        return w.wv.ExecuteScriptAsync(js).await()
    catch as e {
        App.Log("ExecuteScript 失败：" CleanComError(e.Message))
        return ""
    }
}

RichSay(name, ok, detail := "") {
    global RICH_PASS, RICH_FAIL
    if ok
        RICH_PASS += 1
    else
        RICH_FAIL += 1
    App.Log((ok ? "PASS " : "FAIL ") name (detail != "" ? "  [" detail "]" : ""))
}

/* 通用流程：塞文字 → 全选 → 点按钮 → 看 DOM 与 Markdown。
   全选后要等一帧，selectionchange 才会把选区记进页面的 savedRange。 */
RichStyle(w, cmd, tag, wantMd, label) {
    RichEval(w, "__t.put('<p>abcdef</p>');__t.all();1")
    Sleep 120
    RichEval(w, "__t.click('" cmd "');1")
    Sleep 220
    /* 断言用 querySelector 而不是在 innerHTML 里找 "<b>"：ExecuteScriptAsync
       的返回值是 JSON 编码过的，尖括号会变成 \u003C，直接 InStr 永远匹配不上
       （第一版就是这么假失败的 11 条）。 */
    has := RichEval(w, "document.querySelector('#editor " tag "') ? 1 : 0")
    m := RichEval(w, "__t.md()")
    RichSay(label " DOM 有 " tag, Trim(has) = "1", has)
    RichSay(label " 能存成 Markdown " wantMd, InStr(m, wantMd) > 0, SubStr(m, 1, 60))
}

; ---- 顶层包装：SetTimer / OnError 传类静态方法引用会踩坑，统一走这里 ----------
NoteBootTick() => App.BootTick()
NoteNew() => App.NewNote()
NoteShowList() => App.ShowList()
/* NoteDeferNew / NoteDeferList 定义在 lib\note-window.ahk 里（用它们的地方在那儿），
   这里只保证 note.ahk 的外部调用不需要知道细节。 */
NoteShowAllSoon() {
    SetTimer(NoteShowAll, -10)
}
NoteFontSave() => App.SaveFontSize()
NoteToggle() => App.ToggleAll()
/* Ctrl+N 的条件：只有列表窗口是前台时才生效。
   必须用命名函数：实测内联箭头传给 HotIf 会报 "Invalid callback function"。 */
ListHotkeyCond(hk) => ListWindow.IsActive()
NoteReloadTick() => App.ReloadAll()
NoteOpen(id) => App.OpenNote(id)
NoteDelete(id) => App.DeleteNote(id)
NoteHide(id) => App.HideNote(id)
NoteRename(id) => App.RenameNote(id)
NotePin(id, on) => App.SetPin(id, on)
NoteColor(id, color) => App.SetColor(id, color)
NoteShowAll() => App.ShowAll()
NoteHideAll() => App.HideAll()
NoteDataDir() => App.OpenDataDir()
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
