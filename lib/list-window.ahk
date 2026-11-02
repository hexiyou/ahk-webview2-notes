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
    /* 列表窗口自己的置顶。和便签的置顶不是一回事：那个是每条便签的字段（存库里），
       这个是窗口偏好，存在 config.ini 的 [window] listTopmost，下次开还置顶。 */
    static Topmost := 0

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
        ; 置顶是窗口偏好，开窗前就要定下来（Gui 的 +AlwaysOnTop 只能在创建时给，
        ; 之后补 WinSetAlwaysOnTop 也行，但会闪一下）
        ListWindow.Topmost := App.Cfg("window", "listTopmost", 0) ? 1 : 0
        g := Gui("-Caption +Resize" (ListWindow.Topmost ? " +AlwaysOnTop" : ""), "便签列表")
        g.MarginX := 0
        g.MarginY := 0
        g.BackColor := "0xFFFDF8EE"
        g.OnEvent("Close", (*) => ListWindow.Close())
        g.OnEvent("Escape", (*) => ListWindow.Close())
        /* ★ 拖边框改大小必须接 Size：WebView2 的 controller 不会跟着父窗口长大
           （它只认 put_Bounds，也就是 Fill() 那一下）。不接这个事件的表现是
           "窗口拉大了，内容还停在原来的尺寸，右边一大片空白"。
           这里直接 Fill 而不是转给 SetTimer：用户拖边框时系统在模态的
           WM_SIZING 循环里排队派发消息，脚本自己的消息循环不转，定时器不一定
           跟得上；而这个回调本身就在窗口过程里，正好赶在重画之前。 */
        g.OnEvent("Size", ListOnSize)

        ; 上次的大小/位置（没有或不对劲就用 DefaultGeo）
        geo := ListWindow.LoadGeo()
        g.Show("w" geo.w " h" geo.h " x" geo.x " y" geo.y)
        Win.RoundCorners(g.Hwnd, true)
        ; 尺寸下限：不设的话能一路拖成一条缝，里面就全挤扁了
        OnMessage(0x0024, ListMinSize)

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

    ; 窗口尺寸变了：让 controller 重新对齐客户区。最小化时客户区是 0，
    ; 铺上去等于把页面压成一条，还原时会闪一下，所以不理。
    static OnSize(minMax) {
        if (minMax = -1)
            return
        ListWindow.Refill()
        /* 顺手把新尺寸记下来。不等关闭才存：程序被强杀（或从任务管理器结束）
           那一笔就丢了。SetTimer 每来一次会重置，天然是 400ms 防抖。 */
        SetTimer(ListSaveGeoSoon, -400)
    }

    /* 默认落点：主屏右侧、工作区里。工作区可能是 0（远程/无显示器），
       Min 之后会变成负数，Gui.Show 直接抛错，所以既要有上限也要有下限。 */
    static DefaultGeo() {
        wa := Win.WorkArea()
        w := Max(360, Min(520, wa.w - 60))
        h := Max(420, Min(560, wa.h - 80))
        x := Max(0, wa.r - w - 40)
        y := Max(0, wa.t + 80)
        return { x: x, y: y, w: w, h: h }
    }

    /* 上次的尺寸/位置，存成 "x,y,w,h" 一行（跟便签几何一个格式）。
       读出来还要过一遍 Win.Clamp：上次可能是在另一块屏、或更大的分辨率上拖的，
       直接照搬会开到看不见的地方去。 */
    static LoadGeo() {
        d := ListWindow.DefaultGeo()
        s := App.Cfg("window", "listGeo", "")
        if (s = "")
            return d
        p := StrSplit(s, ",")
        if (p.Length != 4)
            return d
        if !(IsNumber(p[1]) && IsNumber(p[2]) && IsNumber(p[3]) && IsNumber(p[4]))
            return d
        return Win.Clamp(p[1] + 0, p[2] + 0, Max(p[3] + 0, 380), Max(p[4] + 0, 300))
    }

    static SaveGeo() {
        if !ListWindow.Win
            return
        r := Win.Rect(ListWindow.Win.gui.Hwnd)
        c := Win.ClientSize(ListWindow.Win.gui.Hwnd)   ; 存客户区，见 Win.ClientSize 的注释
        if (c.w < 200 || c.h < 150)     ; 还没摆好的脏值（0 或极小）不记
            return
        try App.SetCfg("window", "listGeo", r.x "," r.y "," c.w "," c.h)
    }

    /* 切换列表窗口的置顶。窗口不在也照样记下偏好（下次打开就是置顶的），
       config.ini 写盘是 IniWrite，很便宜，不做合并。 */
    static SetTopmost(on) {
        on := on ? 1 : 0
        if (on = ListWindow.Topmost)
            return
        ListWindow.Topmost := on
        if ListWindow.Win
            try WinSetAlwaysOnTop(on, "ahk_id " ListWindow.Win.gui.Hwnd)
        try App.SetCfg("window", "listTopmost", on)
        if ListWindow.Win {
            try ListWindow.Win.wv.PostWebMessageAsJson(
                '{"type":"topmost","on":' (on ? "true" : "false") '}')
            ; 置顶/取消置顶会改变 z 序，重新激活一下，免得窗口沉到后面去了
            if on
                try WinActivate("ahk_id " ListWindow.Win.gui.Hwnd)
        }
    }

    static ToggleTopmost() {
        ListWindow.SetTopmost(!ListWindow.Topmost)
    }

    static Close() {
        if !ListWindow.Win
            return
        ListWindow.SaveGeo()            ; 关之前记下这次的尺寸/位置
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
                case "window-topmost":
                    ListWindow.SetTopmost(JsonNum(raw, "on"))
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

    /* 会改数据的钩子调完必须回推一次列表。
       ★ 页面按钮那条路（✕ 收起 删除）是 Handle 里统一 Push 的，而右键菜单是
       直接调 Call —— 第一版菜单忘了补这一步，现象就是"右键删除后，那一行还
       赖在列表里，手快再点它一下就报『便签已经被删除』"。新建/改名/置顶/换色/
       收起 是同一个毛病，所以统一走这里，别再各写各的。 */
    static CallThenPush(hook, args*) {
        ListWindow.Call(hook, args*)
        ListWindow.Push(ListWindow.Query)
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
            m.Add(n.hotkey ? "快捷键…（" NoteWindow.HotkeyPretty(n.hotkey) "）" : "设置快捷键…"
                , ListWindow.Cb(ListMenuHotkey(id)))
            m.Add()
            m.Add(n.pinned ? "取消置顶" : "置顶", ListWindow.Cb(ListMenuPin(id, n.pinned ? 0 : 1)))
            sub := Menu()
            ; 顺序走 ColorKeys()：Map 的遍历顺序是哈希序，不排会每次换位置
            for cname in NoteWindow.ColorKeys() {
                if !NoteWindow.IsColor(cname)
                    continue
                sub.Add(NoteWindow.ColorLabel(cname), ListWindow.Cb(ListMenuColor(id, cname)))
                if (cname = n.color)
                    sub.Check(NoteWindow.ColorLabel(cname))
            }
            m.Add("颜色", sub)

            /* 透明度：第一项固定是"重置"。设得太透、便签看着像没了的时候，
               得有一个不用先找到那张便签就能点回来的入口 —— 所以它必须在
               列表里（便签本身这时可能已经"找不到"了）。 */
            am := Menu()
            am.Add("重置透明度（100%）", ListWindow.Cb(ListMenuOpacity(id, 100)))
            if (n.opacity >= 100)
                am.Check("重置透明度（100%）")
            am.Add()
            for pct in NoteWindow.OpacityLevels() {
                if (pct = 100)
                    continue
                am.Add(pct "%", ListWindow.Cb(ListMenuOpacity(id, pct)))
                if (pct = n.opacity)
                    am.Check(pct "%")
            }
            m.Add("透明度", am)

            ; 导出：和便签右键菜单里的那一套完全一样，只是入口不同
            em := Menu()
            em.Add("纯文本  (*.txt)", ListWindow.Cb(ListMenuExport(id, "txt")))
            em.Add("Markdown (*.md)", ListWindow.Cb(ListMenuExport(id, "md")))
            em.Add("网页  (*.html)", ListWindow.Cb(ListMenuExport(id, "html")))
            em.Add("RTF 文档 (*.rtf)", ListWindow.Cb(ListMenuExport(id, "rtf")))
            m.Add("导出", em)

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
        m.Add("窗口置顶", ListWindow.Cb(ListMenuTopmost()))
        if ListWindow.Topmost
            m.Check("窗口置顶")
        m.Add()
        m.Add("设置…", ListWindow.Cb(ListMenuSettings()))
        m.Add("打开数据目录", ListWindow.Cb(ListMenuDataDir()))
        m.Show()
    }

    ; 页面就绪时先下发外观/交互参数，再推数据
    static PushInit() {
        if !ListWindow.Win
            return
        appr := ListWindow.Ctx ? ListWindow.Ctx.appearance : 0
        drag := (appr && appr.drag) ? appr.drag : "manual"
        json := '{"type":"init","drag":' JsonQuote(drag)
            . ',"topmost":' (ListWindow.Topmost ? 1 : 0) '}'
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
            json .= ',"opacity":' n.opacity
            ; 角标显示人话（Ctrl+Alt+1），库里存的还是 ^!1
            json .= ',"hk":' JsonQuote(n.hotkey = "" ? "" : NoteWindow.HotkeyPretty(n.hotkey))
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
; 尺寸变了的 400ms 防抖保存（每来一次 Size 都会重置这个定时器）
ListSaveGeoSoon() => ListWindow.SaveGeo()
; Gui 的 Size 事件回调带三个参数（GuiObj, MinMax, Width, Height），
; 参数个数写少一个都会抛 "Too many parameters"
ListOnSize(g, minMax, w, h) => ListWindow.OnSize(minMax)

/* WM_GETMINMAXINFO(0x0024)：窗口能拖到多小。
   lParam 指向 MINMAXINFO，ptMinTrackSize 在偏移 24(x) / 28(y)。
   不设下限时能把窗口一路拖成一条缝，里头就全挤扁了。 */
ListMinSize(wParam, lParam, msg, hwnd) {
    if !ListWindow.Win || hwnd != ListWindow.Win.gui.Hwnd
        return
    NumPut("int", 380, lParam, 24)
    NumPut("int", 300, lParam, 28)
}

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

ListMenuExport(id, fmt) {
    return () => ListWindow.Call("onExport", id, fmt)
}

ListMenuRename(id) {
    return () => ListWindow.CallThenPush("onRename", id)
}

ListMenuPin(id, on) {
    return () => ListWindow.CallThenPush("onPin", id, on)
}

ListMenuColor(id, name) {
    return () => ListWindow.CallThenPush("onColor", id, name)
}

ListMenuOpacity(id, pct) {
    return () => ListWindow.CallThenPush("onOpacity", id, pct)
}

ListMenuHotkey(id) {
    return () => ListWindow.CallThenPush("onHotkey", id)
}

ListMenuHide(id) {
    return () => ListWindow.CallThenPush("onHide", id)
}

ListMenuDelete(id) {
    return () => ListWindow.CallThenPush("onDelete", id)
}

ListMenuNew() {
    return () => ListWindow.CallThenPush("onNew")
}

ListMenuRefresh() {
    return () => ListWindow.Push(ListWindow.Query)
}

ListMenuShowAll() {
    return () => ListWindow.CallThenPush("onShowAll")
}

ListMenuHideAll() {
    return () => ListWindow.CallThenPush("onHideAll")
}

ListMenuDataDir() {
    return () => ListWindow.Call("onDataDir")
}

; 设置面板要建 WebView2 controller（内部 await），宿主的 onSettings 自己会
; 用 SetTimer 挪出菜单回调，这里只管转发。
ListMenuSettings() {
    return () => ListWindow.Call("onSettings")
}

; 窗口置顶：直接切，不用绕回宿主 —— 它只动窗口样式 + config.ini
ListMenuTopmost() {
    return () => ListWindow.ToggleTopmost()
}
