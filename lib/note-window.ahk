#Requires AutoHotkey v2.0
; 本文件用了 clip.ahk 的 Clip.SetText / Clip.SetImageFile。依赖写在这里、
; 而不是指望调用方记得带上：漏了的话 AHK 会在加载阶段弹"变量用不到"的模态框，
; 无人值守跑测试时就永久卡住（probe-list 就踩过）。#Include 是 include-once，
; 调用方重复 include 不会出问题。
#Include clip.ahk
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
    /* 双击标题栏放大。maximized 只是"当前是不是铺满状态"，restGeo 记着放大前
       的几何 —— 两者都只在内存里，不进数据库：重启后回到原来的大小，
       否则下次开机会一张满屏便签糊在桌面上。 */
    maximized := false
    restGeo := ""
    /* 右键菜单的三套。zone 由页面按落点决定：正文文字弹"编辑菜单"，
       图片弹"图片菜单"，其它地方弹"便签菜单"。inpre/lang 只在正文落在
       代码块里时才有值，src 只在 zone=image 时才有值。 */
    menuZone := "note"
    menuInPre := 0
    menuLang := ""
    /* 图片菜单要操作的那张图（页面给的是 img 的原始 src，file:/// 或 data: ）。
       右键大图预览和右键正文里的缩略图都会填它。 */
    menuImage := ""
    /* 这张窗口到底是不是分层窗口（WS_EX_LAYERED）。opacity < 100 时必须分层，
       否则页面透明度没地方透 —— 普通窗口底下是窗口底色，透出来是那块颜色，
       不是桌面。见 App.SetNoteOpacity 里的重建分支。 */
    layered := false

    __New(note) {
        this.id := note.id
        this.note := note
        ctx := NoteWindow.Ctx
        appr := ctx.appearance

        geo := Win.Clamp(note.x, note.y, note.w, note.h)
        /* 透明外观 or 这张便签设了半透明 → 走分层窗口：窗口背景 alpha=0，
           画面完全由页面画（卡片自带 rgba 圆角）。两者只能建窗时决定。 */
        this.layered := (appr.transparent || (note.opacity < 100)) ? true : false
        flags := "-Caption +ToolWindow"
        if this.layered
            flags .= " +E0x00080000 +E0x00200000"     ; LAYERED | NOREDIRECTIONBITMAP
        if (note.pinned)
            flags .= " +AlwaysOnTop"

        g := Gui(flags, "便签 " note.id)
        g.MarginX := 0
        g.MarginY := 0
        g.BackColor := this.layered ? "0x000000" : NoteWindow.ColorHex(note.color)
        g.OnEvent("Close", ObjBindMethod(this, "Destroy"))
        this.gui := g

        ; ★ 先显示再建 controller
        g.Show("x" geo.x " y" geo.y " w" geo.w " h" geo.h " NoActivate")
        this.lastGeo := geo.x "," geo.y "," geo.w "," geo.h

        ; ★ 分层窗口必须在窗口存在之后补 alpha=255，否则整窗 alpha=0，
        ;   鼠标消息会直接穿透到下面的窗口（表现：看得见、点不到）。
        ;   详见 lib\win.ahk 的 MakeTransparent 注释。
        if this.layered
            Win.SetAlpha(g.Hwnd, 255)

        if !this.layered
            Win.RoundCorners(g.Hwnd, true)

        try {
            this.wvc := WebView2.CreateControllerAsync(g.Hwnd, 0, ctx.dataDir, "", ctx.dllPath).await()
        } catch as e {
            MsgBox("WebView2 初始化失败：`n" CleanComError(e.Message), "便签", "Icon!")
            try g.Destroy()
            return
        }
        this.wv := this.wvc.CoreWebView2

        ; 背景色：分层窗口必须给全透明（0）；普通窗口给便签底色，免得加载瞬间闪白
        try {
            this.wvc.DefaultBackgroundColor := this.layered ? 0x00000000
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
                case "toggle-max":
                    ; 双击标题栏（或菜单「最大化窗口」）：铺满 / 还原
                    SetTimer(ObjBindMethod(this, "ToggleMax"), -10)
                case "resize-start":
                    this.StartResize(JsonStr(raw, "edge", "se"))
                case "menu":
                    ; 菜单和确认框都会阻塞线程，所以从消息回调里退出来再弹：
                    ; COM 回调用户不能长时间占着，否则 WebView2 侧会等着卡住
                    this.menuZone := JsonStr(raw, "zone", "note")
                    this.menuInPre := JsonNum(raw, "inpre")
                    this.menuLang := JsonStr(raw, "lang")
                    if (this.menuZone = "image")
                        this.menuImage := JsonStr(raw, "src")
                    SetTimer(ObjBindMethod(this, "ShowMenu"), -10)
                case "copy-image":
                    ; 大图预览里按 Ctrl+C：和菜单「复制图片」同一条路
                    this.menuImage := JsonStr(raw, "src")
                    SetTimer(ObjBindMethod(this, "CopyImage"), -10)
                case "font":
                    ; Ctrl+滚轮：页面先自己应用了字号，这里只负责落盘 + 通知其它窗口
                    App.SetFontSize(JsonNum(raw, "size"))
                case "image":
                    ; 拖拽/粘贴进来的图：base64 解码 + 落盘，别占着 COM 回调线程
                    SetTimer(NoteImageTick(this.id, raw), -10)
                case "clipboard-set":
                    ; 编辑菜单的"复制/剪切"、代码块右上角的"复制"：页面把文字发过来，
                    ; 由这里写剪贴板。页面自己调 navigator.clipboard 会被拒 —— 点原生
                    ; 菜单的那一刻页面已经没有用户手势了。
                    ; 走 Clip.SetText 而不是直接赋值：它会把 LF 换成 CRLF，
                    ; 否则记事本这类只认 CRLF 的程序会把多行代码挤成一行。
                    Clip.SetText(JsonStr(raw, "text"))
                case "paste-key":
                    ; 编辑菜单的"粘贴"：读剪贴板必须靠真实按键，只能代按一次 Ctrl+V
                    SetTimer(ObjBindMethod(this, "PasteKey"), -10)
                case "pick-image-req":
                    ; 编辑菜单的"插入图片…"：FileSelect 会阻塞，得挪出回调
                    SetTimer(ObjBindMethod(this, "PickImage"), -10)
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
        App.RebindNoteHotkeys()     ; 删掉的便签不能留下一个按了没反应的键
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
        json .= ',"opacity":' n.opacity
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
        /* 回执。Ctrl+S 那一条页面要弹"✓ 已保存 hh:mm:ss"，所以得把 manual 带回去 ——
           用户按了保存键却看不到任何反馈，就会怀疑自己是不是没保存上。 */
        this.Send('{"type":"saved","manual":' (JsonNum(raw, "manual") ? 1 : 0) '}')
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
        ; 分层窗口的窗口底色必须是黑的（alpha=0 才有透明），改它等于给卡片
        ; 垫一层实色 —— 半透明的便签会立刻变成不透明。只有普通窗口才跟着换底色。
        if !this.layered
            this.gui.BackColor := NoteWindow.ColorHex(color)
        this.Send('{"type":"color","color":' JsonQuote(color) '}')
    }

    /* 只改外观不写库（写库在 App.SetNoteOpacity 里，它还要负责"要不要重建"）。
       透明度是靠页面整体 opacity 做的：窗口是分层窗口，页面淡下去就透出桌面。
       注意别用 SetLayeredWindowAttributes 的 alpha —— 那个只影响命中测试，
       画面在 WebView2 自己的合成树里，改它没有视觉效果（lib\win.ahk 有记录）。 */
    ApplyOpacity(pct) {
        pct := Max(30, Min(100, Integer(pct)))
        this.note.opacity := pct
        this.Send('{"type":"opacity","pct":' pct '}')
    }

    ; 菜单入口。写库 + 该重建就重建，统一交给 App 收口，别在这里各写一份
    SetOpacity(pct) => App.SetNoteOpacity(this.id, pct)

    ; 菜单入口：弹输入框改全局快捷键（空 = 取消）。校验/落库/重绑都在 App 里
    AskHotkey() {
        App.AskNoteHotkey(this.id)
    }

    /* 透明度档位。30% 是下限：再低就只剩一层影子，误点了都找不回来
       （列表右键的"重置透明度"就是给这个兜底的）。 */
    static OpacityLevels() {
        return [100, 90, 80, 70, 60, 50, 40, 30]
    }

    /* 把 ^!1 说成人话 Ctrl+Alt+1。放在这里而不是 App 里：列表窗口和便签窗口
       都要用，而 probe-list 这类测试只加载窗口层、不带 App。 */
    static HotkeyPretty(k) {
        k := Trim(k)
        out := ""
        while (StrLen(k) > 0 && InStr("#!^+", SubStr(k, 1, 1))) {
            ch := SubStr(k, 1, 1)
            out .= (ch = "#") ? "Win+" : (ch = "!") ? "Alt+" : (ch = "^") ? "Ctrl+" : "Shift+"
            k := SubStr(k, 2)
        }
        return out . k
    }

    ; ---- 显隐 ---------------------------------------------------------------

    Hide() {
        /* 收起的要是原尺寸的那一张：下次从列表里点开，跳出来一张满屏便签
           既吓人又挡事。 */
        if this.maximized
            this.SetMax(0)
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
        /* 最大化时不写库：存下去的会是"满屏那一份"，下次开机所有便签都顶满屏。
           restGeo 才是用户真正的窗口大小。 */
        if this.maximized
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
        if this.maximized          ; 满屏状态下拖顶栏没有意义，别把整屏窗口挪走
            return
        DllCall("ReleaseCapture")
        PostMessage(0x00A1, 2, 0, , "ahk_id " this.gui.Hwnd)   ; WM_NCLBUTTONDOWN / HTCAPTION
    }

    /* ---- 最大化 / 还原 -----------------------------------------------------
       双击标题栏（或菜单里的那一项）切一下。这里用的是"铺满当前显示器的
       工作区"而不是真正的 WS_MAXIMIZE 状态：
         · 这窗口是 -Caption 的无边框窗口，系统最大化会按旧的边框算法吃点客户区，
           在 125%/150% 缩放下还会露出边；
         · 真 WS_MAXIMIZE 会让页面收到 resize、圆角/半透明也跟着走样。
       直接 WinMove 到工作区（已扣掉任务栏，不会盖住开始按钮），
       视觉上和最大化一样，还原时把原几何搬回去就完事。 */
    ToggleMax() {
        this.SetMax(!this.maximized)
    }

    SetMax(on) {
        if !this.gui
            return
        on := on ? 1 : 0
        if (on = this.maximized)
            return
        if (on) {
            r := Win.Rect(this.gui.Hwnd)
            wa := Win.WorkAreaOf(this.gui.Hwnd)
            this.restGeo := { x: r.x, y: r.y, w: r.w, h: r.h }
            /* ★ 先立旗子再动窗口：GeoTick 每 800ms 巡检一次"窗口动过没有"，
               而 AHK 的定时器随时能打断当前线程。旗子立晚了，巡检就会趁
               WinMove 还没返回把"满屏"那一份写进库 —— 表现是下次开机动不动
               就一张满屏便签（自检里真踩到了：300x280 -> 1920x1040）。 */
            this.maximized := 1
            try WinMove(wa.l, wa.t, wa.w, wa.h, "ahk_id " this.gui.Hwnd)
        } else {
            g := IsObject(this.restGeo) ? this.restGeo : Win.Clamp(0, 0, 520, 420)
            try WinMove(g.x, g.y, g.w, g.h, "ahk_id " this.gui.Hwnd)
            ; 还原要在搬完窗口之后再落旗，搬的过程中巡检才会继续躲开
            this.maximized := 0
            this.restGeo := ""
        }
        try this.wvc.Fill()
        /* 满屏还留着圆角的话，四个角会漏出底色，看着像"没铺满" */
        if !NoteWindow.Ctx.appearance.transparent
            try Win.RoundCorners(this.gui.Hwnd, !on)
        ; 页面要知道状态：最大化时它不再发 drag-start / resize-start，
        ; 手柄也会淡出去（CSS 里 body[data-max]）
        this.Send('{"type":"max","on":' (on ? "true" : "false") '}')
        if !on {
            ; 还原后把几何写回：万一用户最大化之前挪过窗口，这一笔才是最新的
            this.lastGeo := ""
            this.SaveGeometryNow()
        }
    }

    ; 缩放：页面手柄按下后调这里，之后靠 15ms 节拍跟光标
    StartResize(edge) {
        if !this.gui
            return
        if this.maximized          ; 满屏时拉手柄只会把状态搞乱
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
        /* 三套菜单。页面按落点给 zone：
             标题栏 / 工具栏 / 底栏 → note  这张便签怎么处理
             正文编辑区            → edit  这段文字怎么编辑
             图片（大图预览 / 正文里的图）→ image  这张图怎么处理
           在正文里右键却弹出"删除这张便签"是最容易误点的组合，所以必须分开。 */
        if (this.menuZone = "image") {
            this.ShowImageMenu()
            return
        }
        if (this.menuZone = "edit") {
            this.ShowEditMenu()
            return
        }
        isMd := (this.note.mode = "md")
        m := Menu()
        m.Add("新建便签", (*) => NoteDeferNew())
        m.Add("便签列表…", (*) => NoteDeferList())
        m.Add("重命名…", NoteWindow.MB(ObjBindMethod(this, "Rename")))
        m.Add(this.note.hotkey ? "快捷键…（" NoteWindow.HotkeyPretty(this.note.hotkey) "）"
            : "设置快捷键…", NoteWindow.MB(ObjBindMethod(this, "AskHotkey")))
        m.Add()
        /* 大段文字/图片的集中输入：先摊开整块屏，省得一边写一边拖窗口。
           双击标题栏是同一个动作，菜单里也留一份（不用记双击这件事）。 */
        m.Add(this.maximized ? "还原窗口大小`t双击标题栏" : "最大化窗口`t双击标题栏"
            , NoteWindow.MB(ObjBindMethod(this, "ToggleMax")))
        m.Add(this.note.pinned ? "取消置顶" : "置顶"
            , NoteWindow.MB(ObjBindMethod(this, "TogglePin")))
        sub := Menu()
        ; 按 ColorKeys() 的顺序排（Map 遍历顺序是哈希序，会每次开机换位置）
        for name in NoteWindow.ColorKeys() {
            if !NoteWindow.IsColor(name)
                continue
            sub.Add(NoteWindow.ColorLabel(name)
                , NoteWindow.MB(ObjBindMethod(this, "DoColor", name)))
            if (name = this.note.color)
                sub.Check(NoteWindow.ColorLabel(name))
        }
        m.Add("颜色", sub)

        /* 透明度：给档位而不是滑杆。档位够用，也不用为"拖滑杆时每一格都要
           重建窗口"再想一套节流；而且 <100 在非透明外观下要换成分层窗口，
           那是一次重建（见 App.SetNoteOpacity）。 */
        am := Menu()
        for pct in NoteWindow.OpacityLevels() {
            label := (pct = 100) ? "100%（不透明）" : pct "%"
            am.Add(label, NoteWindow.MB(ObjBindMethod(this, "SetOpacity", pct)))
            if (pct = this.note.opacity)
                am.Check(label)
        }
        m.Add("透明度", am)
        m.Add()
        m.Add(isMd ? "切换到富文本编辑" : "切换 Markdown 源码"
            , NoteWindow.MB(ObjBindMethod(this, "SendType", "toggle-md")))
        m.Add("复制全文", NoteWindow.MB(ObjBindMethod(this, "CopyAll")))
        m.Add("保存`tCtrl+S", NoteWindow.MB(ObjBindMethod(this, "Cmd", "save")))
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

        /* 导出：四种纯文本/标记格式各一项，再加 PDF / Word 两种"排好版的文档"。
           PDF 走 WebView2 自带的打印引擎，Word 交给本机的 Office —— 两者都比
           前四种慢（建窗口 / 起 Word），所以摆在分隔线下面，别让人误以为是瞬时操作。 */
        em := Menu()
        em.Add("纯文本  (*.txt)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "txt")))
        em.Add("Markdown (*.md)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "md")))
        em.Add("网页  (*.html)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "html")))
        em.Add("RTF 文档 (*.rtf)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "rtf")))
        em.Add()
        em.Add("PDF 文档 (*.pdf)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "pdf")))
        em.Add("Word 文档 (*.docx)", NoteWindow.MB(ObjBindMethod(this, "ExportAs", "docx")))
        m.Add("导出", em)
        /* 导入只收 TXT / Markdown：docx、pdf 要解析器，不属于"便签"的范畴。
           有这个入口之后，"把一段笔记从别处搬进来"就不用再复制粘贴了。 */
        m.Add("导入文件…（TXT / Markdown）", NoteWindow.MB(ObjBindMethod(this, "Import")))

        m.Add()
        m.Add("收起这张", NoteWindow.MB(ObjBindMethod(this, "Hide")))
        m.Add("删除这张…", NoteWindow.MB(ObjBindMethod(this, "ConfirmDelete")))
        m.Show()
    }

    /* 正文里的右键菜单：全是"编辑这段文字"的动作。
       每一项都只是 postMessage 一条 cmd 回页面去执行 —— 菜单是原生菜单，
       点下去的瞬间页面已经没有用户手势了，直接调 Clipboard API 会被拒。 */
    ShowEditMenu() {
        m := Menu()
        m.Add("撤销`tCtrl+Z", NoteWindow.MB(ObjBindMethod(this, "Cmd", "undo")))
        m.Add("重做`tCtrl+Y", NoteWindow.MB(ObjBindMethod(this, "Cmd", "redo")))
        m.Add()
        m.Add("剪切`tCtrl+X", NoteWindow.MB(ObjBindMethod(this, "Cmd", "cut")))
        m.Add("复制`tCtrl+C", NoteWindow.MB(ObjBindMethod(this, "Cmd", "copy")))
        m.Add("粘贴`tCtrl+V", NoteWindow.MB(ObjBindMethod(this, "Cmd", "paste")))
        m.Add("删除", NoteWindow.MB(ObjBindMethod(this, "Cmd", "delete")))
        m.Add()
        m.Add("全选`tCtrl+A", NoteWindow.MB(ObjBindMethod(this, "Cmd", "select-all")))
        m.Add("清除格式", NoteWindow.MB(ObjBindMethod(this, "Cmd", "clear-format")))
        m.Add()
        /* 只有光标确实在代码块里才露出这三项：平时不占地方，要用的时候就在手边。
           「复制这段代码」是右上角那个悬浮按钮的备胎 —— 鼠标没停在块上、或者
           块很长按钮被滚走了的时候，右键也得能整段复制。两条入口同一个 cmd。 */
        if (this.menuInPre) {
            m.Add("复制这段代码", NoteWindow.MB(ObjBindMethod(this, "Cmd", "copy-code")))
            sub := Menu()
            for lang, label in NoteWindow.CodeLangs() {
                sub.Add(label, NoteWindow.MB(ObjBindMethod(this, "Cmd", "codelang", lang)))
                if (lang = this.menuLang)
                    sub.Check(label)
            }
            m.Add("代码语言", sub)
        }
        m.Add("插入代码块", NoteWindow.MB(ObjBindMethod(this, "Cmd", "codeblock")))
        m.Add("插入图片…", NoteWindow.MB(ObjBindMethod(this, "PickImage")))
        m.Add()
        m.Add("保存`tCtrl+S", NoteWindow.MB(ObjBindMethod(this, "Cmd", "save")))
        m.Show()
    }

    /* ---- 图片菜单 ---------------------------------------------------------
       两个入口共用一套：点开大图预览后右键，或直接对着正文里的缩略图右键。
       （后者顺带补上了"图片选中不了、删不掉"这个老毛病 —— 点图片会打开预览，
       在正文里根本抓不到它。）

       ★ 剪贴板只能由宿主写：原生菜单一点，页面就没有用户手势了，
         navigator.clipboard 会被 Chromium 拒掉。见 lib\clip.ahk。 */
    ShowImageMenu() {
        path := NoteWindow.ImageLocalPath(this.menuImage)
        has := (path != "" && FileExist(path))
        /* ★ Disable 要传 Add 时的**完整名字**，带 `t 和加速键文本。
           只写显示名（"复制图片"）会抛 Nonexistent menu item. ——
           被 try 吞掉之后就是"该灰的没灰"，点了才提示找不到。实测过。 */
        copyItem := "复制图片`tCtrl+C"
        m := Menu()
        m.Add(copyItem, NoteWindow.MB(ObjBindMethod(this, "CopyImage")))
        m.Add("另存为…", NoteWindow.MB(ObjBindMethod(this, "SaveImageAs")))
        m.Add()
        m.Add("复制文件路径", NoteWindow.MB(ObjBindMethod(this, "CopyImagePath")))
        m.Add("在文件夹中显示", NoteWindow.MB(ObjBindMethod(this, "RevealImage")))
        m.Add()
        m.Add("从正文中删除这张图", NoteWindow.MB(ObjBindMethod(this, "DeleteImage")))
        /* 文件真找不到了（数据目录被搬走、图片被手删）就把前四项灰掉：
           点下去只弹一句"找不到"比直接看见是灰的还让人困惑。 */
        if !has {
            try {
                m.Disable(copyItem)
                m.Disable("另存为…")
                m.Disable("复制文件路径")
                m.Disable("在文件夹中显示")
            }
        }
        m.Show()
    }

    CopyImage() {
        path := NoteWindow.ImageLocalPath(this.menuImage)
        if (path = "" || !FileExist(path)) {
            this.Hint("这张图的文件找不到了")
            return
        }
        if Clip.SetImageFile(path) {
            this.Hint("图片已复制，去别的软件里 Ctrl+V 试试")
        } else {
            SplitPath path, , , &ext
            this.Hint("这个格式复制不了（." ext "），用「另存为」吧")
        }
    }

    /* 另存为：系统保存框 + 文件复制。不做格式转换 —— 原样拷一份，
       保真且不依赖任何解码器（webp 也照样能存）。 */
    SaveImageAs() {
        path := NoteWindow.ImageLocalPath(this.menuImage)
        if (path = "" || !FileExist(path)) {
            this.Hint("这张图的文件找不到了")
            return
        }
        SplitPath path, &name, , &ext
        f := FileSelect("S", A_Desktop "\" name "." ext, "图片另存为"
            , "图片 (*." ext ";*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp)")
        if (f = "")
            return
        dst := NoteWindow.CopyImageFile(path, f)
        if (dst = "") {
            this.Hint("保存失败（那个位置可能不可写）")
            return
        }
        SplitPath dst, &saved
        this.Hint("已另存为 " saved)
    }

    CopyImagePath() {
        path := NoteWindow.ImageLocalPath(this.menuImage)
        if (path = "" || !FileExist(path)) {
            this.Hint("这张图的文件找不到了")
            return
        }
        A_Clipboard := path
        this.Hint("路径已复制")
    }

    RevealImage() {
        path := NoteWindow.ImageLocalPath(this.menuImage)
        if (path = "" || !FileExist(path)) {
            this.Hint("这张图的文件找不到了")
            return
        }
        try Run('explorer.exe /select,"' path '"')
    }

    /* 删除交给页面：只有它手里有 DOM 元素，而且能用 execCommand('delete') 删，
       这样 Ctrl+Z 还撤得回来。图片文件本身不删 —— 同一条便签里可能引用了两次，
       别的便签也可能粘过同一个链接。 */
    DeleteImage() {
        this.Cmd("delete-image")
    }

    /* 在状态栏显示一句话（页面的 hint）。比 TrayTip 好：气泡会被置顶窗口盖住，
       而且用户正在盯着这张便签，反馈就该出现在便签里。 */
    Hint(text, ok := true) {
        this.Send('{"type":"hint","text":' JsonQuote(text) ',"ok":' (ok ? 1 : 0) '}')
    }

    /* 给页面下发一条编辑命令。看名字就知道干什么，页面那边 runCmd 一一对应。 */
    Cmd(name, arg := "") {
        json := '{"type":"cmd","name":' JsonQuote(name)
        if (arg != "")
            json .= ',"lang":' JsonQuote(arg)
        json .= '}'
        this.Send(json)
    }

    /* 代按一次 Ctrl+V。粘贴这条路绕不开：页面里的 document.execCommand('paste')
       在 Chromium 里一律返回 false（只给扩展放行），而 navigator.clipboard.read()
       要求用户手势 —— 点原生菜单的那一下不算。所以只能让宿主补一个真实按键。
       调用点已经把它挪到 SetTimer 的独立线程，菜单这时也关掉了。 */
    PasteKey() {
        if !this.gui
            return
        try {
            WinActivate("ahk_id " this.gui.Hwnd)
            Sleep 70
            Send("^v")
        } catch as e {
            App.Log("代按粘贴失败：" CleanComError(e.Message))
            App.Toast("粘贴失败，试试直接按 Ctrl+V")
        }
    }

    /* 代码块可选的语言。必须和 ui\code-hl.js 里的 LANGS 保持一致 ——
       那张表负责真干活（调 highlight.js），这张表只负责画菜单。 */
    static CodeLangs() {
        return Map(
            "", "自动识别",
            "text", "纯文本",
            "javascript", "JavaScript",
            "typescript", "TypeScript",
            "python", "Python",
            "xml", "HTML / XML",
            "css", "CSS",
            "json", "JSON",
            "bash", "Bash / Shell",
            "sql", "SQL",
            "c", "C",
            "cpp", "C++",
            "csharp", "C#",
            "java", "Java",
            "go", "Go",
            "rust", "Rust",
            "yaml", "YAML",
            "markdown", "Markdown",
            "diff", "Diff",
            "lua", "Lua",
            "php", "PHP",
            "ruby", "Ruby",
            "swift", "Swift",
            "kotlin", "Kotlin"
        )
    }

    /* 导出统一走 App.ExportNote：它会重新从库里取一次（窗口手里的 this.note
       可能是几分钟前的老快照），也避免这个文件直接依赖 export.ahk ——
       tools 下的探针只 include 本文件，凭空出现的 `Export.` 会被 #Warn 判成
       "未赋值的变量"，然后弹个模态框把自动化测试卡死。 */
    ExportAs(fmt) {
        App.ExportNote(this.id, fmt)
    }

    /* 导入：选文件、问"覆盖还是追加"都在主程序那边（App.ImportNote），
       这里只管转发 —— 它要弹两个对话框，不能在菜单回调里就地做。 */
    Import() {
        App.ImportNote(this.id)
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

    /* 显示顺序单独列一份。AHK v2 的 Map 是哈希表，遍历顺序**不是**插入顺序
       （实测 Map("yellow",..., "pink",...) 第一个出来的是 blue），
       菜单和设置面板要是照着遍历，六个颜色每次开机都换位置。
       新增颜色时两边都要加，probe-menu 会盯着这张表和 Colors() 是否对得上。 */
    static ColorKeys() {
        return ["yellow", "pink", "blue", "green", "purple", "gray"]
    }

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

    /* 把页面给的 src 还原成本地文件路径。三种情况：
         file:///…   —— 就是 data\images 下的图，换回反斜杠、把 %20 解回空格
         data:…      —— 早期或外部塞进来的内嵌图，解出来落到 images 目录
         http(s) 等  —— 网络图片，便签不缓存，返回空（调用方提示"找不到"） */
    static ImageLocalPath(src) {
        src := Trim(src)
        if (src = "")
            return ""
        if (SubStr(src, 1, 5) = "data:")
            return NoteWindow.WriteDataUrl(src)
        return NoteWindow.UrlToPath(src)
    }

    /* file:/// URL -> 本地路径。
       ★ 别用 shlwapi 的 PathCreateFromUrlW：它对 %E5%9B%BE 这种 UTF-8 序列
       按**单字节**摊开，结果是 "å¾"（probe-menu 实测抓到），中文文件名当场
       变乱码。这里自己解：%XX 收成字节、普通字符按 UTF-8 写进去，最后整体
       按 UTF-8 读出来 —— 中文、%20 都对得上。 */
    static UrlToPath(url) {
        if (SubStr(url, 1, 8) != "file:///")
            return ""
        ; 先换分隔符再解码：%2F 那种编码过的斜杠保持原样（Windows 也认）
        return NoteWindow.UrlDecode(StrReplace(SubStr(url, 9), "/", "\"))
    }

    /* 只解 %XX。绝大多数路径里没有 %，那就不进循环（省得逐字符处理一遍）。 */
    static UrlDecode(s) {
        if !InStr(s, "%")
            return s
        n := StrLen(s)
        buf := Buffer(n * 4 + 8, 0)
        k := 0
        i := 1
        while (i <= n) {
            ch := SubStr(s, i, 1)
            if (ch = "%" && i + 2 <= n) {
                hex := SubStr(s, i + 1, 2)
                if RegExMatch(hex, "^[0-9A-Fa-f]{2}$") {
                    NumPut("uchar", Integer("0x" hex), buf, k)
                    k += 1
                    i += 3
                    continue
                }
            }
            one := Buffer(4, 0)
            len := StrPut(ch, one, "UTF-8") - 1     ; 返回值含结尾 0
            if (len > 0 && (k + len) < (n * 4 + 8)) {
                DllCall("RtlMoveMemory", "ptr", buf.Ptr + k, "ptr", one, "uptr", len)
                k += len
            }
            i += 1
        }
        if (k = 0)
            return ""
        return StrGet(buf, "UTF-8")
    }

    /* 另存为的真正动作（拆出来是为了能被自检直接调，不必弹模态对话框）。
       用户没写扩展名就按源文件的补上；返回最终路径，失败返回空串。 */
    static CopyImageFile(src, dst) {
        if (dst = "" || !FileExist(src))
            return ""
        SplitPath dst, , , &dext
        if (dext = "") {
            SplitPath src, , , &sext
            if (sext != "")
                dst .= "." sext
        }
        try FileCopy src, dst, 1
        catch
            return ""
        return FileExist(dst) ? dst : ""
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
       失败就回 image-fail，页面那边把占位图删掉。

       ★ 整段必须包 try：这里跑在 SetTimer 的独立线程里，未捕获异常会弹一个
       模态框把**所有便签**冻住（单 UI 线程），而且页面永远收不到回执，正文里
       留一个虚线空图框。曾经因为 JsonStr 的正则在大字段上抛 PCRE 异常，用户
       看到的正是这个现象。 */
    static SaveImage(id, raw) {
        w := NoteWindow.All.Has(id) ? NoteWindow.All[id] : 0
        if !w
            return
        req := 0
        try {
            req := JsonNum(raw, "req")
            data := JsonStr(raw, "data")
            path := NoteWindow.WriteDataUrl(data)
            if (path = "") {
                App.Log("存图失败：data URL 解不出来（长度 " StrLen(data) "）")
                w.Send('{"type":"image-fail","req":' req '}')
                return
            }
            w.Send('{"type":"image-ok","req":' req ',"url":' JsonQuote(NoteWindow.FileUrl(path)) '}')
        } catch as e {
            App.Log("存图出错：" CleanComError(e.Message) " @" e.Line)
            try w.Send('{"type":"image-fail","req":' req '}')
        }
    }

    /* ★ 这里也不能用正则：base64 动辄几 MB，`^data:image/([\w.+-]+);base64,(.+)$`
       在长输入上同样会撞 PCRE 的 match limit。改成 InStr 切一刀。 */
    static WriteDataUrl(dataUrl) {
        head := "data:image/"
        if (SubStr(dataUrl, 1, StrLen(head)) != head)
            return ""
        sep := InStr(dataUrl, ";base64,")
        if (sep <= 0)
            return ""
        mime := SubStr(dataUrl, StrLen(head) + 1, sep - StrLen(head) - 1)
        b64 := SubStr(dataUrl, sep + 8)
        if (b64 = "")
            return ""
        buf := NoteWindow.B64Decode(b64)
        if !IsObject(buf)
            return ""
        path := NoteWindow.NewImagePath(NoteWindow.MimeExt(mime))
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
       CRYPT_STRING_BASE64(1)，第一遍问长度，第二遍真解。

       去空白用 StrReplace 而不是 RegExReplace("\s+")：后者在几 MB 的输入上
       会逐字节走一遍正则引擎，既慢又有撞 match limit 的风险。 */
    static B64Decode(b64) {
        if InStr(b64, "`n") || InStr(b64, "`r") || InStr(b64, " ") || InStr(b64, "`t")
            b64 := StrReplace(StrReplace(StrReplace(StrReplace(b64, "`r"), "`n"), "`t"), " ")
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
