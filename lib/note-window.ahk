#Requires AutoHotkey v2.0
; ============================================================================
;  note-window.ahk —— 一张便签 = 一个 Gui + 一个 WebView2
;
;  生命周期：
;      __New(note)   建窗口 → 先 Show → 再建 controller（顺序不能反，否则白屏）
;      Send(json)    AHK -> 页面
;      OnMessage    页面 -> AHK，按 type 分发
;      Destroy      先 wvc.Close() 再 Destroy()（只 Destroy 会漏渲染进程）
;
;  几条硬经验（都是踩过的）：
;    · 窗口必须先真正显示，再 CreateControllerAsync；在隐藏窗口上创建，页面能加载、
;      CapturePreview 也有内容，但视觉树不会挂到窗口上 —— 屏幕上一个纯白空窗。
;    · DefaultBackgroundColor 的 alpha 只接受 0 或 255；中间值直接 E_INVALIDARG。
;      所以要"半透明"只能 alpha=0 + 页面自己画 rgba 底色，不能设 0x80xxxxxx。
;    · 缩放不交给系统的 WS_THICKFRAME：那会带来 8px 黑边并吃掉客户区。
;      这里用页面右下角手柄 + 15ms 节拍的 SetWindowPos，视觉上干净。
; ============================================================================

class NoteWindow {
    static Store := 0
    static Ctx := 0                     ; { uiDir, dllPath, dataDir, appearance }
    static All := Map()                 ; id -> NoteWindow

    id := 0
    note := 0
    gui := 0
    wvc := 0
    wv := 0
    ready := false
    dragging := false
    resizing := 0
    lastGeo := ""

    __New(note) {
        this.id := note.id
        this.note := note
        ctx := NoteWindow.Ctx
        appr := ctx.appearance

        geo := Win.Clamp(note.x, note.y, note.w, note.h)
        flags := "-Caption +ToolWindow"
        if (appr.transparent)
            flags .= " +E0x00080000 +E0x00200000"     ; LAYERED | NOREDIRECTIONBITMAP
        if (note.pinned)
            flags .= " +AlwaysOnTop"

        g := Gui(flags, "便签 " note.id)
        g.MarginX := 0
        g.MarginY := 0
        g.BackColor := appr.transparent ? "0x000000" : NoteWindow.ColorHex(note.color)
        g.OnEvent("Close", ObjBindMethod(this, "Destroy"))
        this.gui := g

        ; ★ 先显示再建 controller
        g.Show("x" geo.x " y" geo.y " w" geo.w " h" geo.h " NoActivate")
        this.lastGeo := geo.x "," geo.y "," geo.w "," geo.h

        ; ★ 分层窗口必须在窗口存在之后补 alpha=255，否则整窗 alpha=0，
        ;   鼠标消息会直接穿透到下面的窗口（表现：看得见、点不到）。
        ;   详见 lib\win.ahk 的 MakeTransparent 注释。
        if (appr.transparent)
            Win.SetAlpha(g.Hwnd, 255)

        if (!appr.transparent)
            Win.RoundCorners(g.Hwnd, true)

        try {
            this.wvc := WebView2.CreateControllerAsync(g.Hwnd, 0, ctx.dataDir, "", ctx.dllPath).await()
        } catch as e {
            MsgBox("WebView2 初始化失败：`n" CleanComError(e.Message), "便签", "Icon!")
            try g.Destroy()
            return
        }
        this.wv := this.wvc.CoreWebView2

        ; 背景色：透明模式必须 0；不透明模式给便签底色，免得加载瞬间闪白
        try {
            this.wvc.DefaultBackgroundColor := appr.transparent ? 0x00000000
                : 0xFF000000 | NoteWindow.ColorBGR(note.color)
        }
        try {
            this.wv.Settings.IsNonClientRegionSupportEnabled := 1
            this.wv.Settings.AreDefaultContextMenusEnabled := 0
            this.wv.Settings.AreDevToolsEnabled := ctx.devtools ? 1 : 0
            this.wv.Settings.IsStatusBarEnabled := 0
            this.wv.Settings.IsZoomControlEnabled := 0
            /* ★ 这里必须开着浏览器快捷键（默认值 1）。
               曾经为了禁掉 F5/Ctrl+P 把它设成 0，结果连 Ctrl+V 一起废了：
               Chromium 的"粘贴"是浏览器侧的编辑命令，禁掉快捷键之后 renderer
               根本不产生 paste 事件，页面里挂再多监听也收不到 —— 表现就是
               "右键插入图片正常，Ctrl+V 完全没反应"（用户实测）。
               现在改成保留快捷键，再在页面的 keydown 里 preventDefault 掉
               F5 / Ctrl+R / Ctrl+P / Ctrl+F / Ctrl+N / Ctrl+O / Ctrl+J。
               Ctrl+C/V/X/A/Z 一个都不拦。 */
        }
        try {
            this.wvc.ShouldDetectMonitorScaleChanges := 1
        }

        this.wvc.Fill()
        try this.wvc.IsVisible := 1

        this.wv.add_WebMessageReceived(ObjBindMethod(this, "OnMessage"))
        this.wv.add_ProcessFailed(ObjBindMethod(this, "OnProcessFailed"))
        this.wv.add_NavigationStarting(ObjBindMethod(this, "OnNavStarting"))

        this.wv.Navigate(NoteWindow.FileUrl(ctx.uiDir "\note.html") "?id=" note.id)

        NoteWindow.All[note.id] := this
        SetTimer(ObjBindMethod(this, "Refill"), -150)
        SetTimer(ObjBindMethod(this, "Refill"), -600)
    }

