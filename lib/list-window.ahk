#Requires AutoHotkey v2.0
; ============================================================================
;  list-window.ahk —— 便签列表 / 搜索面板（单例）
;
;  与便签窗口的区别：这个窗口是普通的不透明窗口，用来总览所有便签（含已收起的）。
;  它不直接改数据，所有动作都通过 Hooks 交回主程序：
;      Hooks := Map("onNew", fn, "onOpen", fn, "onDelete", fn, "onHide", fn, "onClose", fn)
;      （用 Map 而不是对象字面量：对象属性直接调用会把对象自身当成第一个参数传进去）
;
;  搜索不在前端过滤，而是回主程序走 SQL LIKE —— 能搜到正文深处，中文也不用分词。
; ============================================================================

class ListWindow {
    static Store := 0
    static Ctx := 0
    static Hooks := 0
    static Win := 0
    static Query := ""

    static IsOpen() => ListWindow.Win ? 1 : 0

    static Open() {
        if ListWindow.Win {
            try {
                ListWindow.Win.gui.Show()
                ListWindow.Win.wv.PostWebMessageAsJson('{"type":"refresh"}')
                WinActivate("ahk_id " ListWindow.Win.gui.Hwnd)
                return
            } catch {
                ListWindow.Win := 0
            }
        }
        ctx := ListWindow.Ctx
        g := Gui("-Caption +Resize", "便签列表")
        g.MarginX := 0
        g.MarginY := 0
        g.BackColor := "0xFFFDF8EE"
        g.OnEvent("Close", (*) => ListWindow.Close())
        g.OnEvent("Escape", (*) => ListWindow.Close())

        ; 工作区可能是 0（远程/无显示器），Min 之后会变成负数，Gui.Show 直接抛错，
        ; 所以这里既要有上限也要有下限
        wa := Win.WorkArea()
        w := Max(360, Min(520, wa.w - 60))
        h := Max(420, Min(560, wa.h - 80))
        x := Max(0, wa.r - w - 40)
        y := Max(0, wa.t + 80)
        g.Show("w" w " h" h " x" x " y" y)
        Win.RoundCorners(g.Hwnd, true)

        try {
            wvc := WebView2.CreateControllerAsync(g.Hwnd, 0, ctx.dataDir, "", ctx.dllPath).await()
        } catch as e {
            MsgBox("列表窗口初始化失败：`n" CleanComError(e.Message), "便签", "Icon!")
            try g.Destroy()
            return
        }
        wv := wvc.CoreWebView2
        try {
            wvc.DefaultBackgroundColor := 0xFFFDF8EE
            wv.Settings.IsNonClientRegionSupportEnabled := 1
            wv.Settings.AreDefaultContextMenusEnabled := 0
            wv.Settings.AreDevToolsEnabled := ctx.devtools ? 1 : 0
        }
        wvc.Fill()
        wvc.IsVisible := 1

        ListWindow.Win := { gui: g, wv: wv, wvc: wvc }
        ; 静态方法引用直接喂给 COM 事件/SetTimer 都会踩坑（拿到的不是可调用对象），
        ; 统一用顶层包装函数转一道
        wv.add_WebMessageReceived(ListOnMessage)
        wv.Navigate(NoteWindow.FileUrl(ctx.uiDir "\list.html"))

        ; 显示后补两次尺寸，收掉残留白屏
        SetTimer(ListRefill, -200)
        SetTimer(ListRefill, -600)
    }

    static Refill() {
        if !ListWindow.Win
            return
        try {
            ListWindow.Win.wvc.Fill()
            ListWindow.Win.wvc.IsVisible := 1
        }
    }

    static Close() {
        if !ListWindow.Win
            return
        try ListWindow.Win.wvc.Close()
        try ListWindow.Win.gui.Destroy()
        ListWindow.Win := 0
        if ListWindow.Hooks && ListWindow.Hooks.Has("onClose")
            try ListWindow.Hooks["onClose"]()
    }

    static OnMessage(sender, args) {
        raw := ""
        try raw := args.WebMessageAsJson
        if (raw = "")
            return
        h := ListWindow.Hooks
        try {
            switch JsonStr(raw, "type") {
                case "ready":
                    ListWindow.Push()
                case "refresh":
                    ListWindow.Push(ListWindow.Query)
                case "search":
                    ListWindow.Query := JsonStr(raw, "q")
                    ListWindow.Push(ListWindow.Query)
                case "new":
                    if h && h.Has("onNew")
                        h["onNew"]()
                    ListWindow.Push(ListWindow.Query)
                case "open":
                    if h && h.Has("onOpen")
                        h["onOpen"](JsonNum(raw, "id"))
                    ListWindow.Push(ListWindow.Query)
                case "delete":
                    if h && h.Has("onDelete")
                        h["onDelete"](JsonNum(raw, "id"))
                    ListWindow.Push(ListWindow.Query)
                case "hide":
                    if h && h.Has("onHide")
                        h["onHide"](JsonNum(raw, "id"))
                    ListWindow.Push(ListWindow.Query)
                case "close":
                    ListWindow.Close()
            }
        } catch as e {
            App.Log("list 消息出错：" CleanComError(e.Message) " @" e.Line)
        }
    }

    ; 推一批便签到页面；term 为空推全部（含已收起）
    static Push(term := "") {
        if !ListWindow.Win
            return
        notes := (term = "") ? ListWindow.Store.All() : ListWindow.Store.SearchAll(term)
        json := '{"type":"notes","items":['
        for i, n in notes {
            if (i > 1)
                json .= ","
            json .= '{"id":' n.id
            json .= ',"title":' JsonQuote(n.title)
            json .= ',"excerpt":' JsonQuote(ListWindow.Excerpt(n.body_text, 60))
            json .= ',"color":' JsonQuote(n.color)
            json .= ',"pinned":' n.pinned
            json .= ',"hidden":' n.hidden
            json .= ',"updated":' n.updated_at
            json .= "}"
        }
        json .= "]}"
        try ListWindow.Win.wv.PostWebMessageAsJson(json)
    }

    static Excerpt(text, len) {
        t := Trim(RegExReplace(text, "\s+", " "))
        return StrLen(t) > len ? SubStr(t, 1, len) "…" : t
    }
}


; ---- 顶层包装（COM 事件 / SetTimer 用） ----------------------------------
ListOnMessage(sender, args) => ListWindow.OnMessage(sender, args)
ListRefill() => ListWindow.Refill()
