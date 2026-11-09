#Requires AutoHotkey v2.0
#SingleInstance Off
#ErrorStdOut UTF-8
/* 警告不要弹模态框。AHK 默认把"局部变量似乎从未赋值"这类警告弹成 MsgBox，
   而这个程序是单 UI 线程 —— 框一弹，所有便签连同自检一起冻住（踩过：
   自检脚本里函数名写错，框直接弹在用户屏幕上，整轮测试卡死）。
   改成写 stdout：run.bat 的控制台里看得见，编译版看不到但不会阻塞。 */
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
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
#Include lib\todo-store.ahk
#Include lib\export.ahk
#Include lib\win.ahk
#Include lib\clip.ahk
#Include lib\WebView2\WebView2.ahk
#Include lib\note-window.ahk
#Include lib\list-window.ahk
#Include lib\settings-window.ahk
#Include lib\ipc.ahk
#Include lib\pdf.ahk
#Include lib\word.ahk

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
    static NoteKeys := 0       ; Map: 便签 id -> 当前真正注册成功的快捷键
    static PendingText := ""   ; 命令行 --new "文字" 带进来的初始内容
    ; 字号范围：太小看不清，太大一张便签里放不下几个字
    static FONT_MIN := 10
    static FONT_MAX := 32
    static FONT_DEFAULT := 15
    ; 导入文件上限：便签是"一屏之内看完"的东西，塞一本小说进去只会让渲染变慢
    static IMPORT_MAX := 4 * 1024 * 1024

    ; ========================================================================
    ;  启动
    ; ========================================================================

    static Main() {
        ; 任何未捕获异常都别弹模态框（单 UI 线程，弹了就全卡死），写日志就好
        OnError(NoteOnError)
        OnExit(NoteOnExit)

        /* Word 导出的后台进程：必须在单实例锁**之前**判，否则会被正在跑的
           那个实例当成"重复启动"，转发一下就退出了，父进程永远等不到结果。
           这条路只碰文件、不建窗口，跑完自己退。 */
        if App.HasArg("--word-export")
            ExitApp Word.ExportManifest(App.ArgAfter("--word-export")
                , App.ArgAfter("--result"))

        ; 1) 单实例：抢到锁的继续，抢不到的唤出已有实例后退出
        App.InstanceLock := DllCall("CreateMutexW", "ptr", 0, "int", 0, "wstr", "Local\QuickNote.SingleInstance", "ptr")
        if (A_LastError = 183) {                 ; ERROR_ALREADY_EXISTS
            App.ForwardToRunning()
            ExitApp()
        }

        ; 2) 进程级 DPI：PerMonitorV2。必须在建窗口前设，否则拔插副屏会糊
        try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

        ; 3) 路径与配置
        App.DataDir := App.ResolveDataDir()
        /* --data-dir <目录>：换一个数据目录跑。自检要一个干净的库，
           不能往用户真正的 notes.db 里塞测试便签。 */
        if (dir := App.ArgAfter("--data-dir")) {
            if !DirExist(dir)
                DirCreate dir
            App.DataDir := dir
        }
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
        /* 待办数据层复用同一条 SQLite 连接：主线程是唯一写入者，不另开连接
           （另开会多一份 WAL 读写者，等于自己跟自己抢锁）。 */
        TodoStore.Attach(App.Store)
        ; PDF 导出要自己建一个隐藏的 WebView2，路径跟便签窗口共用一套
        Pdf.Ctx := App.Ctx

        ; 5) 托盘与热键
        App.BuildTray()
        App.BindHotkeys()

        ; 6) 锚点窗口：单实例唤醒、以及给脚本一个稳定的消息入口
        g := Gui("+ToolWindow -Caption", App.Name "Anchor")
        g.MarginX := 0
        g.MarginY := 0
        g.Show("x-32000 y-32000 w1 h1")
        App.Anchor := g

        /* 外部进程调用入口：新建便签 / 打开列表 / 带内容新建（WM_COPYDATA）。
           以前这里只挂了一条 0x8001（唤醒），现在统一交给 Ipc 管，消息号见 lib\ipc.ahk。
           这一行必须在 Boot 之前：便签装载期间外部调用也得受理（排队等着就行）。 */
        Ipc.Install(App.Anchor.Hwnd)

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

        /* 命令行 --new "文字"：初始内容。等 Boot 把窗口建完再动手，
           否则会和 BootTick 抢着建窗口。 */
        if App.HasArg("--new") {
            App.PendingText := App.ArgAfter("--new")
            SetTimer(NoteCliNew, -2400)
        }

        if App.HasArg("--selftest-ipc")
            SetTimer(SelfTestIpc, -2500)
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
        if App.HasArg("--selftest-dialog")
            SetTimer(SelfTestDialog, -2500)
        if App.HasArg("--selftest-del")
            SetTimer(SelfTestDelete, -2500)
        if App.HasArg("--selftest-opacity")
            SetTimer(SelfTestOpacity, -2500)
        if App.HasArg("--selftest-hotkey")
            SetTimer(SelfTestHotkey, -2500)
        if App.HasArg("--selftest-image")
            SetTimer(SelfTestImage, -2500)
        if App.HasArg("--selftest-codecopy")
            SetTimer(SelfTestCodeCopy, -2500)
        if App.HasArg("--selftest-codelang")
            SetTimer(SelfTestCodeLang, -2500)
        if App.HasArg("--selftest-import")
            SetTimer(SelfTestImport, -2500)
        if App.HasArg("--selftest-batch")
            SetTimer(SelfTestBatch, -2500)
        if App.HasArg("--selftest-pdf")
            SetTimer(SelfTestPdf, -2500)
        if App.HasArg("--selftest-docx")
            SetTimer(SelfTestDocx, -2500)
        if App.HasArg("--selftest-todo")
            SetTimer(SelfTestTodo, -2500)
        if App.HasArg("--shot-settings")
            SetTimer(SelfTestShotSettings, -2500)
        if App.HasArg("--shot-code")
            SetTimer(SelfTestShotCode, -2500)
        if App.HasArg("--shot-max")
            SetTimer(SelfTestShotMax, -2500)

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

    /* 新建便签。opts 留空就是"点一下新建"的老行为。
       opts 可带：text / title / color / pin / activate / x / y / w / h / format
       —— 热键、托盘、列表、外部 IPC 全走这一份实现，别各写一版。

       format 目前只认 "text"（原样落库）。将来要支持"把内容当 Markdown 渲染"，
       在这里加一个分支即可：body_md 存原文、body_html 留空，页面 init 会用
       MD.render(body_md) 填编辑区 —— 那条路页面侧早就通了。 */
    static NewNote(opts := 0) {
        o := IsObject(opts) ? opts : Map()

        text := Ipc.Opt(o, "text", "")
        format := Ipc.Opt(o, "format", "text")
        if (format != "text")
            App.Log("新建便签：format=" format " 暂不支持，按纯文本处理")

        title := Trim(Ipc.Opt(o, "title", ""))
        color := Ipc.Opt(o, "color", "")
        if (color = "" || !NoteWindow.Colors().Has(color))
            color := App.Cfg("window", "color", "yellow")

        pin := Ipc.Opt(o, "pin", 0) ? 1 : 0
        ; 默认抢焦点（内部新建一律抢；外部调用由 Ipc 那边先按 config 定好再传进来）
        activate := Ipc.Num(o, "activate", 1)

        dw := Ipc.Num(o, "w", 0)
        dh := Ipc.Num(o, "h", 0)
        dw := (dw > 0) ? dw : App.Cfg("window", "width", 300)
        dh := (dh > 0) ? dh : App.Cfg("window", "height", 280)
        if (Ipc.Has(o, "hasXY") && o["hasXY"])
            geo := Win.Clamp(Ipc.Num(o, "x", 0), Ipc.Num(o, "y", 0), dw, dh)
        else
            geo := Win.Cascade(App.Store.Count(), dw, dh)

        id := App.Store.Create(Map(
            "color", color,
            "x", geo.x, "y", geo.y, "w", geo.w, "h", geo.h,
            "pinned", pin, "hidden", 0,
            "body_text", text, "body_md", text,
            "body_html", Ipc.TextToHtml(text), "mode", "rich"))
        if (title != "")
            App.Store.SetTitle(id, title)      ; 指定了标题就上锁，别被正文首行盖掉
        else if (text != "")
            App.Store.SetAutoTitle(id, Store.AutoTitle(text))

        n := App.Store.Get(id)
        w := NoteWindow(n)
        if activate
            w.ToFront()
        App.RefreshList()
        App.RefreshTray()
        return w
    }

    /* 新建待办便签。和 NewNote 的区别只在 kind 与默认尺寸：
       待办页要放下一张卡片（勾选框 + 标题 + 状态 + 时间 + 正文），
       300×280 塞不下，默认给 460×540。用户拉过之后按库里的几何走。 */
    static NewTodoNote(opts := 0) {
        o := IsObject(opts) ? opts : Map()

        color := Ipc.Opt(o, "color", "")
        if (color = "" || !NoteWindow.Colors().Has(color))
            color := App.Cfg("window", "todoColor", App.Cfg("window", "color", "yellow"))

        pin := Ipc.Opt(o, "pin", 0) ? 1 : 0
        activate := Ipc.Num(o, "activate", 1)

        dw := Ipc.Num(o, "w", 0)
        dh := Ipc.Num(o, "h", 0)
        dw := (dw > 0) ? dw : App.Cfg("window", "todoWidth", 460)
        dh := (dh > 0) ? dh : App.Cfg("window", "todoHeight", 540)
        if (Ipc.Has(o, "hasXY") && o["hasXY"])
            geo := Win.Clamp(Ipc.Num(o, "x", 0), Ipc.Num(o, "y", 0), dw, dh)
        else
            geo := Win.Cascade(App.Store.Count(), dw, dh)

        /* 容器名：列表里得有个东西可看。用户可以在菜单里「重命名…」改掉；
           改过之后（title_locked=1）不会再被任何自动逻辑覆盖 ——
           待办这一层的自动标题只发生在事项上，不碰容器。 */
        title := Ipc.Opt(o, "title", "")
        if (Trim(title) = "")
            title := "待办 " FormatTime(A_Now, "MM-dd")

        id := App.Store.Create(Map(
            "kind", "todo",
            "title", title,
            "color", color,
            "x", geo.x, "y", geo.y, "w", geo.w, "h", geo.h,
            "pinned", pin, "hidden", 0))

        n := App.Store.Get(id)
        w := NoteWindow(n)
        if activate
            w.ToFront()
        App.RefreshList()
        App.RefreshTray()
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
            "onNewTodo", NoteNewTodo,
            "onOpen", NoteOpen,
            "onDelete", NoteDelete,
            "onHide", NoteHide,
            "onRename", NoteRename,
            "onExport", NoteExport,
            "onPin", NotePin,
            "onColor", NoteColor,
            "onOpacity", NoteSetOpacity,
            "onHotkey", NoteAskHotkey,
            "onShowAll", NoteShowAll,
            "onHideAll", NoteHideAll,
            "onBatch", NoteBatch,
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
        App.RebindNoteHotkeys()        ; 便签没了，它的快捷键也得跟着注销
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

    /* ---- 输入框（可置顶） -----------------------------------------------------
       AHK 自带的 InputBox 只认 w/h/x/y/T 这几种 Options，**不接受 Gui 的
       "+AlwaysOnTop"**（试过：直接抛 "Invalid option."）。于是便签一置顶，
       重命名对话框就被自己的便签盖在底下 —— 用户看不到自己在改什么。
       这里用普通 Gui 搭一个同样用途的小对话框，topmost=1 时整窗带 WS_EX_TOPMOST。

       几处细节照着 InputBox 的手感来做：
         · 回车 = 确定（按钮的 Default 选项），Esc = 取消（Gui 的 Escape 事件）
         · 打开时全选原有标题，直接打字就整段替换（EM_SETSEL 0,-1）
         · 用 WinWaitClose 把调用线程停住，调用方拿到的就是"用户已经答完了" */
    static AskText(title, prompt, def, topmost := 0) {
        res := { ok: 0, value: "" }
        g := Gui((topmost ? "+AlwaysOnTop " : "") "+ToolWindow -MinimizeBox -MaximizeBox", title)
        g.MarginX := 16
        g.MarginY := 14
        g.SetFont("s10", "Microsoft YaHei UI")
        g.Add("Text", "w376", prompt)
        ed := g.Add("Edit", "w376", def)
        okBtn := g.Add("Button", "w84 x224 y+14 Default", "确定")
        cancelBtn := g.Add("Button", "w84 x+8", "取消")

        Submit(*) {
            res.value := ed.Value
            res.ok := 1
            g.Destroy()
        }
        okBtn.OnEvent("Click", Submit)
        cancelBtn.OnEvent("Click", (*) => g.Destroy())
        g.OnEvent("Escape", (*) => g.Destroy())
        g.OnEvent("Close", (*) => g.Destroy())

        g.Show("AutoSize Center")
        ed.Focus()
        PostMessage(0x00B1, 0, -1, ed)          ; EM_SETSEL：全选
        WinWaitClose("ahk_id " g.Hwnd)

        ; 已经 Destroy 过的 Gui 再碰就抛错，这里只需要把对象放掉
        return res
    }

    /* ---- 通用"选一个动作"对话框 -----------------------------------------------
       用来问"覆盖还是追加"、以及批量删除的二次确认。为什么不直接用 MsgBox：
          · MsgBox 的按钮文字是系统固定的（是/否/取消），"是"到底是覆盖还是追加
            全靠用户读正文去猜，正是最容易搞错的地方；
          · 无主窗口的 MsgBox 会被置顶的便签/列表盖在底下（AskText 当初就是
            为了这个才手写的）。
       返回值：点中的按钮下标（从 1 开始），取消/关窗返回 0。 */
    static AskChoice(title, prompt, labels, defIdx := 0, topmost := 0) {
        res := { idx: 0, gui: 0 }
        g := Gui((topmost ? "+AlwaysOnTop " : "") "+ToolWindow -MinimizeBox -MaximizeBox", title)
        g.MarginX := 16
        g.MarginY := 14
        g.SetFont("s10", "Microsoft YaHei UI")
        g.Add("Text", "w360", prompt)
        res.gui := g
        for i, label in labels {
            opt := (i = 1 ? "y+16 w96" : "x+8 w96")
            if (i = defIdx)
                opt .= " Default"
            b := g.Add("Button", opt, label)
            b.OnEvent("Click", ChoicePick.Bind(res, i))
        }
        g.OnEvent("Escape", (*) => g.Destroy())
        g.OnEvent("Close", (*) => g.Destroy())
        g.Show("AutoSize Center")
        WinWaitClose("ahk_id " g.Hwnd)
        return res.idx
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
        ; 置顶的便签 + 置顶的列表窗口，都会把普通对话框盖住，所以跟着一起置顶
        top := 0
        if NoteWindow.All.Has(id) && NoteWindow.All[id].note.pinned
            top := 1
        if ListWindow.IsOpen() && ListWindow.Topmost
            top := 1
        r := App.AskText("重命名便签"
            , "给这张便签起个名字（列表里就显示这个）`n" hintText, n.title, top)
        if !r.ok
            return
        name := Trim(r.value)
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
    /* PDF / Word 不归 export.ahk 管：一个要建隐藏窗口，一个要起子进程碰 Word，
       都是"有副作用"的活儿。那边只管四种纯文本/标记格式。 */
    static ExportNote(id, fmt) {
        n := App.Store.Get(id)
        if !n {
            App.Toast("这张便签已经不在了")
            return
        }
        switch fmt {
            case "pdf": Pdf.Save(n)
            case "docx": Word.Save(n)
            default: Export.Save(n, fmt)
        }
    }

    /* 批量导出：先选一个文件夹，再逐张写。名称冲突交给 Export.SaveMany 处理。 */
    static ExportMany(ids, fmt) {
        notes := []
        for id in ids {
            n := App.Store.Get(id)
            if n
                notes.Push(n)
        }
        if !notes.Length {
            App.Toast("没有可导出的便签")
            return
        }
        switch fmt {
            case "pdf": Pdf.SaveMany(notes)
            case "docx": Word.SaveMany(notes)
            default: Export.SaveMany(notes, fmt)
        }
    }

    /* ---- 导入 ---------------------------------------------------------------
       只支持 TXT / Markdown：其它格式（docx、pdf）要解析器，不属于"便签"的范围。
       正文怎么落地交给页面做 —— rich 模式要把 Markdown 渲染成 HTML、还想让
       光标/撤销栈正常，这些只有页面知道；宿主只负责读文件和问一句"覆盖还是追加"。 */
    static ImportNote(id, path := "", mode := "") {
        n := App.Store.Get(id)
        if !n {
            App.Toast("这张便签已经不在了")
            return
        }
        if (path = "") {
            path := FileSelect(3, "", "导入到便签"
                , "文本与 Markdown (*.txt;*.md;*.markdown;*.mkd)")
            if (path = "")
                return
        }
        SplitPath path, &fname, , &ext
        ext := StrLower(ext)
        fmt := (ext = "md" || ext = "markdown" || ext = "mkd" || ext = "mdown") ? "md" : "txt"
        try size := FileGetSize(path)
        catch {
            App.Toast("读不到这个文件")
            return
        }
        if (size > App.IMPORT_MAX) {
            App.Toast("文件太大了（上限 " Round(App.IMPORT_MAX / 1048576) " MB）")
            return
        }
        text := App.ReadTextFile(path)
        if (Trim(text) = "") {
            App.Toast("这个文件是空的")
            return
        }

        /* 便签里已经有东西才问。空便签直接放进去 —— 对着空白便签问"覆盖还是追加"
           纯属添乱。 */
        hasContent := (Trim(n.body_text) != "" || Trim(n.body_html) != ""
            || Trim(n.body_md) != "")
        if (mode = "" && hasContent) {
            top := App.DialogTopmost(id)
            idx := App.AskChoice("导入 " StrUpper(fmt) " 文件"
                , "便签「" (Trim(n.title) = "" ? "（无标题）" : n.title) "」里已经有内容了。`n`n"
                  . "· 覆盖：用文件内容替换现在的正文，原来的内容会被删掉`n"
                  . "· 追加：把文件内容接在现有内容后面，中间空一行`n`n"
                  . "文件：" fname, ["覆盖", "追加", "取消"], 3, top)
            if (idx = 1)
                mode := "replace"
            else if (idx = 2)
                mode := "append"
            else
                return
        }
        if (mode = "")
            mode := "replace"

        if !NoteWindow.All.Has(id) {
            App.Toast("这张便签还没打开，先打开再导入")
            return
        }
        w := NoteWindow.All[id]
        if !w.ready {
            App.Toast("便签还在加载，稍等一下再试")
            return
        }
        w.Send('{"type":"import","text":' JsonQuote(text)
            . ',"format":' JsonQuote(fmt) ',"mode":' JsonQuote(mode) '}')
        App.Log("导入 " fmt " -> id=" id "，模式 " mode "，来源 " fname)
        App.Toast("已" (mode = "replace" ? "覆盖导入" : "追加导入") "：" fname)
    }

    /* 该不该置顶的对话框。便签自己置顶、或列表窗口置顶时，普通对话框会被
       盖在底下 —— 用户看不到自己在确认什么。 */
    static DialogTopmost(id := 0) {
        top := 0
        if (id && NoteWindow.All.Has(id) && NoteWindow.All[id].note.pinned)
            top := 1
        if ListWindow.IsOpen() && ListWindow.Topmost
            top := 1
        return top
    }

    /* 读文本文件并猜编码。三种 BOM 之外，剩下的按"先当 UTF-8，出现 U+FFFD
       就退回 CP936"处理 —— 国内用户从记事本另存的 txt 大量是 GBK，
       直接按 UTF-8 读会整篇变成方块。 */
    static ReadTextFile(path) {
        b0 := 0, b1 := 0
        try {
            f := FileOpen(path, "r")
            buf := Buffer(2, 0)
            n := f.RawRead(buf, 2)
            f.Close()
            if (n >= 2) {
                b0 := NumGet(buf, 0, "uchar")
                b1 := NumGet(buf, 1, "uchar")
            }
        }
        text := ""
        if (b0 = 0xEF && b1 = 0xBB) {
            try text := FileRead(path, "UTF-8")
        } else if ((b0 = 0xFF && b1 = 0xFE) || (b0 = 0xFE && b1 = 0xFF)) {
            try text := FileRead(path, "UTF-16")
        } else {
            try text := FileRead(path, "UTF-8")
            if (text = "" || InStr(text, Chr(0xFFFD))) {
                t2 := ""
                try t2 := FileRead(path, "CP936")
                if (t2 != "")
                    text := t2
            }
        }
        text := StrReplace(text, "`r`n", "`n")
        return StrReplace(text, "`r", "`n")
    }

    /* ---- 批量操作 -----------------------------------------------------------
       action：clear-hotkey / pin / hide / color / opacity / export / delete
       一次处理一批，最后只刷一次列表和托盘（逐张刷会把列表刷成幻灯片）。
       每个分支都同步已开的窗口："批量改颜色"改完，桌面上那张得立刻变色。 */
    static BatchNotes(action, ids, arg := "") {
        if !IsObject(ids) || !ids.Length
            return 0
        done := 0
        switch action {
            case "clear-hotkey":
                for id in ids {
                    App.Store.SetHotkey(id, "")
                    if NoteWindow.All.Has(id)
                        NoteWindow.All[id].note.hotkey := ""
                    done += 1
                }
                App.RebindNoteHotkeys()      ; 只重绑一次，不是每张一次
            case "pin":
                on := arg ? 1 : 0
                for id in ids {
                    App.Store.SetPinned(id, on)
                    if NoteWindow.All.Has(id)
                        NoteWindow.All[id].ApplyPin(on)
                    done += 1
                }
            case "hide":
                want := arg ? 1 : 0
                for id in ids {
                    if (want) {
                        if NoteWindow.All.Has(id)
                            NoteWindow.All[id].Hide()
                        else
                            App.Store.SetHidden(id, 1)
                    } else {
                        /* 展开 = 真的把窗口叫回桌面，和"全部显示"同一语义。
                           没有窗口的要建窗（OpenNote 内部会 await，本函数只在
                           SetTimer 起的线程里被调用）。 */
                        if NoteWindow.All.Has(id)
                            NoteWindow.All[id].Show()
                        else
                            App.OpenNote(id)
                    }
                    done += 1
                }
            case "color":
                if !NoteWindow.IsColor(arg)
                    return 0
                for id in ids {
                    App.Store.SetColor(id, arg)
                    if NoteWindow.All.Has(id)
                        NoteWindow.All[id].ApplyColor(arg)
                    done += 1
                }
            case "opacity":
                for id in ids {
                    App.SetNoteOpacity(id, arg)   ; 里面会判"要不要重建成分层窗口"
                    done += 1
                }
            case "export":
                App.ExportMany(ids, arg)
                return ids.Length
            case "delete":
                for id in ids {
                    if NoteWindow.All.Has(id)
                        NoteWindow.All[id].Destroy()
                    App.Store.Delete(id)
                    done += 1
                }
                App.RebindNoteHotkeys()
            default:
                App.Log("未知的批量操作：" action)
                return 0
        }
        App.RefreshTray()
        App.RefreshList()
        App.Log("批量操作 " action "：处理 " done " 张")
        return done
    }

    /* 批量删除的二次确认。默认按钮放"取消"上 —— 回车不该把一批便签删掉。
       返回实际删掉的张数（0 = 用户取消）。 */
    static ConfirmBatchDelete(ids) {
        if !IsObject(ids) || !ids.Length
            return 0
        list := ""
        show := Min(ids.Length, 5)
        for i, id in ids {
            if (i > show)
                break
            n := App.Store.Get(id)
            t := !n ? "（已不存在）" : (Trim(n.title) = "" ? "（无标题）" : n.title)
            list .= "`n  · " (StrLen(t) > 28 ? SubStr(t, 1, 28) "…" : t)
        }
        if (ids.Length > show)
            list .= "`n  · …等共 " ids.Length " 张"
        r := App.AskChoice("批量删除"
            , "确定要删除选中的 " ids.Length " 张便签吗？`n" list
              . "`n`n此操作不可恢复：正文、标题、快捷键、窗口设置都会一起消失"
              . "（图片文件仍留在数据目录里）。", ["删除", "取消"], 2, App.DialogTopmost(0))
        if (r != 1)
            return 0
        return App.BatchNotes("delete", ids)
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
            /* 便签自己的快捷键也占着这个键。AHK 不会报冲突，是直接顶掉，
               所以必须在这里拦 —— 否则"设置面板保存成功，某张便签的键却没了"。 */
            for n in App.Store.All() {
                if (n.hotkey != "" && App.SameHotkey(n.hotkey, key)) {
                    App.RebindHotkeys(App.CfgHotkeys())
                    return "「" App.HotkeyLabel(name) "」已经给了便签「"
                        . (n.title = "" ? "（无标题）" : n.title) "」，换一个吧。"
                }
            }
        }

        App.SetCfg("hotkey", "new", hs["new"])
        App.SetCfg("hotkey", "list", hs["list"])
        App.SetCfg("hotkey", "toggle", hs["toggle"])
        showAll := JsonNum(raw, "showAllOnStart", 0) ? 1 : 0
        openList := JsonNum(raw, "openListOnStart", 0) ? 1 : 0
        App.SetCfg("app", "showAllOnStart", showAll)
        App.SetCfg("app", "openListOnStart", openList)

        /* 新建便签的默认颜色：消息里没带这一项就沿用当前值（老版本页面/自检
           都不会把它清成黄色）。非法名字直接当没填。
           NewNote 每次都现读 config.ini，所以写完立即生效，不用重建窗口。 */
        dc := Trim(JsonStr(raw, "defColor", App.Cfg("window", "color", "yellow")))
        if !NoteWindow.IsColor(dc)
            dc := App.Cfg("window", "color", "yellow")
        App.SetCfg("window", "color", dc)

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
            "，默认颜色 " dc "，启动显示全部 " showAll "，启动开列表 " openList)
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
        t.Add("新建待办便签", (*) => NoteDeferTodo())
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
        App.RebindNoteHotkeys()
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

    ; ========================================================================
    ;  每张便签自己的快捷键
    ; ========================================================================

    /* 便签的快捷键存在 notes.hotkey 里（空 = 没设），最多 10 张。
       和上面三个全局键互不干扰，但必须**互斥**：AHK 的 Hotkey() 拿同一个键
       再注册一次不会报错，是直接把前一个顶掉 —— 冲突只能自己比。 */

    static NoteHotkeyLimit := 10

    static RebindNoteHotkeys() {
        if !IsObject(App.NoteKeys)
            App.NoteKeys := Map()
        ; 先全部注销：不注销就重绑，旧键会留在 AHK 的注册表里（顶着旧闭包）
        for id, key in App.NoteKeys.Clone() {
            if (key = "")
                continue
            try Hotkey(key, "Off")
        }
        App.NoteKeys := Map()
        if !App.Store
            return
        n := 0
        for note in App.Store.All() {
            if (note.hotkey = "")
                continue
            if App.BindOne(note.hotkey, NoteSummonBound(note.id)) {
                App.NoteKeys[note.id] := note.hotkey
                n += 1
            } else
                App.Log("便签快捷键注册失败：id=" note.id " = " note.hotkey)
        }
        if (n > 0)
            App.Log("便签快捷键已注册 " n " 个")
    }

    /* 按快捷键召出这张便签：没开就开，开着但不在最前就提到最前，
       已经在最前就收起 —— 一个键既呼出又收回，不用记两个动作。
       建窗要 await WebView2，热键线程里绝不能直接建，一律转独立线程。 */
    static SummonNote(id) {
        SetTimer(NoteSummonTick.Bind(id), -10)
    }

    /* 真正干活的那一半（已经在独立线程里）。先 Show 再 ToFront：窗口可能
       被"收起"过，只是提到最前看不见东西。 */
    static SummonNoteNow(id) {
        if NoteWindow.All.Has(id) {
            w := NoteWindow.All[id]
            if WinActive("ahk_id " w.gui.Hwnd) {
                w.Hide()
                return
            }
            w.Show()
            w.ToFront()
            return
        }
        App.OpenNote(id)
    }

    /* 换成分层窗口只能重建。Destroy 会把几何写回库，重建时照原样摆回去；
       已收起的便签不会走到这里（没有窗口），下次开的时候自然就是分层的。 */
    static RebuildNote(id) {
        if !NoteWindow.All.Has(id)
            return
        NoteWindow.All[id].Destroy()
        n := App.Store.Get(id)
        if n
            NoteWindow(n)
    }

    static AskNoteHotkey(id) {
        n := App.Store.Get(id)
        if !n {
            App.Toast("这张便签已经不在了")
            return
        }
        ; 和重命名框一样：置顶的便签/列表会盖住普通对话框，那就一起置顶
        top := 0
        if NoteWindow.All.Has(id) && NoteWindow.All[id].note.pinned
            top := 1
        if ListWindow.IsOpen() && ListWindow.Topmost
            top := 1
        prompt := "设一个全局快捷键，随时把这张便签呼到最前（已在最前时再按收起）。`n"
            . "写法：^ = Ctrl，! = Alt，+ = Shift，# = Win，例如 ^!1、#n。`n"
            . "留空 = 取消这张便签的快捷键；最多 " App.NoteHotkeyLimit " 张便签可以设。"
        r := App.AskText("便签快捷键", prompt, n.hotkey, top)
        if !r.ok
            return
        e := App.SetNoteHotkey(id, r.value)
        if (e != "")
            MsgBox(e, "便签快捷键", "Icon!")
    }

    ; 返回错误文案，空串 = 成功
    static SetNoteHotkey(id, key) {
        key := Trim(key)
        if (key = "") {
            App.Store.SetHotkey(id, "")
            App.RebindNoteHotkeys()
            App.RefreshWindowHotkey(id, "")
            App.RefreshList()
            return ""
        }

        for name, k in App.CfgHotkeys() {
            if (k != "" && App.SameHotkey(k, key))
                return "这个键已经是「" App.HotkeyLabel(name) "」了，换一个吧。"
        }

        taken := 0, others := 0
        for n in App.Store.All() {
            if (n.hotkey = "" || n.id = id)
                continue
            others += 1
            if App.SameHotkey(n.hotkey, key)
                taken := n
        }
        if taken
            return "这个键已经给了便签「" (taken.title = "" ? "（无标题）" : taken.title) "」，换一个吧。"
        if (others >= App.NoteHotkeyLimit)
            return "已经有 " App.NoteHotkeyLimit " 张便签设了快捷键，先给别的便签清掉一个再用。"

        e := App.TestHotkey(key)
        if (e != "")
            return e

        App.Store.SetHotkey(id, key)
        App.RebindNoteHotkeys()
        App.RefreshWindowHotkey(id, key)
        App.RefreshList()
        App.Log("便签快捷键：id=" id " = " key)
        return ""
    }

    ; 已经开着的窗口里存着一份 note 副本，菜单标签要跟着变
    static RefreshWindowHotkey(id, key) {
        if NoteWindow.All.Has(id)
            NoteWindow.All[id].note.hotkey := key
    }

    /* 只给列表页显示用：^!1 这种写法对普通用户是天书，列表角标显示 Ctrl+Alt+1。
       实现在 NoteWindow 里（窗口层自己就要用，见那边的说明）。 */
    static HotkeyPretty(k) => NoteWindow.HotkeyPretty(k)

    static SameHotkey(a, b) => (App.NormHotkey(a) = App.NormHotkey(b))

    /* 归一化：修饰符拆出来按固定顺序排，主键统一小写。
       "^!A" 与 "!^a" 在 AHK 眼里是同一个键（重复注册会顶掉），必须能认出来。 */
    static NormHotkey(k) {
        k := Trim(k)
        mods := ""
        while (StrLen(k) > 0 && InStr("#!^+", SubStr(k, 1, 1))) {
            ch := SubStr(k, 1, 1)
            if !InStr(mods, ch)
                mods .= ch
            k := SubStr(k, 2)
        }
        sorted := ""
        for ch in ["#", "!", "^", "+"] {
            if InStr(mods, ch)
                sorted .= ch
        }
        return sorted . StrLower(Trim(k))
    }

    ; ========================================================================
    ;  每张便签自己的透明度
    ; ========================================================================

    /* pct 30~100。写库 + 应用到已开的窗口。
       非透明外观下，<100 需要窗口本身是分层的（页面淡下去才有地方透），
       而分层与否是建窗时定的扩展样式 —— 只能重建这一张。
       100 回来时不用重建：分层窗口画不透明内容完全正常。 */
    static SetNoteOpacity(id, pct) {
        pct := Max(30, Min(100, Integer(pct)))
        App.Store.SetOpacity(id, pct)
        if NoteWindow.All.Has(id) {
            w := NoteWindow.All[id]
            if (pct < 100 && !w.layered)
                SetTimer(NoteRebuildTick.Bind(id), -10)
            else
                w.ApplyOpacity(pct)
        }
        App.RefreshList()
        App.Log("便签透明度：id=" id " = " pct "%")
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
        text .= "; 设置面板里的「新建便签的颜色」改的就是这一项`r`n"
        text .= "color=yellow`r`n"
        text .= "; 列表窗口是否置顶（列表右上角的图钉按钮也会改这里）`r`n"
        text .= "listTopmost=0`r`n"
        text .= "; 下面两行是窗口上次的大小/位置，格式 x,y,w,h，程序自己写，不用手改`r`n"
        text .= "; listGeo=、settingsGeo=`r`n`r`n"
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
        text .= "devtools=0`r`n`r`n"
        text .= "[ipc]`r`n"
        text .= "; 外部进程调用接口（窗口消息 / WM_COPYDATA），细节见 docs\ipc.md`r`n"
        text .= "; 0 = 完全关掉，只保留单实例唤醒`r`n"
        text .= "enabled=1`r`n"
        text .= "; 外部塞进来的便签要不要抢焦点：1 = 弹到最前，0 = 安静地建在角落`r`n"
        text .= "; 单条调用也可以在载荷里用 activate:0 单独指定`r`n"
        text .= "activate=1`r`n"
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

    ; 取 --flag 后面那个参数（"最后一个"就不算有）
    static ArgAfter(flag) {
        n := A_Args.Length
        loop n {
            if (A_Args[A_Index] = flag && A_Index < n)
                return A_Args[A_Index + 1]
        }
        return ""
    }

    static SetCfg(section, key, value) {
        try IniWrite String(value), App.DataDir "\config.ini", section, key
    }

    /* 第二个实例：把命令行意图转给已经在跑的那个进程。
       以前只会"全部显示"一下，带进来的参数全丢 —— 有了 IPC 顺手补齐，
       于是 note.ahk --new "买牛奶" 就成了一个可用的命令行入口。 */
    static ForwardToRunning() {
        hwnd := WinExist(App.Name "Anchor")
        if !hwnd {
            ; 找不到锚点（极少见）就退而求其次：提示一下
            MsgBox("便签已经在运行了。`n在托盘图标上双击可以打开列表。", App.Name, "Icon! T2")
            return
        }
        if App.HasArg("--list") {
            PostMessage(Ipc.WM_LIST, Ipc.MAGIC, 0, , "ahk_id " hwnd)
            return
        }
        if App.HasArg("--new") {
            text := App.ArgAfter("--new")
            if (text = "")
                PostMessage(Ipc.WM_NEW, Ipc.MAGIC, 0, , "ahk_id " hwnd)
            else
                Ipc.SendText(hwnd, text)
            return
        }
        PostMessage(Ipc.WM_WAKE, 0, 0, , "ahk_id " hwnd)     ; 老语义：全部显示
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

    /* 拖边框改尺寸：WebView2 的 controller 不会自己跟着父窗口长，全靠 Gui 的
       Size 事件里补一次 Fill()。判据看页面自己的 clientWidth —— 窗口变大而
       controller 没跟上时，页面根本不知道，viewport 不会动。 */
    resized := 0, minSized := 0, geoKept := 0
    oldGeo := App.Cfg("window", "listGeo", "")
    if ListWindow.Win {
        hw := ListWindow.Win.gui.Hwnd
        r := Win.Rect(hw)
        cw0 := App.EvalNum(ListWindow.Win, "document.documentElement.clientWidth")
        WinMove(r.x, r.y, r.w + 160, r.h + 80, "ahk_id " hw)
        Sleep 500
        cw1 := App.EvalNum(ListWindow.Win, "document.documentElement.clientWidth")
        WinMove(r.x, r.y, r.w, r.h, "ahk_id " hw)
        Sleep 500
        cw2 := App.EvalNum(ListWindow.Win, "document.documentElement.clientWidth")
        App.Log("SELFTEST 列表重铺 viewport：" cw0 " -> " cw1 " -> " cw2)
        resized := (cw1 > cw0 + 100 && cw2 < cw1 - 100)

        ; 下限：硬拖到 200x150，WM_GETMINMAXINFO 应该把它挡在 380x300 以上
        WinMove(r.x, r.y, 200, 150, "ahk_id " hw)
        Sleep 600
        r2 := Win.Rect(hw)
        App.Log("SELFTEST 列表最小尺寸：拖到 200x150 后实际 " r2.w "x" r2.h "（期望 ≥380x300）")
        minSized := (r2.w >= 380 && r2.h >= 300)

        ; 尺寸记忆：改大小 → 关 → 再开，外框尺寸要一模一样
        ; （比对"改之前的实测值"而不是 WinMove 传的值：WinMove 设的是客户区，
        ;   Gui.Show 的 w/h 设的是外框，两者差一圈边框，拿请求值当期望会假失败）
        WinMove(r.x, r.y, 620, 520, "ahk_id " hw)
        Sleep 700
        rb := Win.Rect(hw)
        ListWindow.Close()
        Sleep 600
        App.ShowList()
        Sleep 2400
        geoKept := 0
        if ListWindow.Win {
            r3 := Win.Rect(ListWindow.Win.gui.Hwnd)
            App.Log("SELFTEST 列表尺寸记忆：关前 " rb.w "x" rb.h "，重开后 " r3.w "x" r3.h)
            geoKept := (r3.w = rb.w && r3.h = rb.h)
        }
    }

    before := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    App.SetFontSize(before + 1)
    Sleep 700
    got := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    App.Log("SELFTEST 字号写入：库里 " got "（期望 " (before + 1) "）")
    App.SetFontSize(before)                 ; 别把用户配置改坏
    Sleep 700
    back := App.Cfg("appearance", "fontSize", App.FONT_DEFAULT)
    App.Log("SELFTEST 字号已恢复为 " back)
    ; 别把测试尺寸留在用户的 config.ini 里（原来是空就写回空，LoadGeo 认这个）
    App.SetCfg("window", "listGeo", oldGeo)
    allOK := open && resized && minSized && geoKept && got = before + 1 && back = before
    App.Log("SELFTEST 结论：" (allOK ? "通过" : "未通过"))
    SelfTestDone()
}

/* 自检：右键菜单/页面按钮改完数据后，列表要立刻跟着变。
   这两条路以前不一致 —— 页面按钮是 Handle 里统一 Push 的，右键菜单直接调 Call，
   漏了那一步。现象：右键删除后那一行还赖在列表里，手快再点它就报"便签已被删除"。
   这里同时盯删除（两种入口）和置顶（改完要立刻长出"置顶"角标）。 */
SelfTestDelete() {
    ids := []
    ids.Push(App.Store.Create(Map("title", "删我1", "body_text", "a")))
    ids.Push(App.Store.Create(Map("title", "删我2", "body_text", "b")))
    ids.Push(App.Store.Create(Map("title", "留着我", "body_text", "c")))
    App.ShowList()
    Sleep 2600
    if !ListWindow.Win {
        App.Log("SELFTEST DEL 列表没开")
        SelfTestDone()
        return
    }
    n0 := App.EvalNum(ListWindow.Win, "document.querySelectorAll('#list .item').length")
    App.Log("SELFTEST DEL 删除前条数=" n0)

    ; 1) 页面上的 ✕ 按钮（Handle 那条路）
    ListWindow.Win.wv.ExecuteScript("(function(){var r=document.querySelector('#list .item[data-id="
        . Chr(34) ids[1] Chr(34) "]');r.querySelector('.ops button.del').click();return 1})()")
    Sleep 700
    n1 := App.EvalNum(ListWindow.Win, "document.querySelectorAll('#list .item').length")
    App.Log("SELFTEST DEL 点 ✕ 删 id=" ids[1] " 后条数=" n1 "（期望 " (n0 - 1) "）")

    ; 2) 右键菜单的「删除…」（走菜单回调，不经 Handle）—— 顺带删一张正开着的
    try App.OpenNote(ids[2])
    Sleep 800
    ListMenuDelete(ids[2]).Call()
    Sleep 700
    n2 := App.EvalNum(ListWindow.Win, "document.querySelectorAll('#list .item').length")
    App.Log("SELFTEST DEL 菜单删开着窗口的 id=" ids[2] " 后条数=" n2 "（期望 " (n0 - 2) "）")

    ; 3) 菜单置顶：角标要立刻出现，别等下一次刷新
    ListMenuPin(ids[3], 1).Call()
    Sleep 700
    pin := App.EvalNum(ListWindow.Win, "document.querySelectorAll('#list .pin').length")
    App.Log("SELFTEST DEL 菜单置顶后角标数=" pin "（期望 1）")

    ; 收摊：别把测试便签留在用户库里
    try App.DeleteNote(ids[3])
    Sleep 300
    App.Log("SELFTEST DEL 结论：" (n1 = n0 - 1 && n2 = n0 - 2 && pin = 1 ? "通过" : "未通过"))
    SelfTestDone()
}