    ; ---- 收发 ---------------------------------------------------------------

    Send(json) {
        if (this.ready && this.wv)
            try this.wv.PostWebMessageAsJson(json)
    }

    SendType(type) => this.Send('{"type":' JsonQuote(type) '}')

    ToFront() {
        if !this.gui
            return
        try {
            this.gui.Show("NoActivate")
            WinActivate("ahk_id " this.gui.Hwnd)
        }
    }

    Refill() {
        if !this.wvc
            return
        try {
            this.wvc.Fill()
            this.wvc.IsVisible := 1
        }
    }

    ; 注意挂在 NavigationStarting 而不是 Completed：Completed 可能晚于页面发来的
    ; ready，那样会把刚置上的 ready 又打回 false，之后所有 Send 都被拦住。
    OnNavStarting(sender, args) {
        this.ready := false
    }

    OnProcessFailed(sender, args) {
        ; 渲染进程崩了：页面没了，但数据在库里。把 WebView2 关掉、窗口藏起来，
        ; 提示用户点一下重建（重建整个窗口比只重建 controller 简单可靠）。
        this.ready := false
        try NoteWindow.Store.Touch(this.id)
        try {
            if (this.gui)
                this.gui.Hide()
        }
        App.Toast("一张便签的渲染进程退出了，已收起。点托盘「便签列表」可重新打开。")
    }

    ; ---- 页面消息 -----------------------------------------------------------

