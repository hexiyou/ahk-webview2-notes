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

    ; 列表窗口当前是不是前台（Ctrl+N 条件热键用这个判断）
    static IsActive() {
        if !ListWindow.Win
            return 0
        return WinActive("ahk_id " ListWindow.Win.gui.Hwnd) ? 1 : 0
    }

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
            wv.Settings.IsStatusBarEnabled := 0
            wv.Settings.AreDevToolsEnabled := ctx.devtools ? 1 : 0
            /* 关掉浏览器自带的快捷键（Ctrl+N / Ctrl+P / F5 之类）。不关的话
               Ctrl+N 会被 WebView2 当"新建窗口"吃掉，页面根本收不到 —— 表现就是
               "按了 Ctrl+N 毫无反应"。开了 devtools 时保留，否则 F12 也被禁。 */
            wv.Settings.AreBrowserAcceleratorKeysEnabled := ctx.devtools ? 1 : 0
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

    ; 拖动：页面顶栏按下后调这里，把控制权交给系统的移动循环。
    ; 之所以不用 -webkit-app-region: drag + IsNonClientRegionSupportEnabled 那条路，
    ; 是因为在带 WS_THICKFRAME 的窗口上它不生效（用户在真机上验证过：能点、拖不动）。
    static StartMove() {
        if !ListWindow.Win
            return
        try {
            hwnd := ListWindow.Win.gui.Hwnd
            DllCall("ReleaseCapture")
            PostMessage(0x00A1, 2, 0, , "ahk_id " hwnd)   ; WM_NCLBUTTONDOWN / HTCAPTION
        }
    }

    /* ★ 这里是 WebView2 的 COM 事件回调。AHK 在这种回调里的线程"不能等"：
       一旦在里面 await（建窗、关窗都要 await controller），await 永远等不到
       完成，整个线程就永久挂在那一句上。之后定时器照跑、按钮照点，但页面发来
       的消息再也进不来（拖动恰好也靠这些消息）—— 用户看到的就是
       "点完『新建』，两个窗口都拖不动了，但并没有卡死"。
       实测：app.log 里 "NewNote 被调用" 之后，再也没有"建窗完成"。

       所以回调里只做两件事：读参数、处理必须即时的拖动；其余一律交给
       SetTimer(..., -10) 起一个独立线程去做。 */
    static OnMessage(sender, args) {
        raw := ""
        try raw := args.WebMessageAsJson
        if (raw = "")
            return
        type := JsonStr(raw, "type")

        if (type = "drag-start") {
            try ListWindow.StartMove()
            catch as e
                App.Log("list 拖动出错：" CleanComError(e.Message) " @" e.Line)
            return
        }
        SetTimer(ListTick(raw, type), -10)
    }

    ; 真正干活的地方：跑在 SetTimer 起的独立线程里，可以安全地 await / 弹菜单 / 建窗
    static Handle(raw, type) {
        h := ListWindow.Hooks
        try {
            switch type {
                case "ready":
                    ListWindow.PushInit()
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
                case "pin":
                    ListWindow.Call("onPin", JsonNum(raw, "id"), JsonBool(raw, "on"))
                    ListWindow.Push(ListWindow.Query)
                case "color":
                    ListWindow.Call("onColor", JsonNum(raw, "id"), JsonStr(raw, "color"))
                    ListWindow.Push(ListWindow.Query)
                case "show-all":
                    ListWindow.Call("onShowAll")
                    ListWindow.Push(ListWindow.Query)
                case "hide-all":
                    ListWindow.Call("onHideAll")
                    ListWindow.Push(ListWindow.Query)
                case "data-dir":
                    ListWindow.Call("onDataDir")
                case "menu":
                    ListWindow.ShowMenu(JsonNum(raw, "id"))
                case "close":
                    ListWindow.Close()
            }
        } catch as e {
            App.Log("list 消息出错：" type " / " CleanComError(e.Message) " @" e.Line)
        }
    }

    ; 调一个宿主钩子；没有就静默跳过（列表窗口要能独立跑测试）
    static Call(hook, args*) {
        h := ListWindow.Hooks
        if !h || !h.Has(hook)
            return
        try h[hook](args*)
        catch as e
            App.Log("钩子 " hook " 出错：" CleanComError(e.Message) " @" e.Line)
    }

    /* 同 note-window：菜单回调会被传 3 个参数，回调声明得少会抛
       "Too many parameters"，所以统一套一层变参箭头。 */
    static Cb(fn) {
        return (*) => fn.Call()
    }

    /* 右键菜单。id=0 表示点在空白处（面板菜单），否则是该条便签的菜单。
       参数用普通函数包一层再交给 Cb：闭包捕获的是"变量"，直接在 for 循环里
       建箭头会导致所有项都指向最后一个颜色。 */
    static ShowMenu(id) {
        if !ListWindow.Win
            return
        if (id) {
            n := ListWindow.Store ? ListWindow.Store.Get(id) : 0
            if !n
                return
            m := Menu()
            m.Add("打开", ListWindow.Cb(ListMenuOpen(id)))
            m.Add("重命名…", ListWindow.Cb(ListMenuRename(id)))
            m.Add()
            m.Add(n.pinned ? "取消置顶" : "置顶", ListWindow.Cb(ListMenuPin(id, n.pinned ? 0 : 1)))
            sub := Menu()
            for cname, hex in NoteWindow.Colors() {
                sub.Add(NoteWindow.ColorLabel(cname), ListWindow.Cb(ListMenuColor(id, cname)))
                if (cname = n.color)
                    sub.Check(NoteWindow.ColorLabel(cname))
            }
            m.Add("颜色", sub)
            m.Add()
            m.Add("收起这张", ListWindow.Cb(ListMenuHide(id)))
            m.Add("删除…", ListWindow.Cb(ListMenuDelete(id)))
            m.Show()
            return
        }
        m := Menu()
        m.Add("新建便签", ListWindow.Cb(ListMenuNew()))
        m.Add("刷新列表", ListWindow.Cb(ListMenuRefresh()))
        m.Add()
        m.Add("全部显示", ListWindow.Cb(ListMenuShowAll()))
        m.Add("全部收起", ListWindow.Cb(ListMenuHideAll()))
        m.Add()
        m.Add("打开数据目录", ListWindow.Cb(ListMenuDataDir()))
        m.Show()
    }

    ; 页面就绪时先下发外观/交互参数，再推数据
    static PushInit() {
        if !ListWindow.Win
            return
        appr := ListWindow.Ctx ? ListWindow.Ctx.appearance : 0
        drag := (appr && appr.drag) ? appr.drag : "manual"
        json := '{"type":"init","drag":' JsonQuote(drag) '}'
        try ListWindow.Win.wv.PostWebMessageAsJson(json)
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

; ---- 菜单回调 ------------------------------------------------------------
; 每个函数返回一个"零参闭包"，由 ListWindow.Cb 再包一层变参箭头。
; 必须经过函数参数转一手：闭包捕获的是变量本身，直接在 for 循环体里写箭头，
; 所有菜单项会一起指向循环结束时的最后一个值。
ListTick(raw, type) {
    return () => ListWindow.Handle(raw, type)
}

ListMenuOpen(id) {
    return () => ListWindow.Call("onOpen", id)
}

ListMenuRename(id) {
    return () => ListWindow.Call("onRename", id)
}

ListMenuPin(id, on) {
    return () => ListWindow.Call("onPin", id, on)
}

ListMenuColor(id, name) {
    return () => ListWindow.Call("onColor", id, name)
}

ListMenuHide(id) {
    return () => ListWindow.Call("onHide", id)
}

ListMenuDelete(id) {
    return () => ListWindow.Call("onDelete", id)
}

ListMenuNew() {
    return () => ListWindow.Call("onNew")
}

ListMenuRefresh() {
    return () => ListWindow.Push(ListWindow.Query)
}

ListMenuShowAll() {
    return () => ListWindow.Call("onShowAll")
}

ListMenuHideAll() {
    return () => ListWindow.Call("onHideAll")
}

ListMenuDataDir() {
    return () => ListWindow.Call("onDataDir")
}