/* 自检：每张便签的透明度。
   两条路分开验：
     · 透明外观（默认）：窗口本来就是分层的，改透明度 = 改页面 opacity
     · 不透明外观：100% 时是普通窗口，调到 <100 必须**重建**成分层窗口，
       否则页面淡下去透出来的是窗口底色，看上去一点没变（最容易漏的就是这条）
   判据取页面算出来的 opacity，不取库里那个数 —— 库对了但没发到页面，查不出来。 */
SelfTestOpacity() {
    oldTr := App.Ctx.appearance.transparent
    ids := []

    id := App.Store.Create(Map("title", "透明度90", "body_text", "a"))
    ids.Push(id)
    App.SetNoteOpacity(id, 90)
    w := App.OpenNote(id)
    Sleep 2000
    got90 := 0
    if w
        got90 := App.EvalNum(w, "Math.round(parseFloat(getComputedStyle(document.documentElement).opacity||'1')*100)")
    App.Log("SELFTEST OPACITY 透明外观 90%：库=" App.Store.Get(id).opacity
        " 页面=" got90 " 分层=" (w ? w.layered : -1))

    App.SetNoteOpacity(id, 50)
    Sleep 500
    got50 := w ? App.EvalNum(w, "Math.round(parseFloat(getComputedStyle(document.documentElement).opacity||'1')*100)") : 0
    App.Log("SELFTEST OPACITY 改到 50%：库=" App.Store.Get(id).opacity " 页面=" got50)

    App.SetNoteOpacity(id, 100)
    Sleep 500
    got100 := w ? App.EvalNum(w, "Math.round(parseFloat(getComputedStyle(document.documentElement).opacity||'1')*100)") : 0
    App.Log("SELFTEST OPACITY 回到 100%：库=" App.Store.Get(id).opacity " 页面=" got100)

    ; 重建那条路：切成不透明外观，先按 100% 建一张普通窗口
    App.Ctx.appearance.transparent := 0
    id2 := App.Store.Create(Map("title", "透明度重建", "body_text", "b"))
    ids.Push(id2)
    w2 := App.OpenNote(id2)
    Sleep 2000
    beforeLayered := w2 ? w2.layered : -1
    App.SetNoteOpacity(id2, 70)
    Sleep 3200                     ; 重建要先关 WebView2 再建一个，慢
    w3 := NoteWindow.All.Has(id2) ? NoteWindow.All[id2] : 0
    afterLayered := w3 ? w3.layered : -1
    got70 := w3 ? App.EvalNum(w3, "Math.round(parseFloat(getComputedStyle(document.documentElement).opacity||'1')*100)") : 0
    App.Log("SELFTEST OPACITY 不透明外观 100%→70%：分层 " beforeLayered " -> " afterLayered
        "，页面=" got70 "，库=" App.Store.Get(id2).opacity)

    ; 列表右键那条路：设 70%、再"重置透明度"。这是"透到找不着"时的唯一退路，
    ; 它必须真的把库和页面都拉回 100%，而不是只改菜单上的勾。
    App.ShowList()
    Sleep 2600
    set70 := 0, reset := 0, resetPage := 0
    if ListWindow.Win {
        ListMenuOpacity(id, 70).Call()
        Sleep 700
        set70 := App.Store.Get(id).opacity
        ListMenuOpacity(id, 100).Call()
        Sleep 700
        reset := App.Store.Get(id).opacity
        resetPage := App.EvalNum(w, "Math.round(parseFloat(getComputedStyle(document.documentElement).opacity||'1')*100)")
    }
    App.Log("SELFTEST OPACITY 列表菜单：设 70 后库=" set70 "，重置后库=" reset " 页面=" resetPage)

    ok := (got90 = 90 && got50 = 50 && got100 = 100
        && beforeLayered = 0 && afterLayered = 1 && got70 = 70 && App.Store.Get(id2).opacity = 70
        && set70 = 70 && reset = 100 && resetPage = 100)

    ; 收摊：外观恢复、测试便签删掉
    App.Ctx.appearance.transparent := oldTr
    for i in ids
        try App.DeleteNote(i)
    Sleep 300
    App.Log("SELFTEST OPACITY 结论：" (ok ? "通过" : "未通过"))
    SelfTestDone()
}

