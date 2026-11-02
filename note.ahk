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
#Include lib\export.ahk
#Include lib\win.ahk
#Include lib\WebView2\WebView2.ahk
#Include lib\note-window.ahk
#Include lib\list-window.ahk
#Include lib\settings-window.ahk

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
    static Bound := 0          ; Map: 热键名 -> 当前真正注册成功的键串
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

        /* 启动行为（设置面板里可改）。等 Boot 把窗口建完再动作，
           否则会和 BootTick 抢着建窗口。 */
        if App.Cfg("app", "showAllOnStart", 0)
            SetTimer(NoteShowAllSoon, -2200)
        if App.Cfg("app", "openListOnStart", 0)
            SetTimer(NoteDeferList, -2600)

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
        if App.HasArg("--selftest-note")
            SetTimer(SelfTestNote, -2500)
        if App.HasArg("--selftest-edit")
            SetTimer(SelfTestEdit, -2500)
        if App.HasArg("--selftest-export")
            SetTimer(SelfTestExport, -2500)
        if App.HasArg("--selftest-settings")
            SetTimer(SelfTestSettings, -2500)
        if App.HasArg("--shot-settings")
            SetTimer(SelfTestShotSettings, -2500)
        if App.HasArg("--shot-code")
            SetTimer(SelfTestShotCode, -2500)

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
            "onExport", NoteExport,
            "onPin", NotePin,
            "onColor", NoteColor,
            "onShowAll", NoteShowAll,
            "onHideAll", NoteHideAll,
            "onDataDir", NoteDataDir,
            "onSettings", NoteShowSettings,
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

    ; 导出（列表窗口的右键菜单走这里；便签窗口自己有一份 ExportAs）
    static ExportNote(id, fmt) {
        n := App.Store.Get(id)
        if !n {
            App.Toast("这张便签已经不在了")
            return
        }
        Export.Save(n, fmt)
    }

    /* ---- 设置面板 -----------------------------------------------------------
       页面只负责表单，合法性判断和"怎么生效"全在这儿，避免两边各写一套。 */

    static ShowSettings() {
        SettingsWindow.Ctx := App.Ctx
        SettingsWindow.Hooks := Map(
            "onSave", NoteApplySettings,
            "onDataDir", NoteDataDir,
            "onLog", NoteOpenLog)
        SettingsWindow.Open()
    }

    /* 返回错误文案，空串 = 成功。
       顺序很重要：先校验热键 → 全部合法才落盘 → 再逐项生效。
       校验失败时要把原来的热键重新绑回去（TestHotkey 会临时注册再注销）。 */
    static ApplySettings(raw) {
        fs := JsonNum(raw, "fontSize", App.FONT_DEFAULT)
        fs := Max(App.FONT_MIN, Min(App.FONT_MAX, fs))

        hs := Map(
            "new", Trim(JsonStr(raw, "hkNew", "")),
            "list", Trim(JsonStr(raw, "hkList", "")),
            "toggle", Trim(JsonStr(raw, "hkToggle", "")))

        for name, key in hs {
            if (key = "")
                continue
            e := App.TestHotkey(key)
            if (e != "") {
                App.RebindHotkeys(App.CfgHotkeys())
                return "「" App.HotkeyLabel(name) "」" e
            }
        }

        App.SetCfg("hotkey", "new", hs["new"])
        App.SetCfg("hotkey", "list", hs["list"])
        App.SetCfg("hotkey", "toggle", hs["toggle"])
        showAll := JsonNum(raw, "showAllOnStart", 0) ? 1 : 0
        openList := JsonNum(raw, "openListOnStart", 0) ? 1 : 0
        App.SetCfg("app", "showAllOnStart", showAll)
        App.SetCfg("app", "openListOnStart", openList)

        App.SetFontSize(fs)
        App.RebindHotkeys(hs)

        tr := JsonNum(raw, "transparent", 1) ? 1 : 0
        if (tr != (App.Ctx.appearance.transparent ? 1 : 0)) {
            App.Ctx.appearance.transparent := tr
            App.SetCfg("appearance", "transparent", tr)
            ; 重建所有窗口是重活，别在消息线程里做
            SetTimer(NoteReloadTick, -10)
        }
        App.Log("设置已保存：字号 " fs "，透明 " tr
            "，启动显示全部 " showAll "，启动开列表 " openList)
        return ""
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
        t.Add("设置…", (*) => NoteShowSettings())
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
        App.RebindHotkeys(App.CfgHotkeys())
        App.BindListKeys()
    }

    ; 配置里的三个热键原样读出来（设置面板保存失败时用它把状态恢复回去）
    static CfgHotkeys() {
        return Map(
            "new", App.Cfg("hotkey", "new", "^!n"),
            "list", App.Cfg("hotkey", "list", "^!l"),
            "toggle", App.Cfg("hotkey", "toggle", "^!h"))
    }

    static HotkeyLabel(name) {
        switch name {
            case "new": return "新建便签"
            case "list": return "打开便签列表"
            case "toggle": return "显示/收起全部"
        }
        return name
    }

    static HotkeyFn(name) {
        switch name {
            case "new": return NoteDeferNew
            case "list": return NoteDeferList
            case "toggle": return NoteToggle
        }
        return 0
    }

    /* 先注销旧的再绑新的。App.Bound 记的是"真正注册成功了什么"，
       不靠读配置 —— 配置里可能存着非法键，那种是绑不上的。 */
    static RebindHotkeys(hs) {
        if !IsObject(App.Bound)
            App.Bound := Map()
        for name, key in App.Bound.Clone() {
            if (key = "")
                continue
            try Hotkey(key, "Off")
        }
        App.Bound := Map()
        for name, key in hs {
            if (key = "")
                continue
            if App.BindOne(key, App.HotkeyFn(name)) {
                App.Bound[name] := key
                App.Log("热键已注册：" App.HotkeyLabel(name) " = " key)
            } else
                App.Log("热键注册失败：" App.HotkeyLabel(name) " = " key)
        }
    }

    /* 试注册一次看合不合法。它有副作用：成功时会真的注册上，紧接着的 "Off"
       又注销掉，所以调用方必须在之后整体重绑一次。 */
    static TestHotkey(key) {
        key := Trim(key)
        if (key = "")
            return ""
        try {
            Hotkey(key, (*) => 0, "On")
            Hotkey(key, "Off")
            return ""
        } catch as e {
            return "不是合法的热键（" CleanComError(e.Message) "）"
        }
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
    ; 返回 1/0：注册失败（键名非法、被别的程序占了）不算致命，但调用方要知道，
    ; 否则设置面板会把"根本没绑上"当成保存成功
    static BindOne(key, fn) {
        if (key = "" || !fn)
            return 0
        try {
            Hotkey(key, (*) => fn.Call(), "On")
            return 1
        } catch as e {
            App.Log("热键 " key " 注册失败：" CleanComError(e.Message))
            return 0
        }
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
        text .= "[app]`r`n"
        text .= "; 启动时把所有便签都显示出来（否则只恢复上次没收起的）`r`n"
        text .= "showAllOnStart=0`r`n"
        text .= "; 启动时打开便签列表`r`n"
        text .= "openListOnStart=0`r`n`r`n"
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

/* ExecuteScriptAsync 的返回值是 JSON 编码过的：数字原样，字符串会带引号
   （"1" 而不是 1），尖括号还会被转成 \u003C。断言前统一走这里。 */
JStr(v) {
    return Trim(StrReplace(v, Chr(34), ""))
}

RichSay(name, ok, detail := "") {
    global RICH_PASS, RICH_FAIL
    if ok
        RICH_PASS += 1
    else
        RICH_FAIL += 1
    App.Log((ok ? "PASS " : "FAIL ") name (detail != "" ? "  [" detail "]" : ""))
}

; 给 README 拍一张设置面板的截图
ShotSettings(path) {
    w := SettingsWindow.Win
    if !w
        return false
    return ShotWv(w.wv, path)
}

; 给 README 拍一张"带代码着色的便签"
ShotNote(w, path) {
    if !w
        return false
    return ShotWv(w.wv, path)
}

/* 把一个 WebView2 的当前画面拍成 PNG。原来只有设置面板需要，加了代码着色的
   截图功能之后两条路都要用，抽出来。 */
ShotWv(wv, path) {
    pStream := 0
    hr := DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", 1, "ptr*", &pStream, "int")
    if (hr != 0 || !pStream)
        return false
    try {
        wv.CapturePreviewAsync(0, pStream).await()
        hGlobal := 0
        DllCall("ole32\GetHGlobalFromStream", "ptr", pStream, "ptr*", &hGlobal)
        size := DllCall("kernel32\GlobalSize", "ptr", hGlobal, "uptr")
        p := DllCall("kernel32\GlobalLock", "ptr", hGlobal, "ptr")
        if (!p || !size)
            return false
        data := Buffer(size)
        DllCall("RtlMoveMemory", "ptr", data, "ptr", p, "uptr", size)
        DllCall("kernel32\GlobalUnlock", "ptr", hGlobal)
        if FileExist(path)
            FileDelete path
        f := FileOpen(path, "w")
        f.RawWrite(data, size)
        f.Close()
        return true
    }
    return false
}

SelfTestShotSettings() {
    try {
        App.ShowSettings()
        Sleep 3000
        ok := ShotSettings(A_ScriptDir "\assets\shot-settings.png")
        App.Log("SHOT settings=" ok)
    }
    SettingsWindow.Close()
    SelfTestDone()
}

/* 给 README 拍一张"带代码着色"的便签截图：这段就是用户看到的样子，
   肉眼看一眼比一堆断言更能确认配色没有跟便签底色打架。 */
SelfTestShotCode() {
    w := 0
    try {
        w := App.NewNote()
        Loop 40 {
            if w && w.ready
                break
            Sleep 100
        }
        ; 便签默认窗口偏小，临时撑大一点，截图才放得下代码
        if w && w.gui
            WinMove(, , 420, 480, "ahk_id " w.gui.Hwnd)
        if w && w.wvc
            w.wvc.Fill()
        Sleep 300
        RichEval(w, "
        ( LTrim Join
        (function(){
          const ed = document.getElementById('editor');
          ed.innerHTML = '<h2>代码着色</h2>'
            + '<p>光标移开代码块之后自动上色，<b>正文一个字符都不会变</b>。</p>'
            + '<pre><code class=""language-js"">'
            + 'function greet(name) {'
            + '\n' + '  const msg = \"hello \" + name;'
            + '\n' + '  // 行注释'
            + '\n' + '  return msg;'
            + '\n' + '}'
            + '</code></pre>'
            + '<pre><code class=""language-python"">'
            + 'def fib(n):'
            + '\n' + '    return n if n < 2 else fib(n-1) + fib(n-2)'
            + '</code></pre>'
            + '<p>右侧 <b>⋯</b> 是便签菜单，正文里右键是编辑菜单。</p>';
          window.CodeHL.paintAll(ed, { force: true });
          return 1;
        })()
        )")
        Sleep 600
        ok := ShotNote(w, A_ScriptDir "\assets\shot-code.png")
        App.Log("SHOT code=" ok)
        if w
            App.DeleteNote(w.id)
    } catch as e {
        App.Log("SHOT code 失败：" CleanComError(e.Message) " @" e.Line)
    }
    SelfTestDone()
}

/* 自检：设置面板。分两段验：
   1) 窗口能开、页面能收到 init（用 ExecuteScript 读回表单值来证明）
   2) ApplySettings 真能落盘并生效，且非法热键会被拦下、原配置不被动坏 */
SelfTestSettings() {
    try SelfTestSettingsRun()
    catch as e {
        App.Log("SELFTEST SETTINGS 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST SETTINGS 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestSettingsRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0

    ; 记下原始值，测完恢复，别把测试配置留在用户机器上
    oldFs := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    oldHk := App.Cfg("hotkey", "new", "^!n")
    oldAll := App.Cfg("app", "showAllOnStart", 0)

    App.ShowSettings()
    Sleep 2600
    RichSay("设置窗口打开了", SettingsWindow.IsOpen() = 1)

    w := SettingsWindow.Win
    if !w {
        App.Log("SELFTEST SETTINGS 结论：未通过（窗口没建起来）")
        return
    }

    ; 页面侧：字段应该已经被 init 填好
    fsInPage := JStr(RichEval(w, "document.getElementById('fontSize').value"))
    hkInPage := JStr(RichEval(w, "document.getElementById('hkNew').value"))
    RichSay("页面读到了字号", fsInPage = String(oldFs), fsInPage " vs " oldFs)
    RichSay("页面读到了热键", hkInPage = oldHk, hkInPage " vs " oldHk)

    ; 非法热键：应当报错，且配置不被改坏
    badRaw := '{"type":"save","fontSize":19,"transparent":1,"showAllOnStart":0,'
        . '"openListOnStart":0,"hkNew":"Ctrl+","hkList":"","hkToggle":""}'
    err := App.ApplySettings(badRaw)
    RichSay("非法热键被拦下", err != "", err)
    RichSay("拦截后字号没被改", App.Cfg("appearance", "fontSize", App.FONT_DEFAULT) = oldFs)
    RichSay("拦截后原热键仍注册着", App.Bound.Has("new") && App.Bound["new"] = oldHk,
        App.Bound.Has("new") ? App.Bound["new"] : "(无)")

    ; 合法保存：字号 + 新热键 + 启动显示全部
    goodRaw := '{"type":"save","fontSize":18,"transparent":1,"showAllOnStart":1,'
        . '"openListOnStart":0,"hkNew":"^!j","hkList":"^!l","hkToggle":""}'
    err2 := App.ApplySettings(goodRaw)
    RichSay("合法配置保存成功", err2 = "", err2)
    RichSay("字号立即生效", App.Ctx.appearance.fontSize = 18, App.Ctx.appearance.fontSize)
    ; 落盘是 400ms 合并写（按住 Ctrl+滚轮 会连发几十次），所以等一下再看文件
    Sleep 700
    RichSay("字号已落盘", App.Cfg("appearance", "fontSize", 0) = 18,
        App.Cfg("appearance", "fontSize", 0))
    RichSay("新热键已注册", App.Bound.Has("new") && App.Bound["new"] = "^!j",
        App.Bound.Has("new") ? App.Bound["new"] : "(无)")
    RichSay("清空的热键不再注册", !App.Bound.Has("toggle"), App.Bound.Has("toggle") ? 1 : 0)
    RichSay("启动项已落盘", App.Cfg("app", "showAllOnStart", 0) = 1)

    ; 改回来
    backRaw := '{"type":"save","fontSize":' oldFs ',"transparent":1,'
        . '"showAllOnStart":' (oldAll ? 1 : 0) ',"openListOnStart":0,'
        . '"hkNew":' JsonQuote(oldHk) ',"hkList":"^!l","hkToggle":"^!h"}'
    err3 := App.ApplySettings(backRaw)
    RichSay("恢复原配置", err3 = "", err3)
    RichSay("恢复后热键回来了", App.Bound.Has("new") && App.Bound["new"] = oldHk,
        App.Bound.Has("new") ? App.Bound["new"] : "(无)")
    ; 字号写盘是 400ms 合并的，不等一下就直接退出进程，定时器被掐掉，
    ; 配置会停在测试值上（第一次跑就踩了：用户拿到的是 18）
    Sleep 700
    RichSay("字号已恢复", App.Cfg("appearance", "fontSize", 0) = oldFs,
        App.Cfg("appearance", "fontSize", 0))

    SettingsWindow.Close()
    Sleep 300
    RichSay("设置窗口能关掉", SettingsWindow.IsOpen() = 0)

    App.Log("SELFTEST SETTINGS 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
}

/* 自检：四种导出格式。不走 FileSelect（会卡住无人值守的测试），
   直接调 Export.Render 拿字符串断言，顺带真写一个 txt 验编码。 */
SelfTestExport() {
    try SelfTestExportRun()
    catch as e {
        App.Log("SELFTEST EXPORT 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST EXPORT 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestExportRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    BT := Chr(96)

    ; 一张 1x1 的 PNG 落在图片目录里，用来验 HTML 的内嵌图片
    imgDir := App.DataDir "\images"
    if !DirExist(imgDir)
        DirCreate imgDir
    imgPath := imgDir "\_export-test.png"
    b64 := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    buf := NoteWindow.B64Decode(b64)
    try {
        f := FileOpen(imgPath, "w")
        f.RawWrite(buf, buf.Size)
        f.Close()
    }

    md := "# 标题一`n`n"
    md .= "普通**粗体**和*斜体*，还有~~删除线~~和" BT "code" BT "。`n`n"
    md .= "- 列表项`n- [ ] 待办一`n- [x] 待办二`n`n"
    md .= "1. 有序一`n2. 有序二`n`n"
    md .= "> 引用一行`n`n"
    md .= BT BT BT "js`nvar a = 1;`n" BT BT BT "`n`n"
    md .= "---`n`n"
    md .= "[链接](https://example.com) 和 ![图](" NoteWindow.FileUrl(imgPath) ")`n"

    note := {
        title: "导出测试：标题/含非法字符",
        body_md: md,
        body_text: "标题一`n`n普通粗体和斜体，还有删除线和 code。`n`n列表项`n待办一`n待办二",
        body_html: "<h1>标题一</h1><p>普通<b>粗体</b>和<i>斜体</i></p>"
            . "<p><img src=`"" NoteWindow.FileUrl(imgPath) "`" alt=`"图`"></p>"
            . "<pre><code data-lang=`"js`"><span class=`"hljs-keyword`">var</span>"
            . " a = <span class=`"hljs-number`">1</span>;</code></pre>",
        mode: "rich"
    }

    ; ---- TXT：纯文本，不能残留任何标记 ----
    txt := Export.Render(note, "txt")
    RichSay("TXT 用 body_text 原文", InStr(txt, "普通粗体和斜体") > 0, SubStr(txt, 1, 40))
    RichSay("TXT 不含 HTML 标签", InStr(txt, "<") = 0 && InStr(txt, "**") = 0)
    RichSay("TXT 不含 Markdown 标记", InStr(txt, "~~") = 0 && InStr(txt, "# ") = 0)

    ; ---- MD ----
    mdOut := Export.Render(note, "md")
    RichSay("MD 原样输出 body_md", mdOut = md, SubStr(mdOut, 1, 30))

    ; ---- HTML ----
    html := Export.Render(note, "html")
    RichSay("HTML 有完整文档结构", InStr(html, "<!DOCTYPE html>") > 0 && InStr(html, "</html>") > 0)
    RichSay("HTML 保留正文标签", InStr(html, "<h1>标题一</h1>") > 0)
    RichSay("HTML 图片内嵌成 data URI", InStr(html, "data:image/png;base64,iVBOR") > 0)
    RichSay("HTML 不再引用 file://", InStr(html, "file:///") = 0)
    RichSay("HTML 标题做了转义处理", InStr(html, "<title>导出测试") > 0)
    /* 代码着色要跟着走：正文里的 token span 保留，色板也内联进 <style>，
       否则导出后别人打开是一坨黑字，跟便签里看到的完全不是一回事。 */
    RichSay("HTML 保留代码着色 span", InStr(html, "hljs-keyword") > 0)
    RichSay("HTML 内联了着色色板", InStr(html, ".hljs-string") > 0 || InStr(html, ".hljs-comment") > 0)
    RichSay("HTML 的代码块不再是白底", InStr(html, "background:transparent") > 0)

    ; ---- RTF ----
    rtf := Export.Render(note, "rtf")
    RichSay("RTF 头部正确", SubStr(rtf, 1, 6) = "{\rtf1", SubStr(rtf, 1, 20))
    RichSay("RTF 中文转成 \\uNNNN", InStr(rtf, "\u") > 0)
    RichSay("RTF 没有裸中文", !RegExMatch(rtf, "[^\x00-\x7F]"))
    RichSay("RTF 粗体/斜体/删除线", InStr(rtf, "{\b ") > 0 && InStr(rtf, "{\i ") > 0 && InStr(rtf, "{\strike ") > 0)
    RichSay("RTF 列表与待办", InStr(rtf, "\bullet") > 0 && InStr(rtf, "\u9744") > 0)
    RichSay("RTF 代码块用等宽字体", InStr(rtf, "\f1\fs18 ") > 0)
    RichSay("RTF 链接用 HYPERLINK 域", InStr(rtf, "HYPERLINK") > 0)
    RichSay("RTF 花括号配对（粗检）", Export_RtfBalanced(rtf))

    ; ---- 真写一个文件，验编码（BOM + 中文） ----
    outTxt := App.DataDir "\_export-test.txt"
    try {
        f := FileOpen(outTxt, "w", "UTF-8")
        f.Write(txt)
        f.Close()
    }
    raw := ""
    try raw := FileRead(outTxt, "UTF-8")
    RichSay("TXT 落盘可回读", InStr(raw, "普通粗体和斜体") > 0)

    ; ---- 文件名清洗 ----
    stem := Export.FileStem(note)
    RichSay("文件名过滤了非法字符", !RegExMatch(stem, '[\\/:*?"<>|]'), stem)

    App.Log("SELFTEST EXPORT 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    ; 清理
    for f2 in [outTxt, imgPath]
        try FileDelete f2
}

/* RTF 的括号必须严格配对，否则 Word 直接报"无法打开"。
   快速数一遍（\\ 后的花括号是转义的，不算结构）。 */
Export_RtfBalanced(s) {
    depth := 0
    Loop StrLen(s) {
        ch := SubStr(s, A_Index, 1)
        if (ch = "\") {
            A_Index += 1
            continue
        }
        if (ch = "{")
            depth++
        else if (ch = "}") {
            depth--
            if (depth < 0)
                return false
        }
    }
    return depth = 0
}

/* 自检：Ctrl+V 粘贴链路 / 图片限高与看大图 / 右上角 X 改成收起。
   本机注入物理键盘会卡死（见 README），所以这里直接往 document.body 上
   dispatch 一个 ClipboardEvent —— 这恰好能验到最关键的一点：监听挂在
   document 上，焦点不在编辑区也照样收得到（用户报的 Ctrl+V 失效正是这个）。 */
SelfTestNote() {
    try SelfTestNoteRun()
    catch as e {
        App.Log("SELFTEST NOTE 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST NOTE 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestNoteRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0

    w := App.NewNote()
    if !w {
        App.Log("SELFTEST NOTE 没能建出便签")
        return
    }
    id := w.id
    Loop 40 {
        if w.ready
            break
        Sleep 100
    }
    RichSay("页面就绪", w.ready = 1, w.ready)

    /* 1) 粘到 body 上（模拟"焦点不在编辑区"）：画一张图塞进 DataTransfer，
         再派发 paste。内容不经过系统剪贴板，但走的是同一条页面代码路径。 */
    imgDir := App.DataDir "\images"
    before := 0
    Loop Files (imgDir "\*.*")
        before++

    RichEval(w, "(function(){var c=document.createElement('canvas');c.width=8;c.height=8;"
        . "var g=c.getContext('2d');g.fillStyle='#d04040';g.fillRect(0,0,8,8);"
        . "var b=atob(c.toDataURL('image/png').split(',')[1]);"
        . "var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);"
        . "var dt=new DataTransfer();dt.items.add(new File([a],'x.png',{type:'image/png'}));"
        . "document.body.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));"
        . "return 1})()")
    Sleep 2000

    hasImg := RichEval(w, "document.querySelector('#editor img')?1:0")
    after := 0
    Loop Files (imgDir "\*.*")
        after++
    RichSay("粘贴到 body 也能插图（焦点无关）", JStr(hasImg) = "1", hasImg)
    RichSay("图片落盘", after = before + 1, before " -> " after)

    /* 2) 限高：正文里的图 max-height 必须是 180px，否则大图会把便签撑满 */
    mh := RichEval(w, "(function(){var i=document.querySelector('#editor img');"
        . "return i?getComputedStyle(i).maxHeight:'NONE'})()")
    mh := JStr(mh)
    RichSay("图片被限高（max-height）", mh = "180px", mh)

    /* 3) 点图 → 遮罩出现；再点遮罩 → 关掉 */
    out := RichEval(w, "(function(){var i=document.querySelector('#editor img');i.click();"
        . "return document.getElementById('lightbox').hidden?'0':'1'})()")
    RichSay("点图片打开大图遮罩", JStr(out) = "1", out)
    boxed := RichEval(w, "(function(){var l=document.getElementById('lightbox');"
        . "var src=document.getElementById('lightboxImg').getAttribute('src')||'';"
        . "l.click();return (src.indexOf('file:///')>=0 && l.hidden)?'1':'0'})()")
    RichSay("遮罩里是原图且能关掉", JStr(boxed) = "1", boxed)

    /* 4) X = 收起（不是删除）：便签还在库里，只是 hidden=1 */
    RichEval(w, "document.getElementById('btnClose').click();1")
    Sleep 900
    row := App.Store.Get(id)
    RichSay("点 X 后便签还在库里", IsObject(row) ? 1 : 0)
    RichSay("点 X 只收起不删除（hidden=1）", row && row.hidden = 1, row ? row.hidden : "no row")

    App.Log("SELFTEST NOTE 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    ; 收尾：自检建的这张删掉，别留在用户库里
    App.DeleteNote(id)
}

/* ============================================================================
   自检：大图粘贴 / Ctrl+S 回执 / 代码块出路 / 代码着色 / 编辑菜单命令

   这几条对应一轮真实的用户反馈，坑点如下：
     · 大图粘贴 —— 图片 base64 有几 MB，宿主 JsonStr 的正则在 800KB 上就撞
       PCRE match limit。以前这里用的是 8x8 的小图（base64 才几百字节），
       所以"自检全绿、用户一粘就废"。现在故意造一张 700×700 的噪点图，
       base64 上到 1MB 以上，跑不通就说明回归了。
     · Ctrl+S —— 要看得见的回执，不能按下去毫无反应。
     · 代码块 —— 插进去之后光标必须出得来（回车/Shift+Enter/↓ 三条路）。
     · 着色 —— 光标离开代码块时补色，且正文一个字符都不能变。

   本机用 SendInput 注入键盘会卡死（见 README），所以按键一律在页面里
   dispatchEvent 造 KeyboardEvent，走的是真实的 keydown 监听。
   ========================================================================== */
SelfTestEdit() {
    try SelfTestEditRun()
    catch as e {
        App.Log("SELFTEST EDIT 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST EDIT 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestEditRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0

    w := App.NewNote()
    if !w {
        App.Log("SELFTEST EDIT 没能建出便签")
        return
    }
    id := w.id
    Loop 40 {
        if w.ready
            break
        Sleep 100
    }
    RichSay("页面就绪", w.ready = 1, w.ready)

    RichEval(w, "
    ( LTrim Join
    window.__e = {
      ed: () => document.getElementById('editor'),
      put(h) { this.ed().innerHTML = h; },
      all() {
        const r = document.createRange();
        r.selectNodeContents(this.ed());
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
      },
      click(c) { document.querySelector('[data-cmd=\"' + c + '\"]').click(); },
      pre() { return this.ed().querySelector('pre'); },
      caretEnd(el) {
        const r = document.createRange();
        r.selectNodeContents(el); r.collapse(false);
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
      },
      caretAt(el, off) {
        const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let acc = 0, n, last = null;
        while ((n = w.nextNode())) {
          const len = n.nodeValue.length;
          if (off <= acc + len) {
            const r = document.createRange();
            r.setStart(n, Math.max(0, off - acc));
            r.collapse(true);
            const s = getSelection(); s.removeAllRanges(); s.addRange(r);
            return 1;
          }
          acc += len; last = n;
        }
        if (last) this.caretEnd(el);
        return 0;
      },
      key(k, mod) {
        const ev = new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true,
          ctrlKey: !!(mod && mod.ctrl), shiftKey: !!(mod && mod.shift) });
        this.ed().dispatchEvent(ev);
        return ev.defaultPrevented ? 1 : 0;
      },
      caretIn(sel) { const s = getSelection(); return (s.rangeCount && sel.contains(s.anchorNode)) ? 1 : 0; },
      status() { return document.getElementById('status').className + '|' + document.getElementById('hint').textContent; }
    };
    1;
    )")

    ; ---- 0. 右键落点分两套菜单（把 postMessage 拦下来看它到底发了什么）----
    /* 原生菜单没法自动点，但"页面到底有没有按落点区分"是能验的：
       临时替换 chrome.webview.postMessage，dispatch 一个 contextmenu，
       把消息捞出来即可 —— 消息被截住了，宿主那边不会真弹菜单。 */
    rawZones := RichEval(w, "
    ( LTrim Join
    (function(){
      const br = window.chrome.webview;
      const orig = br.postMessage.bind(br);
      let last = null;
      br.postMessage = function(m){ last = m; };
      const fire = function(el){
        last = null;
        el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
        return last || {};
      };
      const ed = document.getElementById('editor');
      ed.innerHTML = '<p>正文</p><pre><code>var a = 1;</code></pre>';
      const a = fire(ed);
      const c = fire(ed.querySelector('pre'));
      const b = fire(document.querySelector('.bar'));
      br.postMessage = orig;
      ed.innerHTML = '';
      return (a.zone || '-') + '|' + (b.zone || '-') + '|' + (c.inpre || 0);
    })()
    )")
    zones := JStr(rawZones)
    zp := StrSplit(zones, "|")
    zEd := zp.Length >= 1 ? zp[1] : ""
    zBar := zp.Length >= 2 ? zp[2] : ""
    zPre := zp.Length >= 3 ? zp[3] : ""
    RichSay("正文右键 → 编辑菜单（zone=edit）", zEd = "edit", zones)
    RichSay("标题栏右键 → 便签菜单（zone=note）", zBar = "note", zones)
    RichSay("代码块里右键会带上 inpre（露出「代码语言」）", zPre = "1", zones)

    ; ---- 1. 大图粘贴：一张 700×700 噪点图，base64 一定超过 1MB -------------
    imgDir := App.DataDir "\images"
    before := 0
    seen := Map()                     ; 自检会往图片目录里写文件，收尾要清干净
    Loop Files (imgDir "\*.*") {
        before++
        seen[A_LoopFileName] := 1
    }

    b64len := RichEval(w, "
    ( LTrim Join
    (function(){
      const n = 700, c = document.createElement('canvas');
      c.width = n; c.height = n;
      const g = c.getContext('2d'), d = g.createImageData(n, n);
      let x = 123456789;
      for (let i = 0; i < d.data.length; i += 4) {
        x = (x * 1103515245 + 12345) & 0x7fffffff;
        d.data[i] = x & 255; d.data[i+1] = (x >> 8) & 255;
        d.data[i+2] = (x >> 16) & 255; d.data[i+3] = 255;
      }
      g.putImageData(d, 0, 0);
      const u = c.toDataURL('image/png');
      const b = atob(u.split(',')[1]);
      const a = new Uint8Array(b.length);
      for (let i = 0; i < b.length; i++) a[i] = b.charCodeAt(i);
      const dt = new DataTransfer();
      dt.items.add(new File([a], 'big.png', { type: 'image/png' }));
      document.body.dispatchEvent(new ClipboardEvent('paste',
        { clipboardData: dt, bubbles: true, cancelable: true }));
      return u.length;
    })()
    )")
    n64 := Number(JStr(b64len))
    ; 这条断言是自检的"体检"：base64 太短就复现不了老 bug，测了等于没测
    RichSay("测试图够大（base64 > 800KB，老代码在这里崩）", n64 > 800000, n64)

    ; 存盘 + 回 URL 需要时间（2MB base64 走一遍 postMessage / 解码 / 写盘）
    Loop 40 {
        pending := JStr(RichEval(w, "document.querySelectorAll('#editor img.pending').length"))
        if (pending = "0")
            break
        Sleep 250
    }
    Sleep 300
    hasImg := JStr(RichEval(w, "document.querySelector('#editor img')?1:0"))
    src := JStr(RichEval(w, "(document.querySelector('#editor img')||{}).src||''"))
    left := JStr(RichEval(w, "document.querySelectorAll('#editor img.pending').length"))
    after := 0
    Loop Files (imgDir "\*.*")
        after++

    RichSay("大图粘贴：图出现在正文里", hasImg = "1", "img=" hasImg)
    RichSay("大图粘贴：占位框没有残留", left = "0", "pending=" left)
    RichSay("大图粘贴：src 是 file:// 链接", InStr(src, "file:///") > 0, SubStr(src, 1, 70))
    RichSay("大图粘贴：图片落盘", after = before + 1, before " -> " after)

    ; ---- 2. Ctrl+S：按下去要有回执 -----------------------------------------
    RichEval(w, "__e.put('<p>Ctrl+S 测试</p>');1")
    Sleep 200
    prevented := RichEval(w, "__e.key('s', {ctrl:true})")
    RichSay("Ctrl+S 被页面接管（不会触发浏览器保存）", JStr(prevented) = "1", prevented)
    Sleep 700
    st := JStr(RichEval(w, "__e.status()"))
    RichSay("Ctrl+S 后状态栏出现『已保存』", InStr(st, "已保存") > 0, st)
    RichSay("Ctrl+S 的回执是强调样式（status.ok）", InStr(st, "ok") > 0, st)

    ; ---- 3. 代码块：三条出路 ------------------------------------------------
    RichEval(w, "__e.put('<p>x</p>');__e.all();1")
    Sleep 150
    RichEval(w, "__e.click('codeblock');1")
    Sleep 250
    hasPre := JStr(RichEval(w, "__e.pre()?1:0"))
    RichSay("工具条能插入代码块", hasPre = "1", hasPre)

    RichEval(w, "(function(){var p=__e.pre();p.textContent='const a = 1;';__e.caretEnd(p);return 1})()")
    Sleep 120
    /* 光标在末尾按回车：应该"跳出去"，而不是在块里再加一行。
       判据 = 焦点落到了 <pre> 后面的兄弟节点里。 */
    RichEval(w, "__e.key('Enter',{})")
    Sleep 250
    rawOut := RichEval(w, "
    ( LTrim Join
    (function(){
      const p = __e.pre();
      const next = p.nextElementSibling;
      if (!next) return 'no-next';
      return __e.caretIn(next) ? '1' : '0';
    })()
    )")
    out := JStr(rawOut)
    RichSay("代码块末尾回车 → 光标跳出去", out = "1", out)

    /* 块里还有内容时按回车不能跳（那是在加行） */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='ab';__e.caretAt(p,1);return 1})()")
    Sleep 100
    mid := JStr(RichEval(w, "__e.key('Enter',{})"))
    RichSay("代码中间回车仍留在块里（不误跳）", mid = "0", mid)

    /* Shift+Enter 随时能跳出来 */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='a';__e.caretEnd(p);return 1})()")
    Sleep 100
    sh := JStr(RichEval(w, "__e.key('Enter',{shift:true})"))
    Sleep 250
    rawOut2 := RichEval(w, "
    ( LTrim Join
    (function(){ var p=__e.pre(); var next=p.nextElementSibling;
      return (next && __e.caretIn(next)) ? '1' : '0'; })()
    )")
    out2 := JStr(rawOut2)
    RichSay("Shift+Enter 直接跳出代码块", out2 = "1", out2)

    /* 空的代码块按退格，整块拆掉 */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='';__e.caretEnd(p);return 1})()")
    Sleep 100
    bs := JStr(RichEval(w, "__e.key('Backspace',{})"))
    Sleep 200
    gone := JStr(RichEval(w, "document.querySelectorAll('#editor pre').length"))
    RichSay("空代码块退格即拆掉", gone = "0", "剩下 " gone " 个 pre")

    ; ---- 4. 着色：光标离开后自动上色 ---------------------------------------
    /* 注意：这段 JS 用的是 ( LTrim Join 续行，Join 会把各行直接拼在一起，
       所以**不能写行注释**（两条斜杠那种）—— 它会把后面的行一起注掉，
       脚本直接语法错误、整段静默失效。第一次就是栽在这儿，三条断言全挂。
       要写注释就用块注释。 */
    RichEval(w, "
    ( LTrim Join
    (function(){
      const ed = __e.ed();
      ed.innerHTML = '<pre><code>const a = 1;</code></pre><div><br></div>';
      const p = ed.querySelector('pre');
      __e.caretEnd(p);
      return 1;
    })()
    )")
    Sleep 150
    /* 把光标移到后面那个段落：这一步会触发 selectionchange → 给前一块补色。 */
    RichEval(w, "(function(){var d=__e.ed().querySelector('div');__e.caretEnd(d);return 1})()")
    Sleep 600
    kw := JStr(RichEval(w, "document.querySelector('#editor pre .hljs-keyword')?1:0"))
    kept := JStr(RichEval(w, "__e.pre().textContent"))
    RichSay("光标离开后代码块上了色", kw = "1", "hljs-keyword=" kw)
    RichSay("着色不改代码正文", kept = "const a = 1;", kept)

    ; 显式指定语言（等价于右键菜单「代码语言」）
    RichEval(w, "(function(){window.CodeHL.setLang(__e.pre(),'python');window.CodeHL.paint(__e.pre());return 1})()")
    Sleep 150
    lang := JStr(RichEval(w, "__e.pre().getAttribute('data-lang')||''"))
    RichSay("能显式指定代码语言", lang = "python", lang)

    ; ---- 5. 编辑菜单的命令通路（宿主 → 页面 runCmd） -----------------------
    RichEval(w, "document.querySelector('#editor').focus();1")
    w.Send('{"type":"cmd","name":"select-all"}')
    Sleep 300
    rawAll := RichEval(w, "
    ( LTrim Join
    (function(){
      const s = getSelection();
      if (!s.rangeCount) return '0';
      const t = s.toString();
      return t.length > 0 ? '1' : '0';
    })()
    )")
    all := JStr(rawAll)
    RichSay("编辑菜单「全选」生效", all = "1", all)

    w.Send('{"type":"cmd","name":"undo"}')
    Sleep 250
    RichSay("编辑菜单「撤销」不报错", 1)

    App.Log("SELFTEST EDIT 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    App.DeleteNote(id)
    ; 清掉自检写进图片目录的噪点图，别把用户的数据目录当垃圾桶
    Loop Files (imgDir "\*.*") {
        if !seen.Has(A_LoopFileName)
            try FileDelete A_LoopFilePath
    }
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
NoteExport(id, fmt) => App.ExportNote(id, fmt)
NoteApplySettings(raw) => App.ApplySettings(raw)
/* 打开设置要建 WebView2 controller（await），绝不能在菜单回调/COM 回调里直接做
   —— 那会重现"点完菜单什么都没反应"的老 bug。统一换到独立线程。 */
NoteShowSettings() {
    SetTimer(NoteOpenSettings, -10)
}

NoteOpenSettings() => App.ShowSettings()
NotePin(id, on) => App.SetPin(id, on)
NoteColor(id, color) => App.SetColor(id, color)
NoteShowAll() => App.ShowAll()
NoteHideAll() => App.HideAll()
NoteDataDir() => App.OpenDataDir()
NoteOpenLog() => App.OpenLog()
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