    OnMessage(sender, args) {
        raw := ""
        try raw := args.WebMessageAsJson
        if (raw = "")
            return
        type := JsonStr(raw, "type")

        /* 整个分发都包在 try 里：AHK 的未捕获异常会弹模态框，那个框会冻住
           所有便签（单 UI 线程），用户看到的就是"全部卡死"。 */
        try {
            switch type {
                case "ready":
                    this.ready := true
                    this.PushInit()
                case "save":
                    this.DoSave(raw)
                case "pin":
                    this.DoPin(JsonBool(raw, "on"))
                case "color":
                    this.DoColor(JsonStr(raw, "color", "yellow"))
                case "close":
                    ; 关窗要 wvc.Close()，不能在 COM 回调里等
                    SetTimer(ObjBindMethod(this, "CloseSelf"), -10)
                case "hide":
                    this.Hide()
                case "new":
                    ; 建窗要 await WebView2 controller —— 在 COM 回调里 await 会永久挂住
                    NoteDeferNew()
                case "list":
                    NoteDeferList()
                case "drag-start":
                    ; 页面在 manual 模式下把顶栏的 app-region 让出来，改由这里拖
                    this.StartMove()
                case "resize-start":
                    this.StartResize(JsonStr(raw, "edge", "se"))
                case "menu":
                    ; 菜单和确认框都会阻塞线程，所以从消息回调里退出来再弹：
                    ; COM 回调用户不能长时间占着，否则 WebView2 侧会等着卡住
                    SetTimer(ObjBindMethod(this, "ShowMenu"), -10)
                case "font":
                    ; Ctrl+滚轮：页面先自己应用了字号，这里只负责落盘 + 通知其它窗口
                    App.SetFontSize(JsonNum(raw, "size"))
                case "image":
                    ; 拖拽/粘贴进来的图：base64 解码 + 落盘，别占着 COM 回调线程
                    SetTimer(NoteImageTick(this.id, raw), -10)
                case "delete":
                    SetTimer(ObjBindMethod(this, "ConfirmDelete"), -10)
                case "open-external":
                    App.OpenExternal(JsonStr(raw, "url"))
                case "toast":
                    App.Toast(JsonStr(raw, "text"))
            }
        } catch as e {
            App.Log("msg/" type " 出错：" CleanComError(e.Message) " @" e.Line)
        }
    }

    /* 关窗并删库。放在独立线程里跑：Destroy 里要 wvc.Close()，在 COM 回调里等
       COM 对象同样是"等到死"的老坑。 */
    CloseSelf() {
        this.Destroy()
        NoteWindow.Store.Delete(this.id)
        App.RefreshTray()
    }

    PushInit() {
        n := this.note
        appr := NoteWindow.Ctx.appearance
        json := '{"type":"init"'
        json .= ',"note":{'
        json .= '"id":' n.id
        json .= ',"title":' JsonQuote(n.title)
        json .= ',"html":' JsonQuote(n.body_html)
        json .= ',"text":' JsonQuote(n.body_text)
        json .= ',"md":' JsonQuote(n.body_md)
        json .= ',"mode":' JsonQuote(n.mode)
        json .= ',"color":' JsonQuote(n.color)
        json .= ',"pinned":' n.pinned
        json .= '}'
        json .= ',"app":{'
        json .= '"transparent":' (appr.transparent ? "true" : "false")
        json .= ',"fontSize":' appr.fontSize
        json .= ',"drag":"' appr.drag '"'
        json .= '}'
        json .= '}'
        this.Send(json)
    }

    DoSave(raw) {
        title := JsonStr(raw, "title")
        html := JsonStr(raw, "html")
        text := JsonStr(raw, "text")
        md := JsonStr(raw, "md")
        mode := JsonStr(raw, "mode", "rich")
        NoteWindow.Store.SaveBody(this.id, title, html, text, md, mode)
        ; 内存里的副本同步更新，免得关闭时用旧值回写
        this.note.title := title
        this.note.body_html := html
        this.note.body_text := text
        this.note.body_md := md
        this.note.mode := mode
    }

    TogglePin() => this.DoPin(!this.note.pinned)

    DoPin(on) {
        NoteWindow.Store.SetPinned(this.id, on)
        this.ApplyPin(on)
    }

    /* 只改外观不写库：列表窗口改置顶/颜色时走这里，避免同一个值写两遍。
       （DoPin/DoColor 是"本地发起的改动"，自己写库；Apply* 是"外部通知"） */
    ApplyPin(on) {
        this.note.pinned := on ? 1 : 0
        try this.gui.Opt((on ? "+" : "-") "AlwaysOnTop")
        if (on)
            try WinSetAlwaysOnTop(1, "ahk_id " this.gui.Hwnd)
        this.Send('{"type":"pin","on":' (on ? "true" : "false") '}')
    }

    DoColor(color) {
        if !NoteWindow.IsColor(color)
            return
        NoteWindow.Store.SetColor(this.id, color)
        this.ApplyColor(color)
    }

