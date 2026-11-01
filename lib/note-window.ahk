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
            this.wv.Settings.AreBrowserAcceleratorKeysEnabled := 0
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
                    this.Destroy()
                    NoteWindow.Store.Delete(this.id)
                    App.RefreshTray()
                case "hide":
                    this.Hide()
                case "new":
                    App.NewNote()
                case "list":
                    App.ShowList()
                case "drag-start":
                    if (NoteWindow.Ctx.appearance.drag = "manual")
                        this.StartMove()
                case "resize-start":
                    this.StartResize(JsonStr(raw, "edge", "se"))
                case "menu":
                    this.ShowMenu()
                case "open-external":
                    App.OpenExternal(JsonStr(raw, "url"))
                case "toast":
                    App.Toast(JsonStr(raw, "text"))
            }
        } catch as e {
            App.Log("msg/" type " 出错：" CleanComError(e.Message) " @" e.Line)
        }
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
        this.note.pinned := on
        try this.gui.Opt((on ? "+" : "-") "AlwaysOnTop")
        if (on)
            try WinSetAlwaysOnTop(1, "ahk_id " this.gui.Hwnd)
    }

    DoColor(color) {
        if !NoteWindow.IsColor(color)
            return
        NoteWindow.Store.SetColor(this.id, color)
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

    ; ---- 右键菜单 -----------------------------------------------------------

    ShowMenu() {
        ; 注意：AHK v2 的箭头函数没有 this 绑定，回调一律用 ObjBindMethod
        m := Menu()
        m.Add("新建便签", (*) => App.NewNote())
        m.Add()
        m.Add(this.note.pinned ? "取消置顶" : "置顶", ObjBindMethod(this, "TogglePin"))
        sub := Menu()
        for name, hex in NoteWindow.Colors() {
            sub.Add(NoteWindow.ColorLabel(name), ObjBindMethod(this, "DoColor", name))
            if (name = this.note.color)
                sub.Check(NoteWindow.ColorLabel(name))
        }
        m.Add("颜色", sub)
        m.Add()
        m.Add("切换 Markdown 源码", ObjBindMethod(this, "SendType", "toggle-md"))
        m.Add("复制全文", ObjBindMethod(this, "SendType", "copy-all"))
        m.Add()
        m.Add("便签列表…", (*) => App.ShowList())
        m.Add("收起这张", ObjBindMethod(this, "Hide"))
        m.Add("删除这张…", ObjBindMethod(this, "ConfirmDelete"))
        m.Show()
    }

    ConfirmDelete() {
        r := MsgBox("删除这张便签？此操作不可撤销。", "便签", "YesNo Icon?")
        if (r = "Yes") {
            this.Destroy()
            NoteWindow.Store.Delete(this.id)
            App.RefreshTray()
        }
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
}