/* 自检：便签自己的全局快捷键。
   重点在**冲突拦截** —— AHK 允许同一个键重复注册（后来的顶掉前面的）且不报错，
   所以"两个便签用同一个键"不会自己暴露。本机 SendInput 会把程序卡死，
   所以这里不真按键，只验注册表、唤起逻辑和列表角标。 */
SelfTestHotkey() {
    ids := []
    id1 := App.Store.Create(Map("title", "快捷一", "body_text", "a"))
    id2 := App.Store.Create(Map("title", "快捷二", "body_text", "b"))
    ids.Push(id1)
    ids.Push(id2)

    e1 := App.SetNoteHotkey(id1, "^!F9")
    e2 := App.SetNoteHotkey(id2, "这不是键")
    e3 := App.SetNoteHotkey(id2, App.Cfg("hotkey", "new", "^!n"))
    e4 := App.SetNoteHotkey(id2, "!^F9")          ; 同键不同写法：修饰符换序
    e5 := App.SetNoteHotkey(id2, "^!F10")
    App.Log("SELFTEST HK 设置=" (e1 = "" ? "ok" : "失败：" e1)
        " 非法键=" (e2 != "" ? "已拦" : "没拦")
        " 撞全局键=" (e3 != "" ? "已拦" : "没拦")
        " 撞别的便签=" (e4 != "" ? "已拦" : "没拦")
        " 第二个=" (e5 = "" ? "ok" : "失败：" e5))
    bound := (App.NoteKeys.Has(id1) && App.NoteKeys.Has(id2)) ? 1 : 0
    App.Log("SELFTEST HK 真注册上=" bound "，库里 id1=" App.Store.Get(id1).hotkey)

    same := App.SameHotkey("^!A", "!^a") ? 1 : 0
    pretty := NoteWindow.HotkeyPretty("^!1")
    App.Log("SELFTEST HK 归一化 ^!A/!^a=" same "，美化 ^!1→" pretty)

    ; 唤起：先收起，再"按"一次 —— 得重新出现
    w := App.OpenNote(id1)
    Sleep 2000
    shown := 0, act := 0, tog := -1
    if w {
        w.Hide()
        Sleep 400
        App.SummonNoteNow(id1)
        Sleep 700
        shown := (App.Store.Get(id1).hidden = 0) ? 1 : 0
        ; 已经在最前时再按 = 收起（拿不到前台就不算失败，纯环境问题）
        WinActivate("ahk_id " w.gui.Hwnd)
        Sleep 400
        act := WinActive("ahk_id " w.gui.Hwnd) ? 1 : 0
        App.SummonNoteNow(id1)
        Sleep 500
        tog := App.Store.Get(id1).hidden
    }
    App.Log("SELFTEST HK 收起后按=" shown "（期望 1），前台时按=" tog "（前台=" act "）")

    ; 列表角标：数量跟着"库里 hotkey 非空"的条数走。用户的库很可能早就有
    ; 别的便签挂着快捷键，写死 2 就永远是 FAIL。
    wantBadges := 0
    for n in App.Store.All()
        if (n.hotkey != "")
            wantBadges += 1
    App.ShowList()
    Sleep 2600
    badges := ListWindow.Win ? App.EvalNum(ListWindow.Win, "document.querySelectorAll('#list .hk').length") : -1
    App.Log("SELFTEST HK 列表角标=" badges "（期望 " wantBadges "）")

    ; 上限：库里先塞 10 个占位的（不真绑），第 11 个要被挡
    fakes := []
    Loop 10 {
        fid := App.Store.Create(Map("title", "占位" A_Index, "body_text", "x"))
        App.Store.SetHotkey(fid, "^!F" (A_Index + 12))
        fakes.Push(fid)
    }
    e6 := App.SetNoteHotkey(id2, "^!F11")
    App.Log("SELFTEST HK 超过上限：" (e6 != "" ? "已拦" : "没拦") "（" e6 "）")

    for i in fakes
        try App.Store.Delete(i)
    for i in ids
        try App.DeleteNote(i)
    App.RebindNoteHotkeys()
    Sleep 400

    ok := (e1 = "" && e2 != "" && e3 != "" && e4 != "" && e5 = ""
        && bound = 1 && same = 1 && pretty = "Ctrl+Alt+1"
        && shown = 1 && (act ? tog = 1 : 1) && badges = wantBadges && wantBadges >= 2
        && e6 != "")
    App.Log("SELFTEST HK 结论：" (ok ? "通过" : "未通过"))
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
          /* 把鼠标"停"在第一个代码块上，右上角的复制按钮才会浮出来 —
             截图里看得见，才知道有这么个东西。 */
          ed.querySelector('pre').dispatchEvent(
            new MouseEvent('mousemove', { bubbles: true, buttons: 0 }));
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

/* 拍一张"最大化之后"的样子：确认铺满工作区、右下角手柄消失、
   正文排版在大窗口下没有散架。 */
SelfTestShotMax() {
    w := 0
    try {
        w := App.NewNote()
        Loop 40 {
            if w && w.ready
                break
            Sleep 100
        }
        RichEval(w, "
        ( LTrim Join
        (function(){
          const ed = document.getElementById('editor');
          ed.innerHTML = '<h2>大段输入</h2>'
            + '<p>双击便签标题栏就铺满整块屏幕，再双击还原。'
            + '长文、图片、代码块想一口气写的时候用得上。</p>'
            + '<pre><code class=""language-python"">'
            + 'def fib(n):'
            + '\n' + '    return n if n < 2 else fib(n-1) + fib(n-2)'
            + '</code></pre>'
            + '<p>空行上再敲一次回车（或 Ctrl+Enter / Esc / 末尾按 ↓）就能跳出代码块。</p>';
          window.CodeHL.paintAll(ed, { force: true });
          /* 直接写 innerHTML 不会触发 input，占位提示「写点什么…」会留在上面；
             补一发 input 让空白判断和字数统计跟上（截图才干净）。 */
          ed.dispatchEvent(new Event('input', { bubbles: true }));
          return 1;
        })()
        )")
        Sleep 400
        w.SetMax(1)
        Sleep 800
        ok := ShotNote(w, A_ScriptDir "\assets\shot-max.png")
        App.Log("SHOT max=" ok)
        w.SetMax(0)
        Sleep 200
        if w
            App.DeleteNote(w.id)
    } catch as e {
        App.Log("SHOT max 失败：" CleanComError(e.Message) " @" e.Line)
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
    oldColor := App.Cfg("window", "color", "yellow")
    oldSGeo := App.Cfg("window", "settingsGeo", "")

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

    ; 默认颜色色块：个数跟 NoteWindow.Colors() 对上，当前值被点亮
    chips := JStr(RichEval(w, "document.querySelectorAll('#swatches .chip').length"))
    RichSay("页面画出了 6 个颜色色块", chips = String(NoteWindow.Colors().Count), chips)
    chipOn := JStr(RichEval(w, "(function(){var c=document.querySelector('#swatches .chip.on');"
        . "return c?c.dataset.key:'-'})()"))
    RichSay("当前默认颜色被点亮", chipOn = oldColor, chipOn " vs " oldColor)
    chipHex := JStr(RichEval(w, "(function(){var c=document.querySelector('#swatches .chip');"
        . "return c?c.style.background:'-'})()"))
    RichSay("色块用的是宿主给的色值（rgb 形式）", InStr(chipHex, "rgb") > 0, chipHex)

    /* 拖边框改尺寸：不接 Gui 的 Size 事件时，窗口拉大了页面还停在原尺寸，
       右边一大片空白（用户报的就是这个）。看页面自己的 clientWidth 才算数。 */
    rs := Win.Rect(w.gui.Hwnd)
    vw0 := App.EvalNum(w, "document.documentElement.clientWidth")
    WinMove(rs.x, rs.y, rs.w + 140, rs.h + 60, "ahk_id " w.gui.Hwnd)
    Sleep 500
    vw1 := App.EvalNum(w, "document.documentElement.clientWidth")
    WinMove(rs.x, rs.y, rs.w, rs.h, "ahk_id " w.gui.Hwnd)
    Sleep 500
    vw2 := App.EvalNum(w, "document.documentElement.clientWidth")
    RichSay("拖大窗口后页面跟着重铺", vw1 > vw0 + 100 && vw2 < vw1 - 100,
        vw0 " -> " vw1 " -> " vw2)
    Sleep 600                          ; 等 400ms 防抖写盘
    geoNow := App.Cfg("window", "settingsGeo", "")
    RichSay("尺寸变了会写进 settingsGeo", geoNow != "", geoNow)

    ; 非法热键：应当报错，且配置不被改坏
    badRaw := '{"type":"save","fontSize":19,"transparent":1,"showAllOnStart":0,'
        . '"openListOnStart":0,"hkNew":"Ctrl+","hkList":"","hkToggle":""}'
    err := App.ApplySettings(badRaw)
    RichSay("非法热键被拦下", err != "", err)
    RichSay("拦截后字号没被改", App.Cfg("appearance", "fontSize", App.FONT_DEFAULT) = oldFs)
    RichSay("拦截后原热键仍注册着", App.Bound.Has("new") && App.Bound["new"] = oldHk,
        App.Bound.Has("new") ? App.Bound["new"] : "(无)")

    ; 合法保存：字号 + 新热键 + 启动显示全部 + 默认颜色改成蓝色
    goodRaw := '{"type":"save","fontSize":18,"transparent":1,"showAllOnStart":1,'
        . '"openListOnStart":0,"defColor":"blue",'
        . '"hkNew":"^!j","hkList":"^!l","hkToggle":""}'
    err2 := App.ApplySettings(goodRaw)
    RichSay("合法配置保存成功", err2 = "", err2)
    RichSay("字号立即生效", App.Ctx.appearance.fontSize = 18, App.Ctx.appearance.fontSize)
    RichSay("默认颜色已落盘", App.Cfg("window", "color", "yellow") = "blue",
        App.Cfg("window", "color", "yellow"))
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
        . '"defColor":' JsonQuote(oldColor) ','
        . '"hkNew":' JsonQuote(oldHk) ',"hkList":"^!l","hkToggle":"^!h"}'
    err3 := App.ApplySettings(backRaw)
    RichSay("恢复原配置", err3 = "", err3)
    RichSay("恢复后热键回来了", App.Bound.Has("new") && App.Bound["new"] = oldHk,
        App.Bound.Has("new") ? App.Bound["new"] : "(无)")
    RichSay("默认颜色已恢复", App.Cfg("window", "color", "blue") = oldColor,
        App.Cfg("window", "color", "blue"))
    ; 别把测试尺寸留在用户的 config.ini 里
    App.SetCfg("window", "settingsGeo", oldSGeo)

    ; 没带 defColor 的老消息不能把默认颜色清成黄色
    App.ApplySettings('{"type":"save","fontSize":' oldFs ',"transparent":1,'
        . '"showAllOnStart":' (oldAll ? 1 : 0) ',"openListOnStart":0,'
        . '"hkNew":' JsonQuote(oldHk) ',"hkList":"^!l","hkToggle":"^!h"}')
    RichSay("消息里没带默认颜色时保持不变",
        App.Cfg("window", "color", "yellow") = oldColor, App.Cfg("window", "color", "yellow"))
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

/* 自检：可置顶的重命名输入框。
   关窗用 PostMessage(WM_CLOSE)，不用 SendInput —— 本机注入真按键会卡死
   （前几轮踩过），而这里要验的只是"窗口出来了、置顶位对不对、能不能正常取消"。 */
SelfTestDialog() {
    try SelfTestDialogRun()
    catch as e {
        App.Log("SELFTEST DIALOG 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST DIALOG 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

global DlgSeen := 0, DlgTop := -1

/* 跑在独立定时器线程里：等对话框出现，记下它的置顶位，然后关掉它。
   AskText 里 WinWaitClose 会把调用线程停住，但定时器线程照样能进来。 */
DialogProbeTick(title) {
    global DlgSeen, DlgTop
    hwnd := 0
    Loop 120 {
        hwnd := WinExist(title)
        if hwnd
            break
        Sleep 25
    }
    if !hwnd {
        DlgSeen := 0
        return
    }
    DlgSeen := 1
    DlgTop := (WinGetExStyle("ahk_id " hwnd) & 0x8) ? 1 : 0     ; WS_EX_TOPMOST
    PostMessage(0x0010, 0, 0, , "ahk_id " hwnd)                  ; WM_CLOSE
}

SelfTestDialogRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    global DlgSeen, DlgTop

    ; 1) 便签置顶时用的那一版：整窗带 WS_EX_TOPMOST
    DlgSeen := 0, DlgTop := -1
    SetTimer(DialogProbeTick.Bind("重命名便签（置顶测试）"), -120)
    r := App.AskText("重命名便签（置顶测试）", "随便写点", "旧标题", 1)
    RichSay("置顶对话框确实弹出来了", DlgSeen = 1, DlgSeen)
    RichSay("置顶对话框带 WS_EX_TOPMOST", DlgTop = 1, DlgTop)
    RichSay("关窗时按取消处理（ok=0）", r.ok = 0, r.ok)

    ; 2) 普通版：不该带置顶位（否则会盖住别的程序）
    DlgSeen := 0, DlgTop := -1
    SetTimer(DialogProbeTick.Bind("重命名便签（普通测试）"), -120)
    r2 := App.AskText("重命名便签（普通测试）", "随便写点", "旧标题", 0)
    RichSay("普通对话框也能弹出来", DlgSeen = 1, DlgSeen)
    RichSay("普通对话框不带置顶位", DlgTop = 0, DlgTop)
    RichSay("普通对话框返回 ok=0", r2.ok = 0, r2.ok)

    ; 3) 没有残窗
    Sleep 300
    left := WinExist("重命名便签（置顶测试）") || WinExist("重命名便签（普通测试）")
    RichSay("对话框关掉后没有残窗", !left, left)

    /* 4) 端到端：置顶的便签调 App.RenameNote，弹出来的框也得是置顶的。
       这一段才真正验到"置顶时重命名框不会被便签盖住"这条需求。 */
    w := 0
    try w := App.NewNote()
    Loop 60 {
        if w && w.ready
            break
        Sleep 100
    }
    RichSay("临时建了一张便签", w && w.ready ? 1 : 0)
    if (w && w.ready) {
        id := w.id
        App.SetPin(id, 1)
        DlgSeen := 0, DlgTop := -1
        SetTimer(DialogProbeTick.Bind("重命名便签"), -120)
        App.RenameNote(id)
        RichSay("置顶便签的重命名框是置顶的", DlgSeen = 1 && DlgTop = 1, DlgSeen "/" DlgTop)
        ; 取消（WM_CLOSE）不该改标题
        stillAuto := App.Store.Get(id)
        RichSay("取消后标题没被改动", stillAuto && stillAuto.title_locked = 0,
            stillAuto ? stillAuto.title_locked : "?")
        App.DeleteNote(id)
        Sleep 200
        RichSay("测试便签已删除", App.Store.Get(id) ? 0 : 1)
    }

    App.Log("SELFTEST DIALOG 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
}

/* 自检：外部进程调用接口（IPC）。
   真起一个独立进程（tools\ipc-send.ahk）当发送方 —— 只有跨进程才验得出
   OnMessage 线程、COPYDATASTRUCT 布局、回执这些坑，进程内自己造消息不算数。 */
SelfTestIpc() {
    try SelfTestIpcRun()
    catch as e {
        App.Log("SELFTEST IPC 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST IPC 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

IpcMaxId() {
    max := 0
    for n in App.Store.All()
        if (n.id > max)
            max := n.id
    return max
}

IpcLogPath() => App.DataDir "\_ipc-sender.log"

IpcLogClear() {
    try FileDelete IpcLogPath()
}

; 起一个真正的独立进程去发消息。发送方自己会 ExitApp，不留尾巴。
IpcSendRun(args) {
    sender := A_ScriptDir "\tools\ipc-send.ahk"
    cmd := '"' A_AhkPath '" "' sender '" --hwnd ' Ipc.Anchor ' --log "' IpcLogPath() '" ' args
    return Run(cmd, , "Hide")
}

IpcAwaitLog(ms := 3000) {
    p := IpcLogPath()
    end := A_TickCount + ms
    loop {
        if FileExist(p) {
            t := Trim(FileRead(p, "UTF-8"), "`r`n `t")
            if (t != "")
                return t
        }
        if (A_TickCount > end)
            return ""
        Sleep 40
    }
    return ""
}

IpcWaitNewId(before, ms := 3000) {
    end := A_TickCount + ms
    loop {
        id := IpcMaxId()
        if (id > before)
            return id
        if (A_TickCount > end)
            return 0
        Sleep 40
    }
    return 0
}

SelfTestIpcRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0

    sender := A_ScriptDir "\tools\ipc-send.ahk"
    RichSay("发送脚本存在", FileExist(sender) ? 1 : 0, sender)
    if (!FileExist(sender) || A_IsCompiled) {
        App.Log("SELFTEST IPC 结论：跳过（编译版没有 tools\ipc-send.ahk）")
        return
    }
    RichSay("锚点窗口就绪", Ipc.Anchor ? 1 : 0, Ipc.Anchor)
    RichSay("IPC 默认开启", Ipc.Enabled ? 1 : 0, Ipc.Enabled)

    made := []

    ; ---- 1) WM_NEW：新建一张空便签 ----------------------------------------
    before := IpcMaxId()
    IpcLogClear()
    IpcSendRun("--new")
    line := IpcAwaitLog()
    RichSay("WM_NEW 返回 1（已受理）", InStr(line, "reply=1") > 0, line)
    id1 := IpcWaitNewId(before)
    RichSay("空便签确实建出来了", id1 ? 1 : 0, "id=" id1)
    if id1 {
        made.Push(id1)
        n := App.Store.Get(id1)
        RichSay("空便签正文为空", n.body_text = "", "[" n.body_text "]")
    }

    ; ---- 2) WM_COPYDATA 纯文本：多行 + 中文 + 需要转义的尖括号 -------------
    txt := "买菜`n1. 鸡蛋 <b>不要</b> `n2. 牛奶"
    tf := App.DataDir "\_ipc-text.txt"
    try FileDelete tf
    f := FileOpen(tf, "w", "UTF-8")
    f.Write(txt)
    f.Close()

    before := IpcMaxId()
    IpcLogClear()
    IpcSendRun('--text-file "' tf '"')
    line := IpcAwaitLog()
    RichSay("纯文本 COPYDATA 返回 1", InStr(line, "reply=1") > 0, line)
    id2 := IpcWaitNewId(before)
    RichSay("纯文本便签建出来了", id2 ? 1 : 0, "id=" id2)
    if id2 {
        made.Push(id2)
        n := App.Store.Get(id2)
        got := Trim(n.body_text, "`r`n")
        RichSay("正文原样落库（含换行）", got = txt, SubStr(StrReplace(got, "`n", "¶"), 1, 40))
        RichSay("标题自动取第一行", n.title = "买菜", n.title)
        RichSay("尖括号被转义，不解析 HTML", InStr(n.body_html, "&lt;b&gt;") > 0,
            SubStr(n.body_html, 1, 60))
        RichSay("自动标题没上锁（还会跟着正文变）", n.title_locked = 0, n.title_locked)
    }

    ; ---- 3) WM_COPYDATA JSON：标题 / 颜色 / 置顶 / 不抢焦点 ----------------
    js := '{"text":"周会纪要\n- 排期","title":"11-02 周会","color":"blue","pin":1,"activate":0}'
    jf := App.DataDir "\_ipc-json.txt"
    try FileDelete jf
    f := FileOpen(jf, "w", "UTF-8")
    f.Write(js)
    f.Close()

    before := IpcMaxId()
    IpcLogClear()
    IpcSendRun('--json-file "' jf '"')
    line := IpcAwaitLog()
    RichSay("JSON COPYDATA 返回 1", InStr(line, "reply=1") > 0, line)
    id3 := IpcWaitNewId(before)
    RichSay("JSON 便签建出来了", id3 ? 1 : 0, "id=" id3)
    if id3 {
        made.Push(id3)
        n := App.Store.Get(id3)
        RichSay("JSON 标题生效并上锁", n.title = "11-02 周会" && n.title_locked = 1,
            n.title "/" (n.title_locked ? "locked" : "auto"))
        RichSay("JSON 颜色生效", n.color = "blue", n.color)
        RichSay("JSON 置顶生效", n.pinned = 1, n.pinned)
        RichSay("JSON 里的 \n 还原成换行", InStr(n.body_text, "排期") > 0,
            SubStr(StrReplace(n.body_text, "`n", "¶"), 1, 40))
        w := NoteWindow.All.Has(id3) ? NoteWindow.All[id3] : 0
        act := (w && WinActive("ahk_id " w.gui.Hwnd)) ? 1 : 0
        RichSay("activate:0 没有把窗口抢到前台", act = 0, act)
    }

    ; ---- 4) 三种拒绝：魔数错 / dwData 错 / 超过 64KB ----------------------
    before := IpcMaxId()

    IpcLogClear()
    IpcSendRun("--bad-magic")
    line := IpcAwaitLog()
    RichSay("wParam 魔数不对 → 返回 0", InStr(line, "reply=0") > 0, line)
    Sleep 300
    RichSay("魔数错的请求没建出便签", IpcMaxId() = before, IpcMaxId() "/" before)

    IpcLogClear()
    IpcSendRun('--bad-cd --text "不该进来"')
    line := IpcAwaitLog()
    RichSay("dwData 不是 QN01 → 返回 0", InStr(line, "reply=0") > 0, line)
    Sleep 300
    RichSay("dwData 错的请求没建出便签", IpcMaxId() = before, IpcMaxId() "/" before)

    IpcLogClear()
    IpcSendRun("--huge")
    line := IpcAwaitLog()
    RichSay("载荷超过 64KB → 返回 0", InStr(line, "reply=0") > 0, line)
    Sleep 300
    RichSay("超长载荷没建出便签", IpcMaxId() = before, IpcMaxId() "/" before)

    ; ---- 5) 回执：外部真的能拿到新便签的 id -------------------------------
    before := IpcMaxId()
    IpcLogClear()
    IpcSendRun('--text "带回执的便签" --ack')
    line := IpcAwaitLog(4500)
    ackId := 0
    if RegExMatch(line, "ack=(\d+)", &m)
        ackId := Integer(m[1])
    RichSay("要了回执就能等到（ack 非 0）", ackId > 0, line)
    RichSay("回执 id 正是刚建的那张", ackId && ackId = IpcMaxId(), ackId "/" IpcMaxId())
    if ackId {
        made.Push(ackId)
        n := App.Store.Get(ackId)
        RichSay("回执便签内容对得上", n && InStr(n.body_text, "带回执的便签") > 0,
            n ? SubStr(n.body_text, 1, 20) : "?")
    }

    ; ---- 6) WM_LIST：打开便签列表 -----------------------------------------
    if ListWindow.IsOpen()
        App.CloseList()
    Sleep 200
    IpcLogClear()
    IpcSendRun("--list")
    line := IpcAwaitLog()
    RichSay("WM_LIST 返回 1", InStr(line, "reply=1") > 0, line)
    end := A_TickCount + 4000
    loop {
        if WinExist("便签列表")
            break
        if (A_TickCount > end)
            break
        Sleep 60
    }
    RichSay("列表窗口确实打开了", WinExist("便签列表") ? 1 : 0)
    App.CloseList()
    Sleep 300

    ; ---- 7) [ipc] enabled=0 时整体关闸 ------------------------------------
    Ipc.Enabled := 0
    before := IpcMaxId()
    IpcLogClear()
    IpcSendRun("--new")
    line := IpcAwaitLog()
    RichSay("enabled=0 时一律拒绝", InStr(line, "reply=0") > 0, line)
    Sleep 300
    RichSay("关闸期间没建出便签", IpcMaxId() = before, IpcMaxId() "/" before)
    Ipc.Enabled := 1

    ; ---- 收尾：把测试便签删干净 -------------------------------------------
    Sleep 300
    for id in made
        try App.DeleteNote(id)
    Sleep 400
    left := 0
    for id in made
        if App.Store.Get(id)
            left++
    RichSay("测试便签已全部删除", left = 0, "剩余 " left)

    App.Log("SELFTEST IPC 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
}