    ApplyColor(color) {
        if !NoteWindow.IsColor(color)
            return
        this.note.color := color
        if !NoteWindow.Ctx.appearance.transparent
            this.gui.BackColor := NoteWindow.ColorHex(color)
        this.Send('{"type":"color","color":' JsonQuote(color) '}')
    }

    ; ---- 显隐 ---------------------------------------------------------------

    Hide() {
        this.SaveGeometryNow()
        try this.gui.Hide()
        NoteWindow.Store.SetHidden(this.id, 1)
        App.RefreshTray()
    }

    Show() {
        if !this.gui
            return
        try {
            this.gui.Show("NoActivate")
            this.wvc.Fill()
            this.wvc.IsVisible := 1
        }
        NoteWindow.Store.SetHidden(this.id, 0)
        App.RefreshTray()
    }

    ; ---- 几何 ---------------------------------------------------------------

    SaveGeometryNow() {
        if !this.gui
            return
        r := Win.Rect(this.gui.Hwnd)
        if (r.w <= 0 || r.h <= 0)
            return
        key := r.x "," r.y "," r.w "," r.h
        if (key = this.lastGeo)
            return
        this.lastGeo := key
        NoteWindow.Store.SetGeometry(this.id, r.x, r.y, r.w, r.h)
    }

    ; 拖动：让系统接管移动循环（页面里标了 -webkit-app-region: drag 的区域）
    StartMove() {
        if !this.gui
            return
        DllCall("ReleaseCapture")
        PostMessage(0x00A1, 2, 0, , "ahk_id " this.gui.Hwnd)   ; WM_NCLBUTTONDOWN / HTCAPTION
    }

    ; 缩放：页面手柄按下后调这里，之后靠 15ms 节拍跟光标
    StartResize(edge) {
        if !this.gui
            return
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        r := Win.Rect(this.gui.Hwnd)
        this.resizing := {
            edge: edge,
            mx: mx, my: my,
            x: r.x, y: r.y, w: r.w, h: r.h
        }
        SetTimer(ObjBindMethod(this, "ResizeTick"), 15)
    }

    ResizeTick() {
        if !this.resizing {
            SetTimer(ObjBindMethod(this, "ResizeTick"), 0)
            return
        }
        ; 物理按键松开就收工，这样鼠标移出窗口也能正确结束
        if !GetKeyState("LButton", "P") {
            this.resizing := 0
            SetTimer(ObjBindMethod(this, "ResizeTick"), 0)
            this.SaveGeometryNow()
            return
        }
        r := this.resizing
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        dx := mx - r.mx
        dy := my - r.my
        x := r.x, y := r.y, w := r.w, h := r.h
        edge := r.edge
        if InStr(edge, "e")
            w := r.w + dx
        if InStr(edge, "s")
            h := r.h + dy
        if InStr(edge, "w") {
            w := r.w - dx
            x := r.x + dx
        }
        if InStr(edge, "n") {
            h := r.h - dy
            y := r.y + dy
        }
        w := Max(w, 180)
        h := Max(h, 140)
        try {
            WinMove(x, y, w, h, "ahk_id " this.gui.Hwnd)
            if this.wvc
                this.wvc.Fill()
            this.lastGeo := x "," y "," w "," h      ; 拖动中先记着，结束时写库
        }
    }

    ; ---- 菜单 ---------------------------------------------------------------

    /* ★ 菜单项回调会被传 3 个参数（项目名、序号、菜单对象），而 AHK 在调用点
       会做严格的参数个数检查：回调声明得比这少就直接抛
           "Too many parameters passed to function."
       表现到界面上就是"菜单弹得出来，但点哪项都没反应"——错误还被记在了
       m.Show() 那一行，看着像是 Show 出问题。所以所有回调统一套 MB 包一层，
       用变参箭头把多出来的参数吃掉。新增菜单项时别忘了。 */
    static MB(fn) {
        return (*) => fn.Call()
    }