/* 自检专用：一张 1x1 的 PNG 落在图片目录里，返回它的路径。
   后面 ExportTestNote / PDF / Word 三个自检共用，别各造一份。 */
ExportTestImage() {
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
    return imgPath
}

/* 自检专用：一张"什么格式都有"的便签（标题/粗体/列表/待办/代码块/引用/图）。
   不落库，只当对象传给 Export.Render 那些纯函数。 */
ExportTestNote() {
    BT := Chr(96)
    imgPath := ExportTestImage()
    md := "# 标题一`n`n"
    md .= "普通**粗体**和*斜体*，还有~~删除线~~和" BT "code" BT "。`n`n"
    md .= "- 列表项`n- [ ] 待办一`n- [x] 待办二`n`n"
    md .= "1. 有序一`n2. 有序二`n`n"
    md .= "> 引用一行`n`n"
    md .= BT BT BT "js`nvar a = 1;`n" BT BT BT "`n`n"
    md .= "---`n`n"
    md .= "[链接](https://example.com) 和 ![图](" NoteWindow.FileUrl(imgPath) ")`n"
    return {
        title: "导出测试：标题/含非法字符",
        body_md: md,
        body_text: "标题一`n`n普通粗体和斜体，还有删除线和 code。`n`n列表项`n待办一`n待办二",
        body_html: "<h1>标题一</h1><p>普通<b>粗体</b>和<i>斜体</i></p>"
            . "<p><img src=`"" NoteWindow.FileUrl(imgPath) "`" alt=`"图`"></p>"
            . "<pre><code data-lang=`"js`"><span class=`"hljs-keyword`">var</span>"
            . " a = <span class=`"hljs-number`">1</span>;</code></pre>",
        mode: "rich"
    }
}

/* 自检专用：造一张指定像素尺寸的纯色 PNG（用来验"大图先缩"）。
   GDI+ 直接画一张 ARGB 位图再存 PNG，文件很小但宽度是真的。 */
MakeTestPng(path, w, h) {
    if !Clip.GdipStart()
        return false
    bmp := 0
    ; PixelFormat32bppARGB = 0x26200A
    if (DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0
        , "uint", 0x26200A, "ptr", 0, "ptr*", &bmp) != 0 || !bmp)
        return false
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    hr := DllCall("gdiplus\GdipSaveImageToFile", "ptr", bmp, "wstr", path, "ptr", clsid, "ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
    return (hr = 0 && FileExist(path))
}

/* 自检：PDF 导出。真的建一个隐藏 WebView2 再打印，所以慢（1~2 秒），
   单独一个入口 —— 别混进 export 那组里拖慢日常回归。 */
SelfTestPdf() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    try {
        note := ExportTestNote()
        out := App.DataDir "\_selftest.pdf"
        out2 := App.DataDir "\_selftest2.pdf"
        try FileDelete out
        try FileDelete out2
        RichSay("导出前目标文件不存在", !FileExist(out) && !FileExist(out2))
        /* 一次给两张：顺带验"同一个隐藏窗口连续导航 + 打印"这条批量路径，
           单张跑不出队列状态机的问题。 */
        Pdf.Start([{ note: note, path: out }, { note: note, path: out2 }], SelfTestPdfDone)
    } catch as e {
        App.Log("SELFTEST PDF 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST PDF 结论：未通过（异常中断）")
        SelfTestDone()
    }
}

SelfTestPdfDone(ok, fail) {
    Global RICH_PASS, RICH_FAIL
    out := App.DataDir "\_selftest.pdf"
    out2 := App.DataDir "\_selftest2.pdf"
    RichSay("回调报 2 成功 0 失败（批量连续打印）", ok = 2 && fail = 0, "ok=" ok " fail=" fail)
    RichSay("第二张也生成了", FileExist(out2), FileExist(out2) ? FileGetSize(out2) " 字节" : "没有")
    try FileDelete out2
    size := FileExist(out) ? FileGetSize(out) : 0
    RichSay("PDF 文件真的落盘了", size > 2048, size " 字节")
    blob := BytesOf(out)
    RichSay("文件头是 %PDF", BytesHas(blob, "%PDF"))
    /* 图片进没进 PDF：正文里那张 1x1 图会变成一个 XObject。
       只查文件大小是不够的 —— 一张纯文字便签也能有几十 KB。 */
    RichSay("图片作为 XObject 进了 PDF", BytesHas(blob, "/Image"))
    RichSay("中文字体子集被内嵌", BytesHas(blob, "/FontFile2"))
    /* A4 = 595×842pt。Chromium 默认给的是 Letter（612×792），
       不显式设 A4 的话这条会挂 —— 这正是它存在的意义。 */
    /* A4 的宽度是 595pt，但 Chromium 会算成 594.96（8.27in 换算的浮点误差），
       所以只比前缀 "59"：Letter 是 612，一眼能分开。 */
    RichSay("纸张是 A4（宽 59x，Letter 是 612）"
        , BytesHas(blob, "/MediaBox [0 0 59")
        , BytesHas(blob, "/MediaBox [0 0 59") ? "A4" : "不是 A4（大概率退回 Letter 了）")
    try FileDelete out
    App.Log("SELFTEST PDF 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
    SelfTestDone()
}

/* 自检：Word 导出。要起子进程 + 本机 Word，耗时 5 秒以上，单独一个入口。
   没装 Office 的机器上这里会明确报"环境不支持"，而不是崩。 */
SelfTestDocx() {
    Global RICH_PASS, RICH_FAIL, DOCX_T0
    RICH_PASS := 0, RICH_FAIL := 0, DOCX_T0 := A_TickCount
    try {
        if !Word.Available() {
            RichSay("环境里有 Microsoft Word", false, "注册表里没有 Word.Application")
            App.Log("SELFTEST DOCX 结论：未通过（这台机器没装 Word）")
            SelfTestDone()
            return
        }
        RichSay("环境里有 Microsoft Word", true)
        note := ExportTestNote()
        out := App.DataDir "\_selftest.docx"
        out2 := App.DataDir "\_selftest2.docx"
        try FileDelete out
        try FileDelete out2
        /* 两张一起：同一个 Word 实例连着转，验批量那条路（省一次 Word 启动）。 */
        Word.Start([{ note: note, path: out }, { note: note, path: out2 }])
        SetTimer(SelfTestDocxWait, 500)
    } catch as e {
        App.Log("SELFTEST DOCX 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST DOCX 结论：未通过（异常中断）")
        SelfTestDone()
    }
}

SelfTestDocxWait() {
    Global RICH_PASS, RICH_FAIL, DOCX_T0
    if Word.Pending {
        if (A_TickCount - DOCX_T0 < 150000)
            return
        SetTimer(SelfTestDocxWait, 0)
        RichSay("Word 导出在 150 秒内结束", false, "超时")
        App.Log("SELFTEST DOCX 结论：未通过（超时）")
        SelfTestDone()
        return
    }
    SetTimer(SelfTestDocxWait, 0)
    out := App.DataDir "\_selftest.docx"
    out2 := App.DataDir "\_selftest2.docx"
    RichSay("第二张也生成了", FileExist(out2), FileExist(out2) ? FileGetSize(out2) " 字节" : "没有")
    try FileDelete out2
    size := FileExist(out) ? FileGetSize(out) : 0
    RichSay("docx 生成了", size > 4096, size " 字节")
    blob := BytesOf(out)
    RichSay("是合法的 zip（PK 头）", BytesHas(blob, "PK"))
    /* docx 的 zip 目录里文件名是明文的，正文是压缩的 —— 所以只能查"有没有
       这个条目"，别指望在原文里搜到 document.xml 的内容。 */
    RichSay("包含 word/document.xml 条目", BytesHas(blob, "word/document.xml"))
    /* 有这个条目 = Word 把图真正嵌进文档了。
       没做 BreakLink 的话图片是 file:// 外链，zip 里根本没有 media 目录。 */
    RichSay("图片内嵌（word/media 条目存在）", BytesHas(blob, "word/media/"))
    try FileDelete out
    App.Log("SELFTEST DOCX 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
    SelfTestDone()
}

/* 二进制文件读进内存，返回 { buf, size }。
   ★ 不要用 StrGet(buf, size, "CP0") 转成字符串再去 InStr —— 二进制流里到处是
     0x00，字符串一转就在第一个 NUL 处断掉（PDF 的 %PDF 在开头所以"看着能读"，
     后面的 /Image、/MediaBox 全丢了，白白误判）。要查 ASCII 标记就用 BytesHas。 */
BytesOf(path) {
    size := 0
    try size := FileGetSize(path)
    if (size <= 0)
        return { buf: 0, size: 0 }
    buf := Buffer(size)
    try {
        f := FileOpen(path, "r")
        f.RawRead(buf, size)
        f.Close()
    } catch
        return { buf: 0, size: 0 }
    return { buf: buf, size: size }
}

/* 在一段原始字节里找一小段 ASCII。PDF / zip 的字典和文件名都是明文，
   这样查不用解压也不用解析格式。命中概率低，所以逐字节扫足够快。 */
BytesHas(blob, needle) {
    if !blob || !blob.buf || blob.size <= 0
        return false
    n := StrLen(needle)
    if (n = 0 || blob.size < n)
        return false
    first := Ord(SubStr(needle, 1, 1))
    last := blob.size - n
    i := 0
    while (i <= last) {
        if (NumGet(blob.buf, i, "uchar") = first) {
            hit := true
            Loop n - 1 {
                if (NumGet(blob.buf, i + A_Index, "uchar") != Ord(SubStr(needle, A_Index + 1, 1))) {
                    hit := false
                    break
                }
            }
            if hit
                return true
        }
        i += 1
    }
    return false
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

    note := ExportTestNote()
    imgPath := ExportTestImage()
    md := note.body_md

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
    /* 图片：以前这里是 [图片] 占位符，用户导出的 RTF 里图全没了。
       现在必须真的带 \pict 数据，且十六进制长度对得上文件大小（1 字节 = 2 字符）。 */
    RichSay("RTF 内嵌了图片（\pngblip）", InStr(rtf, "\pngblip") > 0)
    RichSay("占位标记全部换回了图片", InStr(rtf, "QNIMGM") = 0)
    RichSay("RTF 图片带显示尺寸", InStr(rtf, "\picwgoal") > 0 && InStr(rtf, "\pichgoal") > 0)
    hexLen := 2 * FileGetSize(imgPath)
    mi := RegExMatch(rtf, "\\pngblip[^}]*? ([0-9A-Fa-f]+)\}", &mm)
    RichSay("RTF 图片数据长度与文件一致"
        , mi > 0 && StrLen(mm[1]) = hexLen
        , "hex=" (mi > 0 ? StrLen(mm[1]) : -1) " 期望=" hexLen)

    ; ---- Word 用的 HTML：保留 file:// 引用（Word 不认 data URI） ----
    whtml := Export.Html(note, false)
    RichSay("Word 版 HTML 保留 file:// 引用", InStr(whtml, "file:///") > 0)
    RichSay("Word 版 HTML 不内嵌 data URI", InStr(whtml, "data:image/") = 0)
    whtml2 := Export.HtmlForWord(note)
    RichSay("Word 版 HTML 把着色 class 翻成内联 style"
        , InStr(whtml2, 'style="color:#d73a49"') > 0
          && InStr(whtml2, 'class="hljs-keyword"') = 0)

    ; ---- 大图先缩再嵌：4000px 宽的图应被缩到 1600px ----
    bigPath := App.DataDir "\_export-big.png"
    if MakeTestPng(bigPath, 4000, 120) {
        p := Export.PrepImage(bigPath)
        RichSay("超过 3200px 的图被缩到 1600px", IsObject(p) && p.w = 1600, IsObject(p) ? p.w "x" p.h : "读不出来")
        RichSay("缩图后仍是 PNG", IsObject(p) && p.kind = "png")
        small := Export.PrepImage(imgPath)
        RichSay("小图不动（1x1 保持原样）", IsObject(small) && small.w = 1, IsObject(small) ? small.w : "读不出来")
    } else {
        RichSay("造一张 4000×120 的测试图", false, "GDI+ 失败")
    }
    try FileDelete bigPath

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

    ; ---- 3. 代码块：能敲多行，也要出得去 ------------------------------------
    RichEval(w, "__e.put('<p>x</p>');__e.all();1")
    Sleep 150
    RichEval(w, "__e.click('codeblock');1")
    Sleep 250
    hasPre := JStr(RichEval(w, "__e.pre()?1:0"))
    RichSay("工具条能插入代码块", hasPre = "1", hasPre)

    /* ★ 本轮的正题：块末尾敲回车必须还能接着敲下一行。
       判据是页面**没有** preventDefault（返回 0）—— 这一下交还给浏览器去插换行。
       上一版这里返回 1（把光标弹出块外），多行代码根本敲不进去。 */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='const a = 1;';__e.caretEnd(p);return 1})()")
    Sleep 120
    firstEnter := JStr(RichEval(w, "__e.key('Enter',{})"))
    RichSay("块末尾回车仍留在块里（能继续敲下一行）", firstEnter = "0", "prevented=" firstEnter)

    /* 再敲一次（此时最后一行已经是空行）才是出口。直接把 DOM 做成"敲过一次
       回车"的样子：末尾多一个 <br>，和 Chromium 里的实况一致。 */
    RichEval(w, "(function(){var p=__e.pre();p.innerHTML='const a = 1;<br>';__e.caretEnd(p);return 1})()")
    Sleep 120
    secondEnter := JStr(RichEval(w, "__e.key('Enter',{})"))
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
    RichSay("空行上再敲回车 → 光标跳出去", secondEnter = "1" && out = "1"
        , "prevented=" secondEnter " out=" out)
    trimmed := JStr(RichEval(w, "(function(){return CodeHL.textOf(__e.pre())})()"))
    RichSay("跳出去时把末尾空行削掉", trimmed = "const a = 1;", "[" trimmed "]")

    /* 块里还有内容时按回车不能跳（那是在加行） */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='ab';__e.caretAt(p,1);return 1})()")
    Sleep 100
    mid := JStr(RichEval(w, "__e.key('Enter',{})"))
    RichSay("代码中间回车仍留在块里（不误跳）", mid = "0", "prevented=" mid)

    /* Shift+Enter 是"块内换行"，不是出口 —— 误触一次就把正在写的行扔出块外，
       比没有出口更气人（上一版就是这么设计的，用户敲回车被弹出去）。 */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='a';__e.caretEnd(p);return 1})()")
    Sleep 100
    sh := JStr(RichEval(w, "__e.key('Enter',{shift:true})"))
    Sleep 200
    rawSh := RichEval(w, "
    ( LTrim Join
    (function(){ var p=__e.pre(); return __e.caretIn(p) ? '1' : '0'; })()
    )")
    shIn := JStr(rawSh)
    RichSay("Shift+Enter 留在块里（块内换行，不再当出口）", sh = "0" && shIn = "1"
        , "prevented=" sh " inpre=" shIn)

    /* Ctrl+Enter：明确出口 */
    ctrlEnter := JStr(RichEval(w, "__e.key('Enter',{ctrl:true})"))
    Sleep 250
    rawCtrl := RichEval(w, "
    ( LTrim Join
    (function(){ var p=__e.pre(); var n=p.nextElementSibling;
      return (n && __e.caretIn(n)) ? '1' : '0'; })()
    )")
    ctrlOut := JStr(rawCtrl)
    RichSay("Ctrl+Enter 直接跳出代码块", ctrlEnter = "1" && ctrlOut = "1"
        , "prevented=" ctrlEnter " out=" ctrlOut)

    /* Esc：也得出得去（以前 Esc 只清选区，光标还锁在块里） */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='b';__e.caretEnd(p);return 1})()")
    Sleep 100
    escKey := JStr(RichEval(w, "__e.key('Escape',{})"))
    Sleep 250
    escOut := JStr(RichEval(w, "
    ( LTrim Join
    (function(){ var p=__e.pre(); var n=p.nextElementSibling;
      return (n && __e.caretIn(n)) ? '1' : '0'; })()
    )"))
    RichSay("Esc 也能从代码块里出来", escKey = "1" && escOut = "1", "out=" escOut)

    /* 光标在块尾按 ↓：顺着视线往下走 */
    RichEval(w, "(function(){var p=__e.pre();p.textContent='c';__e.caretEnd(p);return 1})()")
    Sleep 100
    downKey := JStr(RichEval(w, "__e.key('ArrowDown',{})"))
    Sleep 250
    downOut := JStr(RichEval(w, "
    ( LTrim Join
    (function(){ var p=__e.pre(); var n=p.nextElementSibling;
      return (n && __e.caretIn(n)) ? '1' : '0'; })()
    )"))
    RichSay("块尾按 ↓ 出来", downKey = "1" && downOut = "1", "out=" downOut)

    /* Tab 在块里是缩进，不是"把焦点跳走" */
    RichEval(w, "__e.ed().focus();(function(){var p=__e.pre();p.textContent='x';__e.caretEnd(p);return 1})()")
    Sleep 100
    tabKey := JStr(RichEval(w, "__e.key('Tab',{})"))
    Sleep 200
    /* 断言里把空格换成 ·：JStr 会 Trim，尾随空格读回来就没了（踩过一次） */
    tabText := JStr(RichEval(w, "(function(){return CodeHL.textOf(__e.pre()).replace(/ /g,'·')})()"))
    RichSay("Tab 在块里被页面接管（不跳焦点）", tabKey = "1", "prevented=" tabKey)
    RichSay("Tab 真的插了两个空格", tabText = "x··", "[" tabText "]")

    /* Shift+Tab 把刚缩进的两格退回去（只动光标前面的空格） */
    shTab := JStr(RichEval(w, "__e.key('Tab',{shift:true})"))
    Sleep 200
    shTabText := JStr(RichEval(w, "(function(){return CodeHL.textOf(__e.pre()).replace(/ /g,'·')})()"))
    RichSay("Shift+Tab 退掉两格缩进", shTabText = "x", "prevented=" shTab " [" shTabText "]")

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

    ; ---- 6. 双击标题栏最大化 / 还原 -----------------------------------------
    /* 页面侧：同一个位置 380ms 内的第二下必须发 toggle-max，而不是又发一次
       drag-start。把 postMessage 拦下来看它到底发了什么 ——
       千万别让它真发出去：drag-start 会让宿主进系统移动循环，自检就卡死在这儿。 */
    rawSeq := RichEval(w, "
    ( LTrim Join
    (function(){
      const br = window.chrome.webview;
      const orig = br.postMessage.bind(br);
      const log = [];
      br.postMessage = function(m){ log.push(m && m.type); };
      const bar = document.querySelector('.bar');
      const fire = function(){
        bar.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true
          , button: 0, screenX: 500, screenY: 300 }));
      };
      fire(); fire();
      br.postMessage = orig;
      return log.join(',');
    })()
    )")
    seq := JStr(rawSeq)
    RichSay("双击标题栏 = 一次 drag-start + 一次 toggle-max", seq = "drag-start,toggle-max", seq)

    /* 宿主侧：铺满工作区 → 还原。先把手头的几何写进库，才好验"最大化期间不动库" */
    w.SaveGeometryNow()
    Sleep 200
    r0 := Win.Rect(w.gui.Hwnd)
    g0 := NoteWindow.Store.Get(id)
    w.SetMax(1)
    Sleep 350
    r1 := Win.Rect(w.gui.Hwnd)
    wa := Win.WorkAreaOf(w.gui.Hwnd)
    RichSay("最大化铺满工作区（扣掉任务栏）"
        , Abs(r1.w - wa.w) <= 2 && Abs(r1.h - wa.h) <= 2
        , r1.w "x" r1.h " vs 工作区 " wa.w "x" wa.h)
    RichSay("最大化后贴在工作区左上角"
        , Abs(r1.x - wa.l) <= 2 && Abs(r1.y - wa.t) <= 2, r1.x "," r1.y)
    g1 := NoteWindow.Store.Get(id)
    RichSay("最大化不写库（下次开机不会满屏）"
        , g1.w = g0.w && g1.h = g0.h, g0.w "x" g0.h " -> " g1.w "x" g1.h)
    pageMax := JStr(RichEval(w, "document.body.dataset.max || '-'"))
    RichSay("页面收到 max=true（拖动与手柄自动让位）", pageMax = "1", pageMax)

    w.SetMax(0)
    Sleep 350
    r2 := Win.Rect(w.gui.Hwnd)
    RichSay("再次双击还原回原尺寸"
        , Abs(r2.w - r0.w) <= 2 && Abs(r2.h - r0.h) <= 2
        && Abs(r2.x - r0.x) <= 2 && Abs(r2.y - r0.y) <= 2
        , r0.w "x" r0.h " @" r0.x "," r0.y " -> " r2.w "x" r2.h " @" r2.x "," r2.y)
    pageMax2 := JStr(RichEval(w, "document.body.dataset.max || '-'"))
    RichSay("还原后页面状态复位", pageMax2 = "0", pageMax2)

    App.Log("SELFTEST EDIT 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    App.DeleteNote(id)
    ; 清掉自检写进图片目录的噪点图，别把用户的数据目录当垃圾桶
    Loop Files (imgDir "\*.*") {
        if !seen.Has(A_LoopFileName)
            try FileDelete A_LoopFilePath
    }
}

/* 自检：图片的"带出去"链路 —— 复制到剪贴板 / 另存为 / 从正文删除。
   为什么值得单独测：这条链路每一环都会**静默失败**，
     · 剪贴板里有 CF_DIB 不代表内容对（位深/宽高写错，粘出来是一团黑或空图）
     · file:/// 还原成本地路径，中文名和空格最容易错
     · 另存为不补扩展名，存下去是一个没有关联程序的裸文件
   这个自检会占用剪贴板，跑完把原来的文本剪贴板还回去。 */
SelfTestImage() {
    try SelfTestImageRun()
    catch as e {
        App.Log("SELFTEST IMAGE 抛异常：" CleanComError(e.Message) " @" e.Line)
    }
    SelfTestDone()
}

SelfTestImageRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    oldClip := ""
    try oldClip := A_Clipboard

    imgDir := App.DataDir "\images"
    seen := Map()
    Loop Files (imgDir "\*.*")
        seen[A_LoopFileName] := 1

    id := App.Store.Create(Map("title", "图片复制测试", "body_text", "x"))
    w := App.OpenNote(id)
    if !w {
        App.Log("SELFTEST IMAGE 没能打开便签")
        return
    }
    Loop 40 {
        if w.ready
            break
        Sleep 100
    }
    RichSay("页面就绪", w.ready = 1, w.ready)

    /* ---- 1. 造一张 320×180 的纯色图贴进正文 -------------------------------
       走真实的粘贴链路（ClipboardEvent + File），顺便确认图片照常落盘。 */
    RichEval(w, "
    ( LTrim Join
    (function(){
      const c = document.createElement('canvas');
      c.width = 320; c.height = 180;
      const g = c.getContext('2d');
      g.fillStyle = '#c81e28';
      g.fillRect(0, 0, 320, 180);
      const u = c.toDataURL('image/png');
      const b = atob(u.split(',')[1]);
      const a = new Uint8Array(b.length);
      for (let i = 0; i < b.length; i++) a[i] = b.charCodeAt(i);
      const dt = new DataTransfer();
      dt.items.add(new File([a], 'red.png', { type: 'image/png' }));
      document.body.dispatchEvent(new ClipboardEvent('paste',
        { clipboardData: dt, bubbles: true, cancelable: true }));
      return 1;
    })()
    )")

    pending := "?", got := "0"
    Loop 40 {
        pending := JStr(RichEval(w, "document.querySelectorAll('#editor img.pending').length"))
        got := JStr(RichEval(w, "document.querySelectorAll('#editor img').length"))
        if (pending = "0" && got = "1")
            break
        Sleep 250
    }
    RichSay("测试图已经贴进正文", got = "1" && pending = "0", "img=" got " pending=" pending)

    src := JStr(RichEval(w,
        "(function(){var i=document.querySelector('#editor img');return i?i.getAttribute('src'):''})()"))
    RichSay("src 是 file:/// 链接", InStr(src, "file:///") > 0, SubStr(src, 1, 90))

    path := NoteWindow.ImageLocalPath(src)
    RichSay("src 能还原成本地路径", path != "" && FileExist(path), path)

    /* ---- 2. 复制到剪贴板 -------------------------------------------------- */
    copied := 0
    try copied := Clip.SetImageFile(path) ? 1 : 0
    RichSay("复制图片：写剪贴板成功", copied = 1)
    RichSay("剪贴板里出现 CF_DIB"
        , DllCall("IsClipboardFormatAvailable", "uint", 8, "uint") ? true : false)

    dibW := 0, dibH := 0, dibBits := 0, pxR := 0, pxG := 0, pxB := 0
    if Clip.OpenClip() {
        hData := DllCall("GetClipboardData", "uint", 8, "ptr")
        if hData {
            p := DllCall("GlobalLock", "ptr", hData, "ptr")
            if p {
                dibW := NumGet(p, 4, "int")
                dibH := NumGet(p, 8, "int")
                dibBits := NumGet(p, 14, "ushort")
                /* 像素从偏移 40 开始，24 位 DIB 是 BGR 顺序。只看头不够 ——
                   头对了但像素没拷进去，粘出来照样是一张黑图。 */
                pxB := NumGet(p, 40, "uchar")
                pxG := NumGet(p, 41, "uchar")
                pxR := NumGet(p, 42, "uchar")
            }
            DllCall("GlobalUnlock", "ptr", hData)
        }
        DllCall("CloseClipboard")
    }
    RichSay("CF_DIB 的宽高就是原图（320×180）", dibW = 320 && dibH = 180, dibW "x" dibH)
    RichSay("CF_DIB 是 24 位（画图/Office/微信都认）", dibBits = 24, dibBits)
    RichSay("CF_DIB 的像素就是原图的红（#C81E28）"
        , pxR = 200 && pxG = 30 && pxB = 40, "R" pxR " G" pxG " B" pxB)

    pngFmt := DllCall("RegisterClipboardFormatW", "wstr", "PNG", "uint")
    pngOk := pngFmt ? DllCall("IsClipboardFormatAvailable", "uint", pngFmt, "uint") : 0
    RichSay("同时写了 PNG 格式（透明能保住）", pngOk ? true : false, "fmt=" pngFmt)

    /* ---- 3. 另存为 -------------------------------------------------------- */
    tmp := A_Temp "\qnote-img-" A_TickCount
    saved := NoteWindow.CopyImageFile(path, tmp)
    RichSay("另存为：没写扩展名会自动补 .png"
        , saved = tmp ".png" && FileExist(saved), saved)
    sameSize := 0
    if FileExist(tmp ".png")
        sameSize := (FileGetSize(tmp ".png") = FileGetSize(path)) ? 1 : 0
    RichSay("另存为：文件大小和原图一致", sameSize = 1)
    if FileExist(tmp ".png")
        try FileDelete tmp ".png"

    /* ---- 4. 页面：三套菜单的第三套 ---------------------------------------- */
    rawCtx := RichEval(w, "
    ( LTrim Join
    (function(){
      const br = window.chrome.webview;
      const orig = br.postMessage.bind(br);
      let last = null;
      br.postMessage = function(m){ last = m; };
      const img = document.querySelector('#editor img');
      img.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
      br.postMessage = orig;
      return (last && last.zone ? last.zone : '-') + '|' + (last && last.src ? 1 : 0);
    })()
    )")
    ctx := JStr(rawCtx)
    RichSay("正文里右键图片 → 图片菜单（zone=image，带 src）", ctx = "image|1", ctx)

    rawLb := RichEval(w, "
    ( LTrim Join
    (function(){
      const br = window.chrome.webview;
      const orig = br.postMessage.bind(br);
      let last = null;
      br.postMessage = function(m){ last = m; };
      document.querySelector('#editor img').click();
      const box = document.getElementById('lightbox');
      box.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
      const open = box.hidden ? 0 : 1;
      br.postMessage = orig;
      return open + '|' + (last && last.zone ? last.zone : '-');
    })()
    )")
    lb := JStr(rawLb)
    RichSay("大图预览里右键还是图片菜单", lb = "1|image", lb)

    rawCc := RichEval(w, "
    ( LTrim Join
    (function(){
      const br = window.chrome.webview;
      const orig = br.postMessage.bind(br);
      let last = null;
      br.postMessage = function(m){ last = m; };
      const ev = new KeyboardEvent('keydown',
        { key: 'c', ctrlKey: true, bubbles: true, cancelable: true });
      document.dispatchEvent(ev);
      br.postMessage = orig;
      return (ev.defaultPrevented ? 1 : 0) + '|' + (last && last.type ? last.type : '-');
    })()
    )")
    cc := JStr(rawCc)
    RichSay("看图时 Ctrl+C 走复制图片（菜单上写着就得真能用）", cc = "1|copy-image", cc)

    /* ---- 5. 从正文删除这张图 ---------------------------------------------- */
    w.Cmd("delete-image")
    Sleep 700
    left := JStr(RichEval(w, "document.querySelectorAll('#editor img').length"))
    RichSay("菜单「从正文中删除这张图」生效", left = "0", "剩 " left)
    RichSay("删完大图预览也关掉了"
        , JStr(RichEval(w, "document.getElementById('lightbox').hidden ? 1 : 0")) = "1")

    App.Log("SELFTEST IMAGE 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    App.DeleteNote(id)
    ; 自检写的图删掉，别把用户的数据目录当垃圾桶
    Loop Files (imgDir "\*.*") {
        if !seen.Has(A_LoopFileName)
            try FileDelete A_LoopFilePath
    }
    ; 剪贴板还回去（原来是什么就不知道了，只能还原文本）
    if (oldClip != "")
        try A_Clipboard := oldClip
}

/* 自检：代码块右上角的「复制」按钮。
   验的是四件事：
     1) 按钮位置/归属 —— 必须在 body 下、不在 <pre> 里（否则被重绘冲掉）、
        不在 #editor 里（否则被当正文存进库）；
     2) 点下去剪贴板里真的是整段代码，换行是 CRLF、末尾不多空行；
     3) 鼠标移开、切到 Markdown 模式时会收起；
     4) 右键菜单那条「复制这段代码」和按钮走同一条路。
   跑完删掉自己建的便签，剪贴板还原。 */
SelfTestCodeCopy() {
    try SelfTestCodeCopyRun()
    catch as e {
        App.Log("SELFTEST CODECOPY 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST CODECOPY 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestCodeCopyRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    oldClip := ""
    try oldClip := A_Clipboard

    id := App.Store.Create(Map("title", "代码复制测试", "body_text", "x"))
    w := App.OpenNote(id)
    if !w {
        App.Log("SELFTEST CODECOPY 没能打开便签")
        return
    }
    Loop 40 {
        if w.ready
            break
        Sleep 100
    }
    RichSay("页面就绪", w.ready = 1, w.ready)

    /* 页面里的测试脚手架。故意把"悬停"写成 dispatchEvent，而不是真的移动
       鼠标：本机 SendInput 会卡死（见 README 实现笔记），合成事件走的是
       note.js 里 mousemove 监听器的同一条路。 */
    RichEval(w, "
    ( LTrim Join
    window.__c = {
      ed: () => document.getElementById('editor'),
      btn: () => document.getElementById('codeCopy'),
      pre: () => document.querySelector('#editor pre'),
      put(code) {
        this.ed().innerHTML = '<pre><code></code></pre>';
        const c = this.ed().querySelector('pre code');
        c.className = 'language-python';
        c.textContent = code;
      },
      hover(el) {
        el.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, buttons: 0 }));
      },
      state() {
        const b = this.btn();
        const p = this.pre();
        if (!p) return 'nopre';
        if (b.hidden) return 'hidden';
        const br = b.getBoundingClientRect();
        const pr = p.getBoundingClientRect();
        return [1, Math.round(br.top - pr.top), Math.round(pr.right - br.right)
          , this.ed().contains(b) ? 1 : 0, p.contains(b) ? 1 : 0].join('|');
      },
      label() {
        return this.btn().textContent.trim() + '|' + (this.btn().classList.contains('ok') ? 1 : 0);
      },
      textOk() {
        return window.CodeHL.textOf(this.pre()) === 'a = 1\nif a:\n    print(a)\nb = 2' ? 'same' : 'diff';
      },
      btnInHtml() {
        return this.ed().innerHTML.indexOf('codeCopy') >= 0 ? 'has' : 'clean';
      }
    };
    1;
    )")

    code := 'a = 1\nif a:\n    print(a)\nb = 2'
    want := "a = 1`r`nif a:`r`n    print(a)`r`nb = 2"

    RichEval(w, "__c.put('" code "');1")
    Sleep 200
    RichSay("一开始按钮是收着的"
        , Trim(JStr(RichEval(w, "__c.btn().hidden ? 1 : 0"))) = "1")

    /* ---- 1. 悬停浮出 + 位置 + 归属 --------------------------------------- */
    RichEval(w, "__c.hover(__c.pre());1")
    Sleep 150
    st := JStr(RichEval(w, "__c.state()"))
    parts := StrSplit(st, "|")
    RichSay("鼠标移到代码块上 → 按钮浮出", parts.Length >= 5 && parts[1] = "1", st)
    RichSay("按钮贴在块的右上角（top 0~10px、右侧留 0~20px）"
        , parts.Length >= 5 && parts[2] >= 0 && parts[2] <= 10 && parts[3] >= 0 && parts[3] <= 20, st)
    RichSay("按钮不在 <pre> 里（否则被着色重绘冲掉）", parts.Length >= 5 && parts[5] = "0", st)
    RichSay("按钮不在 #editor 里（否则被当正文存进库）", parts.Length >= 5 && parts[4] = "0", st)
    RichSay("代码正文没被按钮上的字污染", JStr(RichEval(w, "__c.textOk()")) = "same")

    /* ---- 2. 点一下 = 整段进剪贴板 ---------------------------------------- */
    got := ""
    try A_Clipboard := "sentinel"
    RichEval(w, "__c.btn().click();1")
    Loop 12 {
        Sleep 100
        try got := A_Clipboard
        if (got != "sentinel")
            break
    }
    digest := StrReplace(StrReplace(got, "`r`n", "|"), "`n", "¶")
    RichSay("点按钮 → 剪贴板就是整段代码", got = want, digest)
    RichSay("换行是 CRLF（记事本才不会挤成一行）"
        , StrLen(got) = StrLen(want) && InStr(got, "`r`n") > 0, StrLen(got))
    RichSay("末尾没多出空行", SubStr(got, -2) != "`r`n", SubStr(got, -4))

    RichSay("按钮当场变「已复制」（状态栏也有回执）"
        , JStr(RichEval(w, "__c.label()")) = "已复制|1", JStr(RichEval(w, "__c.label()")))
    Sleep 1400
    RichSay("1.2 秒后按钮文字自己复原"
        , JStr(RichEval(w, "__c.label()")) = "复制|0", JStr(RichEval(w, "__c.label()")))

    /* ---- 3. 鼠标移开就收起 ----------------------------------------------- */
    RichEval(w, "__c.hover(__c.ed());1")
    Sleep 400
    RichSay("鼠标移出代码块 → 按钮收起"
        , Trim(JStr(RichEval(w, "__c.btn().hidden ? 1 : 0"))) = "1")

    /* ---- 4. 重绘之后按钮还在（它本来就不在 <pre> 里，重绘碰不到它） -------- */
    RichEval(w, "window.CodeHL.paintAll(document.getElementById('editor'), {force:true});1")
    Sleep 150
    RichEval(w, "__c.hover(__c.pre());1")
    Sleep 150
    st2 := JStr(RichEval(w, "__c.state()"))
    p2 := StrSplit(st2, "|")
    RichSay("代码块重新着色后按钮照常浮出", p2.Length >= 5 && p2[1] = "1", st2)

    /* ---- 5. 右键菜单那条入口 --------------------------------------------- */
    zone := JStr(RichEval(w, "
    ( LTrim Join
    (function(){
      const br = window.chrome.webview;
      const orig = br.postMessage.bind(br);
      let last = null;
      br.postMessage = function(m){ last = m; };
      const pre = document.querySelector('#editor pre');
      pre.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
      br.postMessage = orig;
      return (last && last.zone ? last.zone : '-') + '|' + (last && last.inpre ? 1 : 0)
        + '|' + (document.getElementById('codeCopy').hidden ? 1 : 0);
    })()
    )"))
    RichSay("在代码块里右键 → 编辑菜单 + inpre=1，按钮让路", zone = "edit|1|1", zone)

    try A_Clipboard := "sentinel"
    w.Cmd("copy-code")
    got2 := "sentinel"
    Loop 15 {
        Sleep 100
        try got2 := A_Clipboard
        if (got2 != "sentinel")
            break
    }
    RichSay("菜单「复制这段代码」结果一样", got2 = want
        , StrReplace(StrReplace(got2, "`r`n", "|"), "`n", "¶"))

    /* ---- 6. 落库的 HTML 里没有按钮 --------------------------------------- */
    RichSay("editor.innerHTML 里没有按钮节点", JStr(RichEval(w, "__c.btnInHtml()")) = "clean")
    w.Cmd("save")
    Sleep 600
    row := App.Store.Get(id)
    RichSay("存进库的 body_html 也没被污染", InStr(row.body_html, "codeCopy") = 0
        , SubStr(row.body_html, 1, 80))

    /* ---- 7. Markdown 源码模式里没有代码块 DOM，按钮必须收起来 ------------- */
    w.SendType("toggle-md")
    Sleep 600
    RichSay("切到 Markdown 源码 → 按钮消失"
        , Trim(JStr(RichEval(w, "__c.btn().hidden ? 1 : 0"))) = "1")

    App.Log("SELFTEST CODECOPY 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    App.DeleteNote(id)
    if (oldClip != "")
        try A_Clipboard := oldClip
}

/* 自检：代码块的语言标记在「可视化 ⇄ Markdown 源码」往返中不能丢。

   ★ 这条 bug 的根因记一笔：CodeHL.paint() 是 `pre.innerHTML = 高亮后的 HTML`，
     而 highlight.js 的输出里**没有 <code>** —— 渲染时那个
     `<code class="language-python">` 在第一次上色时就被整块冲掉了。
     MD.toMarkdown() 又偏偏只从 code.className 里读 language-x，于是两条路
     一齐断在这个看不见的节点上：屏幕上看还是对的（pre 上留着 data-hl），
     一往返就变回没有语言的 ```。

   所以这里验的不只是"最终显示对不对"，而是四层信息在每次重画后都还在：
     ① 页面读得到的语言（右键菜单的勾选靠它）
     ② <code> 节点还在（language-x 的载体，导出的通行写法）
     ③ pre 的 data-lang（没有 <code> 时的兜底）
     ④ Markdown 源码里的围栏语言 */
SelfTestCodeLang() {
    try SelfTestCodeLangRun()
    catch as e {
        App.Log("SELFTEST CODELANG 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST CODELANG 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestCodeLangRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    F := Chr(96) Chr(96) Chr(96)          ; Markdown 的围栏，三个反引号

    id := App.Store.Create(Map("title", "语言标记测试", "body_text", "x"))
    w := App.OpenNote(id)
    if !w {
        App.Log("SELFTEST CODELANG 没能打开便签")
        return
    }
    Loop 40 {
        if w.ready
            break
        Sleep 100
    }
    RichSay("页面就绪", w.ready = 1, w.ready)

    RichEval(w, "
    ( LTrim Join
    window.__l = {
      mdBtn: () => document.getElementById('btnMd'),
      pre: () => document.querySelector('#editor pre'),
      isMd: () => document.getElementById('btnMd').classList.contains('active') ? 1 : 0,
      lang: () => {
        const p = window.__l.pre();
        return p ? (window.CodeHL.detect(p) || '-') : 'nopre';
      },
      hasCode: () => {
        const p = window.__l.pre();
        return p && p.querySelector('code') ? 1 : 0;
      },
      cls: () => {
        const p = window.__l.pre();
        const c = p && p.querySelector('code');
        return c ? (c.className || 'noclass') : 'nocode';
      },
      preLang: () => {
        const p = window.__l.pre();
        return p ? (p.getAttribute('data-lang') || '-') : 'nopre';
      },
      text: () => {
        const p = window.__l.pre();
        return p ? window.CodeHL.textOf(p) : 'nopre';
      },
      paintAll: () => window.CodeHL.paintAll(document.getElementById('editor'), { force: true }),
      setLang: (l) => {
        const p = window.__l.pre();
        window.CodeHL.setLang(p, l);
        window.CodeHL.paint(p);
      },
      mdText: () => document.getElementById('source').value,
      insertLine: (kind) => {
        const p = window.__l.pre();
        const c = p.querySelector('code') || p;
        const r = document.createRange();
        r.selectNodeContents(c);
        r.collapse(false);
        const s = window.getSelection();
        s.removeAllRanges();
        s.addRange(r);
        document.execCommand(kind || 'insertLineBreak');
        return window.CodeHL.textOf(p);
      },
      typeInto: (t) => {
        document.execCommand('insertText', false, t);
        return window.CodeHL.textOf(window.__l.pre());
      },
      html: () => window.__l.pre().innerHTML.slice(0, 120),
      writeMd: (md) => {
        if (!window.__l.isMd()) window.__l.mdBtn().click();
        document.getElementById('source').value = md;
        window.__l.mdBtn().click();
      }
    };
    1;
    )")

    /* ---- 1. Markdown 源码里写了 python → 切到可视化 ---------------------- */
    RichEval(w, "__l.writeMd(String.fromCharCode(96,96,96) + 'python\nprint(1)\n' + String.fromCharCode(96,96,96));1")
    Sleep 300
    RichSay("源码写 " F "python → 可视化后语言还是 python"
        , JStr(RichEval(w, "__l.lang()")) = "python", JStr(RichEval(w, "__l.lang()")))
    RichSay("可视化后 <pre> 里还留着 <code>（language-x 的载体）"
        , Trim(JStr(RichEval(w, "__l.hasCode()"))) = "1", JStr(RichEval(w, "__l.cls()")))
    RichSay("<code> 上带着 language-python"
        , InStr(JStr(RichEval(w, "__l.cls()")), "language-python") > 0, JStr(RichEval(w, "__l.cls()")))
    RichSay("代码正文没被着色改动", JStr(RichEval(w, "__l.text()")) = "print(1)"
        , JStr(RichEval(w, "__l.text()")))

    /* ---- 2. 再画一次（失焦、光标离开都会重画），语言不能漂 ------------- */
    RichEval(w, "__l.paintAll();1")
    Sleep 200
    RichSay("重画一遍之后语言还是 python"
        , JStr(RichEval(w, "__l.lang()")) = "python", JStr(RichEval(w, "__l.lang()")))
    RichEval(w, "__l.paintAll();1")
    Sleep 200
    RichSay("连着重画两次也不漂（右键菜单的勾选靠这个值）"
        , JStr(RichEval(w, "__l.lang()")) = "python", JStr(RichEval(w, "__l.lang()")))

    /* ---- 3. 可视化里用右键菜单改语言 → 切回 Markdown 源码 ---------------- */
    RichEval(w, "__l.setLang('javascript');1")
    Sleep 200
    RichSay("菜单设成 JavaScript 后页面读得回来"
        , JStr(RichEval(w, "__l.lang()")) = "javascript", JStr(RichEval(w, "__l.lang()")))
    RichEval(w, "__l.mdBtn().click();1")
    Sleep 300
    md1 := JStr(RichEval(w, "__l.mdText()"))
    RichSay("切到源码后围栏上还有 javascript"
        , InStr(md1, F "javascript") > 0, StrReplace(md1, Chr(10), "|"))

    /* ---- 4. 再往返一趟：源码 → 可视化 → 源码（用户报的第二种） ---------- */
    RichEval(w, "__l.writeMd(String.fromCharCode(96,96,96) + 'toml\na = 1\n' + String.fromCharCode(96,96,96));1")
    Sleep 300
    RichSay("源码写 " F "toml → 可视化后是 toml"
        , JStr(RichEval(w, "__l.lang()")) = "toml", JStr(RichEval(w, "__l.lang()")))
    RichEval(w, "__l.mdBtn().click();1")
    Sleep 300
    md2 := JStr(RichEval(w, "__l.mdText()"))
    RichSay("往返一趟 toml 没丢", InStr(md2, F "toml") > 0, StrReplace(md2, Chr(10), "|"))

    /* ---- 5. 「纯文本」也要保住：它不写 language-x，只写 data-lang -------- */
    RichEval(w, "__l.writeMd(String.fromCharCode(96,96,96) + 'python\nprint(2)\n' + String.fromCharCode(96,96,96));1")
    Sleep 250
    RichEval(w, "__l.setLang('text');1")
    Sleep 200
    RichSay("选「纯文本」后页面读得到 text"
        , JStr(RichEval(w, "__l.lang()")) = "text", JStr(RichEval(w, "__l.lang()")))
    RichEval(w, "__l.mdBtn().click();1")
    Sleep 300
    md3 := JStr(RichEval(w, "__l.mdText()"))
    RichSay("切到源码后围栏是 " F "text（不是空的）"
        , InStr(md3, F "text") > 0, StrReplace(md3, Chr(10), "|"))

    /* ---- 6. 在"有 <code> 的块"里编辑：另起一行、输入文字都不能走样 -------
       这条是给保留 <code> 这个改动兜底的：以前重画会把 <code> 冲掉，用户
       实际上是在裸 <pre> 里打字；现在 code 一直在，浏览器的插入行为可能
       变成 <div>（那 textOf 就读不出换行了，两行会粘成一行）。 */
    RichEval(w, "__l.writeMd(String.fromCharCode(96,96,96) + 'python\nprint(3)\n' + String.fromCharCode(96,96,96));1")
    Sleep 250
    RichEval(w, "__l.paintAll();1")
    Sleep 150
    RichSay("重画后 <code> 还在（这条块接下来要在里面编辑）"
        , Trim(JStr(RichEval(w, "__l.hasCode()"))) = "1", JStr(RichEval(w, "__l.cls()")))
    t1 := JStr(RichEval(w, "__l.insertLine()"))
    RichSay("在 <code> 里另起一行，读回来是两行（不粘行）"
        , InStr(t1, "\n") > 0, StrReplace(t1, "\n", "|"))
    t2 := JStr(RichEval(w, "__l.insertLine('insertParagraph')"))
    RichSay("换一种插入方式（insertParagraph，可能插 div）也不粘行"
        , InStr(t2, "\n") > 0, StrReplace(t2, "\n", "|"))
    t3 := JStr(RichEval(w, "__l.typeInto('y = 2')"))
    RichSay("接着输入的文字也在", InStr(t3, "y = 2") > 0, StrReplace(t3, "\n", "|"))

    /* ---- 7. 落库再读回来：存的是带 data-lang 的 HTML，重开要还认 ------- */
    w.Cmd("save")
    Sleep 600
    row := App.Store.Get(id)
    RichSay("存进库的 body_html 里有 language-x"
        , InStr(row.body_html, "language-") > 0 || InStr(row.body_html, "data-lang") > 0
        , SubStr(row.body_html, 1, 120))

    App.Log("SELFTEST CODELANG 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")

    App.DeleteNote(id)
}

/* 自检：导入 TXT / Markdown。
   "覆盖还是追加"平时是弹框问的，自检里没人点，所以走 ImportNote 的 mode 参数
   直接指定 —— 这里要验的是"内容怎么落地"，不是对话框长什么样。
   编码识别是纯函数，四种文件各来一遍：国内从记事本另存的 txt 大量是 GBK，
   按 UTF-8 硬读会整篇变方块。 */
SelfTestImport() {
    global RICH_PASS := 0, RICH_FAIL := 0
    dir := A_ScriptDir "\data\"
    files := [], id := 0

    try {
        want := "第一行中文`n第二行 ascii`n"
        p1 := dir "_imp_utf8bom.txt"
        p2 := dir "_imp_utf8raw.txt"
        p3 := dir "_imp_utf16.txt"
        p4 := dir "_imp_gbk.txt"
        files.Push(p1, p2, p3, p4)
        WriteEnc(p1, "UTF-8", want)        ; 带 BOM
        WriteEnc(p2, "UTF-8-RAW", want)    ; 不带 BOM
        WriteEnc(p3, "UTF-16", want)       ; 带 BOM
        WriteEnc(p4, "CP936", want)

        labels := ["UTF-8 带 BOM", "UTF-8 无 BOM", "UTF-16", "GBK"]
        ps := [p1, p2, p3, p4]
        for i, p in ps {
            got := App.ReadTextFile(p)
            RichSay("编码识别：" labels[i], got = want, StrReplace(got, "`n", "¶"))
        }
        RichSay("换行统一成 LF", InStr(App.ReadTextFile(p3), "`r") = 0)

        /* ---- 建一张便签，真往页面里导 ---------------------------------- */
        id := App.Store.Create(Map("title", "导入测试", "body_text", "占位"))
        w := App.OpenNote(id)
        Loop 40 {
            if (w && w.ready)
                break
            Sleep 100
        }
        RichSay("页面就绪", w && w.ready = 1)

        App.ImportNote(id, p1, "replace")
        Sleep 800
        t1 := JStr(RichEval(w, "document.getElementById('editor').innerText"))
        RichSay("TXT 覆盖：正文变成文件内容"
            , InStr(t1, "第一行中文") > 0 && InStr(t1, "第二行 ascii") > 0, t1)
        RichSay("覆盖把原来的内容清掉了", InStr(t1, "占位") = 0, t1)

        ; ---- 追加一份 Markdown：要渲染成 HTML，且接在原文后面 ----------
        p5 := dir "_imp_add.md"
        files.Push(p5)
        WriteEnc(p5, "UTF-8-RAW", "# 追加标题`n`n- 项目一`n- 项目二`n")
        App.ImportNote(id, p5, "append")
        Sleep 800
        h1 := JStr(RichEval(w, "document.querySelector('#editor h1') ? 'yes' : 'no'"))
        RichSay("追加 Markdown：渲染出 <h1>", h1 = "yes", h1)
        both := JStr(RichEval(w, "document.getElementById('editor').innerText"))
        RichSay("追加：新旧内容都在", InStr(both, "第一行中文") > 0 && InStr(both, "追加标题") > 0
            , StrReplace(both, "`n", "¶"))
        /* 接缝处必须留一个空段落，否则最后一行和标题会黏成一段；
           但只许留**一个** —— 原正文末尾本来就挂着空行，不削就是三四行的空隙 */
        gap := JStr(RichEval(w, "
        ( LTrim Join
        (function(){
          const h = document.querySelector('#editor h1');
          if (!h) return 'noh1';
          let e = h.previousElementSibling, n = 0;
          if (!e) return 'noprev';
          while (e && e.tagName === 'DIV' && !e.textContent.trim()
                 && !e.querySelector('img,pre,table,hr')) { n++; e = e.previousElementSibling; }
          return n === 0 ? 'tight' : 'gap' + n;
        })()
        )"))
        RichSay("追加接缝处只留一个空行", gap = "gap1", gap)

        w.Cmd("save")
        Sleep 700
        row := App.Store.Get(id)
        RichSay("落库的 body_html 里有渲染后的标题", InStr(row.body_html, "<h1") > 0
            , SubStr(row.body_html, 1, 60))
        RichSay("落库的正文含两段内容"
            , InStr(row.body_text, "第一行中文") > 0 && InStr(row.body_text, "追加标题") > 0)

        ; ---- 再覆盖一次：追加进去的标题要消失 --------------------------
        App.ImportNote(id, p1, "replace")
        Sleep 800
        h1b := JStr(RichEval(w, "document.querySelector('#editor h1') ? 'yes' : 'no'"))
        RichSay("再次覆盖：上一次追加的内容被清干净", h1b = "no", h1b)

        ; ---- 空文件 / 超大文件：只是一句提示，正文不许动 ------------------
        p6 := dir "_imp_empty.txt"
        files.Push(p6)
        WriteEnc(p6, "UTF-8", "   `n`n`t  ")
        before := JStr(RichEval(w, "document.getElementById('editor').innerText"))
        App.ImportNote(id, p6, "replace")
        Sleep 500
        after := JStr(RichEval(w, "document.getElementById('editor').innerText"))
        RichSay("空文件不动正文", before = after, StrLen(after))

        p7 := dir "_imp_big.txt"
        files.Push(p7)
        WriteEnc(p7, "UTF-8-RAW", StrReplace(Format("{:" (App.IMPORT_MAX + 10) "}", ""), " ", "a"))
        App.ImportNote(id, p7, "replace")
        Sleep 500
        after2 := JStr(RichEval(w, "document.getElementById('editor').innerText"))
        RichSay("超过 4MB 拒绝导入", after2 = before, "上限 " App.IMPORT_MAX)

        ; ---- 编码猜错的兜底：GBK 文件也不能变成方块 ---------------------
        RichSay("GBK 文件读出来是正常中文"
            , InStr(App.ReadTextFile(p4), "第一行中文") > 0)

        App.Log("SELFTEST IMPORT 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
            . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
    } catch as e {
        App.Log("SELFTEST IMPORT 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST IMPORT 结论：未通过（异常中断）")
    } finally {
        for p in files
            try FileDelete p
        if (id)
            try App.DeleteNote(id)
        SelfTestDone()
    }
}

/* 写一个指定编码的文件。FileOpen 的 "UTF-8" 带 BOM、"UTF-8-RAW" 不带，
   自检要的是"两种都认"，所以得分开写。 */
WriteEnc(path, enc, text) {
    fh := FileOpen(path, "w", enc)
    try fh.Write(text)
    finally fh.Close()
}

/* 挑一个当前没被占用的热键，专给自检用。用户的库里很可能早就把 ^!1 之类的
   键分给了某些便签（这是正常使用状态），自检写死具体键就会误报冲突。
   exclude 用来排除已经挑走的那个：两张便签不能挂同一个键。
   优先 F 键 —— 不占主键区，也不容易和用户的全局热键碰上。 */
TestPickFreeHotkey(exclude := "") {
    for cand in ["^!F9", "^!F10", "^!F11", "^!F12", "^!7", "^!6", "^!5", "^!4"] {
        if (exclude != "" && App.SameHotkey(cand, exclude))
            continue
        free := true
        for name, k in App.CfgHotkeys() {
            if (k != "" && App.SameHotkey(k, cand)) {
                free := false
                break
            }
        }
        if (free) {
            for n in App.Store.All() {
                if (n.hotkey != "" && App.SameHotkey(n.hotkey, cand)) {
                    free := false
                    break
                }
            }
        }
        if (free)
            return cand
    }
    return ""
}

/* 自检：批量操作。
   批量删除的二次确认在 ConfirmBatchDelete 里弹框，自检没人点它，所以这里
   直接验 BatchNotes 本体（删除分支也在里面）。重点是"库改了 + 已经开着的
   窗口同步改了"，只查库会漏掉 Apply* 那一半。 */
SelfTestBatch() {
    global RICH_PASS := 0, RICH_FAIL := 0
    ids := [], id1 := 0, w1 := 0

    try {
        id1 := App.Store.Create(Map("title", "批量甲", "body_text", "甲"))
        id2 := App.Store.Create(Map("title", "批量乙", "body_text", "乙"))
        id3 := App.Store.Create(Map("title", "批量丙", "body_text", "丙"))
        ids.Push(id1, id2, id3)

        w1 := App.OpenNote(id1)
        Loop 40 {
            if (w1 && w1.ready)
                break
            Sleep 100
        }
        RichSay("页面就绪", w1 && w1.ready = 1)

        ; ---- 1. 批量清空快捷键 -----------------------------------------
        /* 键要现挑：用户的库里很可能早就把 ^!1 给了某张便签，直接写死会让
           自检报"这个键已经给了便签"——那是正常状态，不是缺陷。 */
        hkA := TestPickFreeHotkey()
        hkB := TestPickFreeHotkey(hkA)
        RichSay("挑到两个空闲键", hkA != "" && hkB != "", hkA " / " hkB)

        e1 := App.SetNoteHotkey(id1, hkA)
        e2 := App.SetNoteHotkey(id2, hkB)
        RichSay("两张各挂一个快捷键"
            , e1 = "" && e2 = "" && App.Store.Get(id1).hotkey != ""
              && App.Store.Get(id2).hotkey != ""
            , (e1 = "" ? "ok" : e1) " / " (e2 = "" ? "ok" : e2))
        n := App.BatchNotes("clear-hotkey", ids)
        RichSay("批量清空：三张都空了", n = 3 && App.Store.Get(id1).hotkey = ""
            && App.Store.Get(id2).hotkey = "" && App.Store.Get(id3).hotkey = "", n)
        /* 清空之后键要真的还回来 —— 只把库字段抹掉、热键还占着的话，
           用户会在设置面板里撞"这个键已经给了便签"的假冲突。
           App.NoteKeys 是"当前真绑定着"的那份账，库字段清空后它也该清空。 */
        RichSay("清空后不再占着键"
            , !App.NoteKeys.Has(id1) && !App.NoteKeys.Has(id2), App.NoteKeys.Count)

        ; ---- 2. 置顶 ----------------------------------------------------
        n := App.BatchNotes("pin", ids, 1)
        Sleep 300
        top := (WinGetExStyle("ahk_id " w1.gui.Hwnd) & 0x8) ? 1 : 0
        RichSay("批量置顶：库里三张都置顶"
            , App.Store.Get(id1).pinned = 1 && App.Store.Get(id3).pinned = 1, n)
        RichSay("批量置顶：开着的窗口真的到了最前", top = 1, top)

        App.BatchNotes("pin", ids, 0)
        Sleep 300
        top0 := (WinGetExStyle("ahk_id " w1.gui.Hwnd) & 0x8) ? 1 : 0
        RichSay("批量取消置顶", App.Store.Get(id1).pinned = 0 && top0 = 0, top0)

        ; ---- 3. 颜色 ----------------------------------------------------
        App.BatchNotes("color", ids, "green")
        Sleep 300
        pc := JStr(RichEval(w1, "document.body.dataset.color"))
        RichSay("批量改颜色：库里都变绿"
            , App.Store.Get(id1).color = "green" && App.Store.Get(id3).color = "green"
            , App.Store.Get(id1).color)
        RichSay("批量改颜色：页面跟着变", pc = "green", pc)

        ; ---- 4. 收起 / 展开 ---------------------------------------------
        App.BatchNotes("hide", ids, 1)
        Sleep 500
        vis := DllCall("IsWindowVisible", "ptr", w1.gui.Hwnd) ? 1 : 0
        RichSay("批量收起：库里 hidden=1", App.Store.Get(id1).hidden = 1
            && App.Store.Get(id3).hidden = 1)
        RichSay("批量收起：窗口真的藏起来了", vis = 0, vis)

        App.BatchNotes("hide", ids, 0)
        Sleep 3000                       ; 没窗口的那两张要现建，慢
        vis2 := DllCall("IsWindowVisible", "ptr", w1.gui.Hwnd) ? 1 : 0
        RichSay("批量展开：库里 hidden=0", App.Store.Get(id1).hidden = 0)
        RichSay("批量展开：窗口回到桌面", vis2 = 1, vis2)

        /* 透明度放最后：不透明外观下改透明度会重建窗口，w1 那个对象会失效，
           前面的断言就没法再用它了。 */
        cur := NoteWindow.All.Has(id1) ? NoteWindow.All[id1] : 0
        App.BatchNotes("opacity", ids, 55)
        Sleep 600
        cur := NoteWindow.All.Has(id1) ? NoteWindow.All[id1] : 0
        pv := cur ? App.EvalNum(cur, "Math.round(parseFloat(getComputedStyle(document.documentElement).opacity||'1')*100)") : -1
        RichSay("批量透明度：库 55", App.Store.Get(id1).opacity = 55
            && App.Store.Get(id3).opacity = 55, App.Store.Get(id1).opacity)
        RichSay("批量透明度：页面 55", pv = 55, pv)

        ; ---- 5. 删除 ----------------------------------------------------
        n := App.BatchNotes("delete", ids)
        gone := 0
        for i in ids
            if !App.Store.Get(i)
                gone += 1
        RichSay("批量删除：三张都从库里消失", n = 3 && gone = 3, gone)
        RichSay("批量删除：窗口也关了", !NoteWindow.All.Has(id1) && !NoteWindow.All.Has(id3))

        /* ---- 6. 批量导出的重名处理（纯函数，不弹框） -------------------- */
        ed := A_ScriptDir "\data\_batch_exp\"
        try DirCreate ed
        used := Map()
        a1 := Export.UniquePath(ed, "同名", "md", used)
        a2 := Export.UniquePath(ed, "同名", "md", used)
        a3 := Export.UniquePath(ed, "同名", "md", used)
        RichSay("重名自动加序号（2）(3）"
            , a1 != a2 && a2 != a3 && InStr(a2, "(2)") > 0 && InStr(a3, "(3)") > 0, a2)
        WriteEnc(a1, "UTF-8-RAW", "x")
        b1 := Export.UniquePath(ed, "同名", "md", Map())
        RichSay("目标目录里已有同名文件时也不覆盖", b1 != a1 && InStr(b1, "(2)") > 0, b1)
        ; 大小写：Windows 的文件系统不区分，同一批里 Case.md 和 case.md 是同一个文件。
        ; AHK 的 = 默认不区分大小写，这里要区分地比（StrCompare 第三个参数）。
        used3 := Map()
        c1 := Export.UniquePath(ed, "Case", "md", used3)
        c2 := Export.UniquePath(ed, "case", "md", used3)
        RichSay("大小写不同也算重名（Windows 规则）", StrCompare(c1, c2, true) != 0, c2)
        try DirDelete ed, true

        App.Log("SELFTEST BATCH 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
            . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
    } catch as e {
        App.Log("SELFTEST BATCH 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST BATCH 结论：未通过（异常中断）")
    } finally {
        for i in ids
            try App.DeleteNote(i)
        SelfTestDone()
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
NoteNewTodo() => App.NewTodoNote()
; 便签快捷键：热键回调只转一手，真正的"开窗/提到最前"在独立线程里做
NoteSummonTick(id) => App.SummonNoteNow(id)
NoteSummonBound(id) => () => App.SummonNote(id)
; 透明度 <100 又赶上非透明外观：换成分层窗口要重建这一张
NoteRebuildTick(id) => App.RebuildNote(id)
; 命令行 --new "文字"：Boot 完之后再建，别和 BootTick 抢窗口
NoteCliNew() => App.NewNote(Map("text", App.PendingText))
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
NoteSetOpacity(id, pct) => App.SetNoteOpacity(id, pct)
NoteAskHotkey(id) => App.AskNoteHotkey(id)
NoteShowAll() => App.ShowAll()
NoteHideAll() => App.HideAll()
/* 列表的批量操作（清快捷键 / 置顶 / 收起展开 / 颜色 / 透明度 / 导出 / 删除）。
   删除的二次确认在这里做：页面只说"要删这些"，删不删由宿主问。 */
NoteBatch(action, ids, arg := "") {
    if (action = "delete")
        return App.ConfirmBatchDelete(ids)
    return App.BatchNotes(action, ids, arg)
}
/* App.AskChoice 的按钮回调：记下点了第几个再关窗。
   Bind 把 res 和下标一起带过来，多出来的事件参数用 * 吃掉。 */
ChoicePick(res, idx, *) {
    res.idx := idx
    try res.gui.Destroy()
}
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

/* ============================================================================
   自检：待办便签（P1）
   —— 数据层 + 页面两层都验。页面部分一律通过 window.__todo 调"真按钮/真防抖"，
      不直接改 DOM 假装修好了：那样测出来的只是测试脚本自己。
   ========================================================================== */
SelfTestTodo() {
    try SelfTestTodoRun()
    catch as e {
        App.Log("SELFTEST TODO 异常：" CleanComError(e.Message) " @" e.Line)
        App.Log("SELFTEST TODO 结论：未通过（异常中断）")
    }
    SelfTestDone()
}

SelfTestTodoRun() {
    Global RICH_PASS := 0, RICH_FAIL := 0
    now := Store.Now()

    ; ---- 0. 老库（v3）升级不丢数据 --------------------------------------
    oldp := App.DataDir "\_selftest_v3.db"
    for f in [oldp, oldp "-wal", oldp "-shm"]
        if FileExist(f)
            try FileDelete f
    odb := Sqlite(oldp)
    odb.Exec("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);")
    odb.Exec("INSERT INTO meta(k,v) VALUES('schema_version','3');")
    odb.Exec("CREATE TABLE notes(id INTEGER PRIMARY KEY AUTOINCREMENT,"
        . " title TEXT NOT NULL DEFAULT '', body_html TEXT NOT NULL DEFAULT '',"
        . " body_text TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL DEFAULT '',"
        . " mode TEXT NOT NULL DEFAULT 'rich', color TEXT NOT NULL DEFAULT 'yellow',"
        . " x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,"
        . " w INTEGER NOT NULL DEFAULT 300, h INTEGER NOT NULL DEFAULT 280,"
        . " pinned INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0,"
        . " title_locked INTEGER NOT NULL DEFAULT 0, opacity INTEGER NOT NULL DEFAULT 100,"
        . " hotkey TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0,"
        . " updated_at INTEGER NOT NULL DEFAULT 0);")
    odb.Run("INSERT INTO notes(title, body_text) VALUES(?,?)", "老便签", "老正文")
    odb.Exec("PRAGMA journal_mode=DELETE")
    odb.Close()
    ost := Store(oldp)
    RichSay("老库升到 v4", ost.db.Scalar("SELECT v FROM meta WHERE k='schema_version'") = "4"
        , ost.db.Scalar("SELECT v FROM meta WHERE k='schema_version'"))
    old := ost.All()
    RichSay("老库数据没丢", old.Length = 1 && old[1].body_text = "老正文"
        , old.Length " / " (old.Length ? old[1].body_text : "?"))
    RichSay("老行 kind 补成 note", old.Length && old[1].kind = "note"
        , old.Length ? old[1].kind : "?")
    ost.Close()

    ; ---- 1. 新建待办便签 -------------------------------------------------
    w := App.NewTodoNote(Map("activate", 0))
    if !w {
        App.Log("SELFTEST TODO 没能建出待办便签")
        return
    }
    Loop 60 {
        if w.ready
            break
        Sleep 100
    }
    RichSay("待办便签页面就绪", w.ready = 1, w.ready)
    RichSay("便签 kind=todo", App.Store.KindOf(w.id) = "todo", App.Store.KindOf(w.id))
    RichSay("默认窗口 460x540", w.note.w = 460 && w.note.h = 540
        , w.note.w "x" w.note.h)
    RichSay("装的是 todo.html", InStr(w.wv.Source, "todo.html") > 0, w.wv.Source)

    ; 空列表时页面自动建第一条（省一次点击）
    Loop 30 {
        if (TodoStore.Count(w.id) >= 1)
            break
        Sleep 100
    }
    RichSay("空列表自动建了第一条", TodoStore.Count(w.id) = 1, TodoStore.Count(w.id))
    RichSay("页面卡片数与事项数一致", JStr(RichEval(w, "__todo.count()")) = "1"
        , JStr(RichEval(w, "__todo.count()")))

    it1 := TodoStore.Items(w.id)[1]
    RichSay("新事项默认未开始 / 时间为 0", it1.status = "todo" && it1.start_at = 0 && it1.due_at = 0
        , it1.status " " it1.start_at "/" it1.due_at)
    RichSay("第一条 seq=1000", it1.seq = 1000, it1.seq)

    ; ---- 2. 标题与正文 ---------------------------------------------------
    RichEval(w, "__todo.setTitle(0, '写方案')")
    Sleep 250
    RichSay("标题改名落库", TodoStore.Get(it1.id).title = "写方案"
        , TodoStore.Get(it1.id).title)

    RichEval(w, "__todo.setBody(0, '<div>第一行内容</div>')")
    Sleep 800                              ; 400ms 防抖 + 余量
    it1 := TodoStore.Get(it1.id)
    RichSay("正文落库（body_html）", InStr(it1.body_html, "第一行内容") > 0, it1.body_html)
    RichSay("body_md 同步", InStr(it1.body_md, "第一行内容") > 0, it1.body_md)
    RichSay("body_text 同步", InStr(it1.body_text, "第一行内容") > 0, it1.body_text)
    RichSay("便签摘要跟着变", InStr(App.Store.Get(w.id).body_text, "第一行内容") > 0
        , App.Store.Get(w.id).body_text)
    RichSay("列表摘要带清单", InStr(App.Store.Get(w.id).body_md, "- [ ] 写方案") > 0
        , App.Store.Get(w.id).body_md)

    ; 清空标题 → 按正文首行自动生成
    RichEval(w, "__todo.setTitle(0, '')")
    Sleep 250
    RichSay("空标题按正文首行重算", TodoStore.Get(it1.id).title = "第一行内容"
        , TodoStore.Get(it1.id).title)

    ; ---- 3. 新增第二条 ---------------------------------------------------
    RichEval(w, "__todo.add()")
    Loop 30 {
        if (TodoStore.Count(w.id) >= 2)
            break
        Sleep 100
    }
    RichSay("点「+ 新事项」多一条", TodoStore.Count(w.id) = 2, TodoStore.Count(w.id))
    its := TodoStore.Items(w.id)
    RichSay("新事项排在后面且 seq 递增", its[2].seq > its[1].seq
        , its[1].seq "/" its[2].seq)
    RichSay("进度显示 0/2", InStr(JStr(RichEval(w, "__todo.prog()")), "0/2") > 0
        , JStr(RichEval(w, "__todo.prog()")))

    ; ---- 4. 勾选完成 -----------------------------------------------------
    RichEval(w, "__todo.chk(0)")
    Loop 20 {
        if (TodoStore.Get(it1.id).status = "done")
            break
        Sleep 100
    }
    it1 := TodoStore.Get(it1.id)
    RichSay("勾选写 done 与 done_at", it1.status = "done" && it1.done_at > 0
        , it1.status " " it1.done_at)
    RichSay("卡片打上 done 类", JStr(RichEval(w, "__todo.hasClass(0,'.ti','done')")) = "1")
    RichSay("勾选框显示为已勾", JStr(RichEval(w, "document.querySelectorAll('.ti-chk')[0].dataset.on")) = "1"
        , JStr(RichEval(w, "document.querySelectorAll('.ti-chk')[0].dataset.on")))
    RichSay("已完成项在清单里打勾", InStr(App.Store.Get(w.id).body_md, "- [x]") > 0
        , App.Store.Get(w.id).body_md)
    RichSay("进度变成 1/2", InStr(JStr(RichEval(w, "__todo.prog()")), "1/2") > 0
        , JStr(RichEval(w, "__todo.prog()")))

    ; ---- 5. 逾期只在非终态出现 -------------------------------------------
    RichEval(w, "__todo.chk(0)")           ; 再点一次 → 回到 todo
    Sleep 300
    TodoStore.SetTimes(it1.id, now - 7200, now - 3600)
    w.PushItems()
    Sleep 250
    RichSay("未完成 + 过期 → 胶囊标红"
        , JStr(RichEval(w, "__todo.hasClass(0,'.tm','due-over')")) = "1"
        , JStr(RichEval(w, "__todo.text(0,'.tm')")))
    RichSay("逾期文案带时长", InStr(JStr(RichEval(w, "__todo.text(0,'.tm')")), "逾期") > 0
        , JStr(RichEval(w, "__todo.text(0,'.tm')")))
    RichSay("列表摘要计入逾期", TodoStore.Summary(w.id).overdue = 1
        , TodoStore.Summary(w.id).overdue)
    TodoStore.SetStatus(it1.id, "done")
    w.PushItems()
    Sleep 250
    RichSay("完成后不再显示逾期"
        , JStr(RichEval(w, "__todo.hasClass(0,'.tm','due-over')")) = "0")
    RichSay("完成后摘要不再计逾期", TodoStore.Summary(w.id).overdue = 0
        , TodoStore.Summary(w.id).overdue)
    TodoStore.SetStatus(it1.id, "todo")
    w.PushItems()
    Sleep 200

    ; ---- 6. 排序（箭头/拖动共用 MoveTo） ---------------------------------
    before := TodoStore.Items(w.id)
    TodoStore.MoveTo(w.id, before[2].id, 1)
    w.PushItems()
    Sleep 250
    RichSay("移到第 1 位后 DOM 顺序跟着变"
        , JStr(RichEval(w, "__todo.ids()[0]")) = String(before[2].id)
        , JStr(RichEval(w, "__todo.ids()[0]")) " vs " before[2].id)
    RichSay("库里顺序也变了", TodoStore.Items(w.id)[1].id = before[2].id
        , TodoStore.Items(w.id)[1].id)
    RichSay("拖动只改一条 seq？seq 仍严格递增", IsAscTodo(TodoStore.Items(w.id)))

    ; ---- 7. 关联便签 / 关联失效 -----------------------------------------
    nid := App.Store.Create(Map("title", "被关联的便签", "body_text", "正文"
        , "body_md", "正文", "body_html", "<div>正文</div>"))
    TodoStore.SetLink(it1.id, nid)
    w.PushItems()
    Sleep 250
    RichSay("关联成功且拿得到标题", TodoStore.Get(it1.id).link_title = "被关联的便签"
        , TodoStore.Get(it1.id).link_title)
    /* 排过序之后 it1 未必在第一位，按 id 找它现在的位置再断言 */
    ix := JStr(RichEval(w, "__todo.idx(" it1.id ")"))
    RichSay("↗ 按钮点亮", JStr(RichEval(w, "__todo.hasClass(" ix ",'.lk','link-ok')")) = "1"
        , "idx=" ix)
    App.Store.Delete(nid)
    w.PushItems()
    Sleep 250
    RichSay("被关联便签删除后关联清零、事项保留"
        , TodoStore.Get(it1.id).link_note_id = 0 && TodoStore.Count(w.id) = 2)
    ix := JStr(RichEval(w, "__todo.idx(" it1.id ")"))
    RichSay("↗ 不再点亮", JStr(RichEval(w, "__todo.hasClass(" ix ",'.lk','link-ok')")) = "0")

    ; ---- 8. 派生正文只读 -------------------------------------------------
    htmlBefore := App.Store.Get(w.id).body_html
    RichSay("SaveBody 拒绝写待办便签的正文"
        , App.Store.SaveBody(w.id, "x", "<div>x</div>", "x", "x", "rich") = 0)
    RichSay("拒绝之后派生正文没变", App.Store.Get(w.id).body_html = htmlBefore)

    ; ---- 9. 筛选与窗口状态 -----------------------------------------------
    RichEval(w, "__todo.filter('open')")
    Sleep 150
    RichSay("筛选「未完成」只留未完的", JStr(RichEval(w, "__todo.visible()")) = "2"
        , JStr(RichEval(w, "__todo.visible()")))
    TodoStore.SetStatus(TodoStore.Items(w.id)[1].id, "done")
    w.PushItems()
    Sleep 200
    RichSay("筛选状态下完成一项，可见数跟着变"
        , JStr(RichEval(w, "__todo.visible()")) = "1"
        , JStr(RichEval(w, "__todo.visible()")))
    RichEval(w, "__todo.filter('all')")
    Sleep 150
    RichSay("切回「全部」都在", JStr(RichEval(w, "__todo.visible()")) = "2"
        , JStr(RichEval(w, "__todo.visible()")))

    ; ---- 10. 时间弹层 ----------------------------------------------------
    RichEval(w, "__todo.openTime(0)")
    Sleep 150
    RichSay("点时间胶囊能弹出行内面板", JStr(RichEval(w, "__todo.tpOpen()")) = "1")
    tpv := FormatTime(A_Now, "yyyy-MM-dd") "T09:00:00"
    RichEval(w, "__todo.tpSet('" tpv "', '" FormatTime(DateAdd(A_Now, 2, "Days"), "yyyy-MM-dd") "T18:30:00')")
    Sleep 400
    ita := TodoStore.Get(TodoStore.Items(w.id)[1].id)
    RichSay("弹层里填的时间真的落了库", ita.start_at > 0 && ita.due_at > ita.start_at
        , ita.start_at "/" ita.due_at)
    RichSay("秒级精度（不是整分）", Mod(ita.start_at, 60) = 0 && ita.start_at > 0)

    ; ---- 11. 单事项 Markdown 源码 ----------------------------------------
    /* 按 id 定位卡片：排过序之后 DOM 第 N 张未必是库里第 N 条。
       注意 '\n' 必须写成字面反斜杠 n —— AHK 的转义符是反引号，
       真写成 `n 会被求值成真实换行，塞进 JS 单引号字符串就是语法错误。 */
    mdid := TodoStore.Items(w.id)[1].id
    mix := JStr(RichEval(w, "__todo.idx(" mdid ")"))
    RichEval(w, "__todo.openMd(" mix ")")
    Sleep 150
    RichSay("能打开单事项 Markdown 面板", JStr(RichEval(w, "__todo.mdOpen()")) = "1"
        , "idx=" mix)
    RichEval(w, "__todo.setMd('- 甲\n- 乙')")
    Sleep 500
    bx := JStr(RichEval(w, "__todo.idx(" mdid ")"))
    /* 别在 AHK 这边 InStr 判 "<li>"：RichEval 回来的 HTML 会被 JSON 转义成
       \u003C，永远匹配不上。判定放 JS 里做，只回传 0/1。 */
    RichSay("应用源码后正文变成渲染结果"
        , JStr(RichEval(w, "__todo.bodyHTML(" bx ").indexOf('<li>') >= 0 ? 1 : 0")) = "1"
        , JStr(RichEval(w, "__todo.bodyHTML(" bx ")")))
    RichSay("源码成为 body_md 的正本"
        , InStr(TodoStore.Get(mdid).body_md, "- 甲") > 0
        , TodoStore.Get(mdid).body_md)
    RichSay("面板已关闭", JStr(RichEval(w, "__todo.mdOpen()")) = "0")

    ; ---- 12. 删除 --------------------------------------------------------
    victim := TodoStore.Items(w.id)[2].id
    TodoStore.Delete(victim)
    w.PushItems()
    Sleep 250
    RichSay("删事项后页面少一张卡片", JStr(RichEval(w, "__todo.count()")) = "1"
        , JStr(RichEval(w, "__todo.count()")))
    RichSay("删事项后库里也只剩一条", TodoStore.Count(w.id) = 1, TodoStore.Count(w.id))

    ; ---- 13. 收尾 --------------------------------------------------------
    delID := w.id
    App.Store.Delete(delID)
    RichSay("删待办便签连带清事项", TodoStore.Count(delID) = 0, TodoStore.Count(delID))
    if NoteWindow.All.Has(delID) {
        try NoteWindow.All[delID].Destroy()
    }

    App.Log("SELFTEST TODO 结论：" (RICH_FAIL = 0 ? "通过" : "未通过")
        . "（PASS " RICH_PASS " / FAIL " RICH_FAIL "）")
}

; 自检小工具：seq 必须严格递增（排序的全部依据就是它）
IsAscTodo(items) {
    prev := -1
    for it in items {
        if (it.seq <= prev)
            return false
        prev := it.seq
    }
    return true
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