    ShowMenu() {
        isMd := (this.note.mode = "md")
        m := Menu()
        m.Add("新建便签", (*) => NoteDeferNew())
        m.Add("便签列表…", (*) => NoteDeferList())
        m.Add("重命名…", NoteWindow.MB(ObjBindMethod(this, "Rename")))
        m.Add()
        m.Add(this.note.pinned ? "取消置顶" : "置顶"
            , NoteWindow.MB(ObjBindMethod(this, "TogglePin")))
        sub := Menu()
        for name, hex in NoteWindow.Colors() {
            sub.Add(NoteWindow.ColorLabel(name)
                , NoteWindow.MB(ObjBindMethod(this, "DoColor", name)))
            if (name = this.note.color)
                sub.Check(NoteWindow.ColorLabel(name))
        }
        m.Add("颜色", sub)
        m.Add()
        m.Add(isMd ? "切换到富文本编辑" : "切换 Markdown 源码"
            , NoteWindow.MB(ObjBindMethod(this, "SendType", "toggle-md")))
        m.Add("复制全文", NoteWindow.MB(ObjBindMethod(this, "CopyAll")))
        m.Add("插入图片…", NoteWindow.MB(ObjBindMethod(this, "PickImage")))
        m.Add()
        /* 字号也有菜单入口：万一没有滚轮（或触控板不好按 Ctrl+滚轮），
           还能调回来。Ctrl+滚轮 和这里走的是同一套 SetFontSize。 */
        fm := Menu()
        fm.Add("放大`tCtrl+滚轮上", (*) => App.ZoomFont(1))
        fm.Add("缩小`tCtrl+滚轮下", (*) => App.ZoomFont(-1))
        fm.Add()
        fm.Add("恢复默认", (*) => App.ZoomFont(0))
        m.Add("字号", fm)

        /* 导出：四种格式各一项。用子菜单而不是弹个"选格式"的对话框 ——
           导出是低频操作，多一层菜单比多一个对话框省事。 */
        em := Menu()
        em.Add("纯文本  (*.txt)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "txt")))
        em.Add("Markdown (*.md)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "md")))
        em.Add("网页  (*.html)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "html")))
        em.Add("RTF 文档 (*.rtf)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "rtf")))
        m.Add("导出", em)

        m.Add()
        m.Add("收起这张", NoteWindow.MB(ObjBindMethod(this, "Hide")))
        m.Add("删除这张…", NoteWindow.MB(ObjBindMethod(this, "ConfirmDelete")))
        m.Show()
    }

    /* 导出统一走 App.ExportNote：它会重新从库里取一次（窗口手里的 this.note
       可能是几分钟前的老快照），也避免这个文件直接依赖 export.ahk ——
       tools 下的探针只 include 本文件，凭空出现的 `Export.` 会被 #Warn 判成
       "未赋值的变量"，然后弹个模态框把自动化测试卡死。 */
    ExportAs(fmt) {
        App.ExportNote(this.id, fmt)
    }

    /* ---- 插入图片 -----------------------------------------------------------
       走系统文件框（宿主弹），而不是页面的 <input type=file>：页面那边是从
       postMessage 里收到指令才想去弹框的，没有用户手势，Chromium 会拦掉。 */
    PickImage() {
        f := FileSelect(3, "", "插入图片", "图片 (*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp)")
        if (f = "")
            return
        this.InsertImageFile(f)
    }

    InsertImageFile(src) {
        try size := FileGetSize(src)
        catch {
            App.Toast("读不到这个文件")
            return
        }
        if (size > NoteWindow.MAX_IMAGE) {
            App.Toast("图片太大了（上限 " Round(NoteWindow.MAX_IMAGE / 1048576) "MB）")
            return
        }
        SplitPath src, , , &ext
        ext := StrLower(ext)
        if !RegExMatch(ext, "^(png|jpg|jpeg|gif|webp|bmp)$") {
            App.Toast("只支持 png / jpg / gif / webp / bmp")
            return
        }
        dst := NoteWindow.NewImagePath(ext)
        if (dst = "") {
            App.Toast("图片目录建不出来")
            return
        }
        try FileCopy src, dst
        catch {
            App.Toast("复制图片失败")
            return
        }
        this.Send('{"type":"image-in","url":' JsonQuote(NoteWindow.FileUrl(dst)) '}')
    }

    ; 重命名交给主程序：列表窗口的菜单调的是同一套逻辑，只写一份
    Rename() {
        App.RenameNote(this.id)
    }

    /* 复制走 AHK 剪贴板而不是页面里的 navigator.clipboard：菜单点击时页面已经
       没有用户手势了，clipboard API 会被拒。n.body_* 是防抖保存后的最新副本。 */
    CopyAll() {
        n := this.note
        text := (n.mode = "md") ? n.body_md : n.body_text
        if (text = "")
            text := (n.body_text != "") ? n.body_text : n.body_md
        A_Clipboard := text
        App.Toast(text = "" ? "这张便签还是空的" : "已复制全文")
    }

    ConfirmDelete() {
        r := MsgBox("删除这张便签？此操作不可撤销。", "便签", "YesNo Icon?")
        if (r = "Yes")
            SetTimer(ObjBindMethod(this, "CloseSelf"), -10)
    }

    ; ---- 销毁 ---------------------------------------------------------------

    Destroy() {
        this.SaveGeometryNow()
        NoteWindow.All.Delete(this.id)
        if this.wvc {
            try this.wvc.Close()          ; 必须先关 controller，否则渲染进程一直占着
            this.wvc := 0
        }
        if this.gui {
            try this.gui.Destroy()
            this.gui := 0
        }
    }

    ; ---- 颜色表 -------------------------------------------------------------

    static Colors() {
        return Map(
            "yellow", "FFF3B0",
            "pink",   "FFD6E0",
            "blue",   "CFE8FF",
            "green",  "D7F5D3",
            "purple", "E6DAFF",
            "gray",   "ECECEC"
        )
    }

    static IsColor(name) => NoteWindow.Colors().Has(name)

    static ColorLabel(name) {
        static labels := Map("yellow", "黄色", "pink", "粉色", "blue", "蓝色"
            , "green", "绿色", "purple", "紫色", "gray", "灰色")
        return labels.Has(name) ? labels[name] : name
    }

    ; "FFF3B0" -> "0xFFF3B0"（AHK 的 BackColor 用 BGR 顺序，但六位十六进制
    ; 字符串在 AHK 里是 RGB 写法，Gui.BackColor 直接吃 "0xFFF3B0"）
    static ColorHex(name) {
        c := NoteWindow.Colors()
        return "0x" (c.Has(name) ? c[name] : "FFF3B0")
    }

    ; WebView2 的 DefaultBackgroundColor 是 0xAARRGGBB，所以要 BGR 重排
    static ColorBGR(name) {
        c := NoteWindow.Colors()
        hex := c.Has(name) ? c[name] : "FFF3B0"
        r := SubStr(hex, 1, 2), g := SubStr(hex, 3, 2), b := SubStr(hex, 5, 2)
        return Integer("0x" b g r)
    }

    static FileUrl(p) {
        return "file:///" StrReplace(StrReplace(p, "\", "/"), " ", "%20")
    }

    /* ---- 图片落盘 -----------------------------------------------------------
       图片不放数据库：一条便签的记录会从几 KB 涨到几 MB，而且 body_html 和
       body_md 各存一份，之后每次自动保存都要重写整个 blob，打字都会卡。
       正文里只留 file:/// 链接。

       代价：数据目录搬家/删了图片，正文里的图就裂了。对"单机便签"这个定位
       是可以接受的取舍（整个库还是一份文件，拷走就能用 —— 除了图片）。 */
    static MAX_IMAGE := 8 * 1024 * 1024

    static ImagesDir() {
        return NoteWindow.Ctx ? NoteWindow.Ctx.imagesDir : ""
    }

    static NewImagePath(ext) {
        dir := NoteWindow.ImagesDir()
        if (dir = "")
            return ""
        if !DirExist(dir) {
            try DirCreate dir
            catch
                return ""
        }
        return dir "\" FormatTime(A_Now, "yyyyMMdd-HHmmss") "-" NoteWindow.RandHex(4) "." ext
    }

    static RandHex(n) {
        s := ""
        Loop n
            s .= Format("{:02x}", Random(0, 255))
        return s
    }

    /* 页面拖拽/粘贴发来的 data:image/png;base64,xxxx —— 解出来写盘，回 URL。
       失败就回 image-fail，页面那边把占位图删掉。 */
    static SaveImage(id, raw) {
        w := NoteWindow.All.Has(id) ? NoteWindow.All[id] : 0
        if !w
            return
        req := JsonNum(raw, "req")
        data := JsonStr(raw, "data")
        path := NoteWindow.WriteDataUrl(data)
        if (path = "") {
            w.Send('{"type":"image-fail","req":' req '}')
            return
        }
        w.Send('{"type":"image-ok","req":' req ',"url":' JsonQuote(NoteWindow.FileUrl(path)) '}')
    }

    static WriteDataUrl(dataUrl) {
        if !RegExMatch(dataUrl, "^data:image/([a-zA-Z0-9.+-]+);base64,(.+)$", &m)
            return ""
        ext := NoteWindow.MimeExt(m[1])
        buf := NoteWindow.B64Decode(m[2])
        if !IsObject(buf)
            return ""
        path := NoteWindow.NewImagePath(ext)
        if (path = "")
            return ""
        try {
            f := FileOpen(path, "w")
            f.RawWrite(buf, buf.Size)
            f.Close()
        } catch {
            return ""
        }
        return path
    }

    static MimeExt(mime) {
        switch StrLower(Trim(mime)) {
            case "png": return "png"
            case "jpeg", "jpg": return "jpg"
            case "gif": return "gif"
            case "webp": return "webp"
            case "bmp": return "bmp"
        }
        return "png"
    }

    /* base64 解码走系统 crypt32，不自己写表：
       CRYPT_STRING_BASE64(1)，第一遍问长度，第二遍真解。 */
    static B64Decode(b64) {
        b64 := RegExReplace(b64, "\s+", "")
        size := 0
        if !DllCall("crypt32\CryptStringToBinaryW", "wstr", b64, "uint", StrLen(b64)
            , "uint", 1, "ptr", 0, "uint*", &size, "ptr", 0, "ptr", 0)
            return 0
        if (size = 0)
            return 0
        buf := Buffer(size, 0)
        if !DllCall("crypt32\CryptStringToBinaryW", "wstr", b64, "uint", StrLen(b64)
            , "uint", 1, "ptr", buf, "uint*", &size, "ptr", 0, "ptr", 0)
            return 0
        return buf
    }
}

; ---- 延迟建窗（COM 回调里不能 await，必须换到 SetTimer 的独立线程） -----------
/* ★ 绝对不要用 Func("名字")。那是 AHK v1 的写法，v2 里 Func 是内置类，
   Func("NoteNew") 会走类构造并返回一个残缺对象，SetTimer 再调它的 .Call()
   就抛 "Object.Call / Invalid base."。更阴的是 NoteOnError 把它记进日志就完事
   （不弹框），界面表现是"点菜单毫无反应"。实测过：Func() 直接抛 Invalid base，
   而裸函数名的 Type 就是 Func。
   这里调的是 App 的静态方法：probe 脚本单独 include 本文件时也会有一个同名的
   App 桩类，所以两边都能跑。 */
NoteDeferNew() {
    SetTimer(() => App.NewNote(), -10)
}

NoteDeferList() {
    SetTimer(() => App.ShowList(), -10)
}

; 图片消息：闭包捕获 id/raw，跑在 SetTimer 的独立线程里
NoteImageTick(id, raw) {
    return () => NoteWindow.SaveImage(id, raw)
}
