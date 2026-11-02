#Requires AutoHotkey v2.0
; ============================================================================
;  ipc.ahk —— 外部进程调用接口（窗口消息）
;
;  为什么不开 HTTP：便签是常驻桌面小工具，开端口要处理鉴权、防火墙弹窗、
;  端口冲突，收益却只是"好调用"。而 Windows 本来就有跨进程调用的正规通道：
;  给某个窗口句柄发一条消息。发起方一行 SendMessage 就够了，收不到就说明
;  目标没在跑 —— 语义清楚，没有半开连接、没有超时重试。
;
;  ┌ 外部进程 ── FindWindow("QuickNoteAnchor") ────────────────────┐
;  │  SendMessage(hwnd, 0x8010, 0x514E, 0)      新建一张空便签      │
;  │  SendMessage(hwnd, 0x8011, 0x514E, 0)      打开便签列表        │
;  │  SendMessage(hwnd, WM_COPYDATA, 0, &cds)   带内容新建（JSON/纯文本）│
;  └──────────────────────────────────────────────────────────────┘
;                   ↓ 建好后回执
;  PostMessage(调用方窗口, 0x8014, 新便签 id, 0)
;
;  ★★ 三条铁律（都是踩出来的，改代码前先读）
;
;  1) 消息回调跑在 AHK 的**新线程**里，随时可能打断主线程（跟 SetTimer 一样）。
;     这里只许"校验 + 入队"：不能建 WebView2、不能弹菜单/对话框、不能写库。
;     建 controller 要 await，而 COM 回调里 await 永不返回 —— 一旦在这里建窗，
;     发送方的 SendMessage 会一直卡着，整个程序看起来就是死了。
;
;  2) 真正的活儿全部丢给 SetTimer(IpcDrain, -1) 回主线程做，
;     和 NoteShowAllSoon / NoteDeferNew 是同一套纪律。
;
;  3) WM_COPYDATA 是**同步**的：对方一直等到这里返回。返回值 1 只代表"已受理"，
;     不代表便签已经建好（排队的活儿还在后面）。要 id 就得传 replyTo，
;     等我们建完再 PostMessage 回执。
;
;  另外两条环境边界（代码管不了，只能写进文档）：
;    · UIPI：低完整性进程发不进高完整性窗口。便签要是以管理员身份跑，
;      普通权限的调用方会"发送成功但毫无反应"。
;    · 会话隔离：RDP 另一个会话、另一个登录用户，都收不到。
; ============================================================================

class Ipc {
    static Anchor := 0            ; 锚点窗口句柄（外部就发给它）
    static Enabled := 1           ; [ipc] enabled
    static Activate := 1          ; [ipc] activate：外部建的便签要不要抢焦点
    static Jobs := []             ; 待派发队列
    static Accepted := 0          ; 累计受理
    static Rejected := 0          ; 累计拒绝（队列满 / 载荷非法）
    static LastErr := ""

    ; 消息号：WM_APP 区间（0x8000-0xBFFF）是进程私有的，跨进程发送时系统不解释，
    ; 不会和任何系统消息撞车。不要用 WM_USER(0x0400-0x7FFF)，那是"按窗口类"语义的。
    static WM_WAKE := 0x8001      ; 老语义：全部显示（第二个实例唤醒用）
    static WM_NEW := 0x8010       ; 新建空便签
    static WM_LIST := 0x8011      ; 打开便签列表
    static WM_ACK := 0x8014       ; 回执：wParam = 新便签 id（0 = 失败）
    static WM_COPY := 0x004A      ; WM_COPYDATA，系统消息号，不能改

    ; 魔数：wParam 必须是它，防止别的程序瞎广播的 WM_APP 消息被当真
    static MAGIC := 0x514E        ; "NQ"
    static CD_MAGIC := 0x514E3031 ; "QN01"，放在 COPYDATASTRUCT.dwData 里
    static MAX_BYTES := 65536     ; 载荷上限（官方也建议 COPYDATA 别传大数据）
    static MAX_QUEUE := 32        ; 队列上限，防止被刷爆
    static F_QUIET := 0x1         ; WM_NEW 的 lParam：bit0 = 建完不抢焦点

    ; ========================================================================
    ;  安装
    ; ========================================================================

    static Install(hwnd) {
        Ipc.Anchor := hwnd
        Ipc.Enabled := App.Cfg("ipc", "enabled", 1) ? 1 : 0
        Ipc.Activate := App.Cfg("ipc", "activate", 1) ? 1 : 0

        /* 给锚点盖一个窗口属性。标题（QuickNoteAnchor）已经够用，
           但属性不怕被别的程序改成同名窗口 —— 高级调用方可以用
           EnumWindows + GetPropW 精确认亲。 */
        try DllCall("SetPropW", "ptr", hwnd, "wstr", "QuickNote.IPC", "ptr", 1, "int")

        OnMessage(Ipc.WM_WAKE, IpcOnWake)
        OnMessage(Ipc.WM_NEW, IpcOnNew)
        OnMessage(Ipc.WM_LIST, IpcOnList)
        OnMessage(Ipc.WM_COPY, IpcOnCopyData)

        App.Log("IPC 就绪：锚点=" hwnd
            "，新建=0x" Format("{:X}", Ipc.WM_NEW)
            "，列表=0x" Format("{:X}", Ipc.WM_LIST)
            "，回执=0x" Format("{:X}", Ipc.WM_ACK)
            "，COPYDATA=0x4A"
            "，enabled=" Ipc.Enabled " activate=" Ipc.Activate)
    }

    ; ========================================================================
    ;  消息回调（新线程！只许校验 + 入队）
    ; ========================================================================

    static HandleWake(wParam, lParam, msg, hwnd) {
        if (hwnd != Ipc.Anchor)
            return 0
        NoteShowAllSoon()          ; 它自己会 SetTimer 换线程
        return 1
    }

    static HandleNew(wParam, lParam, msg, hwnd) {
        if (hwnd != Ipc.Anchor || wParam != Ipc.MAGIC || !Ipc.Enabled)
            return 0
        return Ipc.Accept(Ipc.NewJob(Map("quiet", (lParam & Ipc.F_QUIET) ? 1 : 0)))
    }

    static HandleList(wParam, lParam, msg, hwnd) {
        if (hwnd != Ipc.Anchor || wParam != Ipc.MAGIC || !Ipc.Enabled)
            return 0
        return Ipc.Accept(Map("op", "list"))
    }

    /* WM_COPYDATA。COPYDATASTRUCT 的布局：
         64 位：dwData(8) cbData(4) [4 字节对齐] lpData(8) = 24 字节
         32 位：dwData(4) cbData(4)              lpData(4) = 12 字节
       手搓指针最容易错的就是 64 位下的这个对齐 —— lpData 在 16 而不是 12。 */
    static HandleCopyData(wParam, lParam, msg, hwnd) {
        if (hwnd != Ipc.Anchor || !Ipc.Enabled || !lParam)
            return 0

        magic := NumGet(lParam, 0, "ptr")
        if (magic != Ipc.CD_MAGIC) {
            Ipc.Rejected++
            App.Log("IPC 拒绝：dwData 不是 QN01（收到 0x" Format("{:X}", magic) "）")
            return 0
        }

        cb := NumGet(lParam, A_PtrSize, "uint")
        if (cb < 1 || cb > Ipc.MAX_BYTES) {
            Ipc.Rejected++
            App.Log("IPC 拒绝：载荷 " cb " 字节，超出 1~" Ipc.MAX_BYTES)
            return 0
        }

        off := (A_PtrSize = 8) ? 16 : 8
        p := NumGet(lParam, off, "ptr")
        if !p
            return 0

        raw := ""
        try raw := StrGet(p, cb, "UTF-8")
        catch as e {
            Ipc.Rejected++
            App.Log("IPC 拒绝：载荷不是合法 UTF-8（" CleanComError(e.Message) "）")
            return 0
        }
        return Ipc.AcceptPayload(raw)
    }

    ; ========================================================================
    ;  载荷 → 任务
    ; ========================================================================

    /* 两种模式都收：
       · 以 { 开头 → 当成扁平 JSON（只认标量字段，不递归；够用了）
       · 否则整段当正文（对接计划任务、ToDo 类工具时，对方最可能只会塞字符串） */
    static AcceptPayload(raw) {
        probe := Trim(raw, " `t`r`n")
        if (probe = "")
            return 0

        j := Ipc.NewJob()
        if (SubStr(probe, 1, 1) = "{") {
            j["format"] := JsonStr(probe, "format", "text")
            j["text"] := JsonStr(probe, "text", "")
            j["title"] := JsonStr(probe, "title", "")
            j["color"] := JsonStr(probe, "color", "")
            j["pin"] := JsonBool(probe, "pin", JsonBool(probe, "pinned", 0))
            j["activate"] := JsonNum(probe, "activate", -1)
            j["replyTo"] := JsonNum(probe, "replyTo", 0)
            if JsonHas(probe, "x")
                j["x"] := JsonNum(probe, "x", 0)
            if JsonHas(probe, "y")
                j["y"] := JsonNum(probe, "y", 0)
            if JsonHas(probe, "w")
                j["w"] := JsonNum(probe, "w", 0)
            if JsonHas(probe, "h")
                j["h"] := JsonNum(probe, "h", 0)
            j["hasXY"] := (JsonHas(probe, "x") && JsonHas(probe, "y")) ? 1 : 0
            if (j["text"] = "" && j["title"] = "")
                return 0
        } else {
            ; 纯文本：只掐掉结尾换行（echo 出来的常见形态），缩进原样保留
            j["text"] := Trim(raw, "`r`n")
            if (j["text"] = "")
                return 0
        }
        return Ipc.Accept(j)
    }

    static NewJob(extra := 0) {
        j := Map("op", "new", "format", "text", "text", "", "title", "",
            "color", "", "pin", 0, "x", 0, "y", 0, "w", 0, "h", 0,
            "activate", -1, "replyTo", 0, "hasXY", 0, "quiet", 0)
        if IsObject(extra)
            for k, v in extra
                j[k] := v
        return j
    }

    static Accept(job) {
        if (Ipc.Jobs.Length >= Ipc.MAX_QUEUE) {
            Ipc.Rejected++
            App.Log("IPC 拒绝：队列满（" Ipc.MAX_QUEUE " 条），先让主线程消化一下")
            return 0
        }
        Ipc.Jobs.Push(job)
        Ipc.Accepted++
        SetTimer(IpcDrain, -1)
        return 1
    }

    ; ========================================================================
    ;  派发（主线程）
    ; ========================================================================

    static Drain() {
        if !Ipc.Jobs.Length
            return
        job := Ipc.Jobs.RemoveAt(1)
        try Ipc.Run(job)
        catch as e {
            Ipc.LastErr := CleanComError(e.Message)
            App.Log("IPC 执行失败：" Ipc.LastErr " @" e.Line)
            Ipc.Reply(job, 0)
        }
        ; 还有活就再来一轮。留 30ms 空隙：建窗是重活，别让定时器把消息循环连坐
        if Ipc.Jobs.Length
            SetTimer(IpcDrain, -30)
    }

    static Run(job) {
        switch job["op"] {
            case "new":
                ; 抢不抢焦点：调用方明说了就听调用方的，没说就用 [ipc] activate
                act := job["activate"]
                if (act = -1)
                    act := job["quiet"] ? 0 : Ipc.Activate
                w := App.NewNote(Map(
                    "text", job["text"], "title", job["title"], "color", job["color"],
                    "pin", job["pin"], "activate", act,
                    "x", job["x"], "y", job["y"], "w", job["w"], "h", job["h"],
                    "hasXY", job["hasXY"], "format", job["format"]))
                id := (IsObject(w) && w.HasProp("id")) ? w.id : 0
                App.Log("IPC 新建便签 id=" id "，正文 " StrLen(job["text"]) " 字"
                    (job["title"] = "" ? "" : "，标题[" job["title"] "]"))
                Ipc.Reply(job, id)
            case "list":
                App.ShowList()
                App.Log("IPC 打开便签列表")
        }
    }

    /* 回执：只发给"还活着"的窗口。对方要是先退了（脚本跑完就 ExitApp 那种），
       IsWindow 会挡住，不至于把消息丢进黑洞。

       ★ 这里不能用 AHK 自带的 PostMessage：它按 WinTitle 找窗口，
         而 WinTitle 的搜索只覆盖**顶层窗口**。作回执信箱的常常是
         "message-only 窗口"（HWND_MESSAGE），AHK 根本找不到它，
         结果就是 PostMessage 静默失败 —— 调 Python 那版时踩到过，
         日志里是"投递失败"，调用方永远等不到回执。直接 DllCall 就没这问题。 */
    static Reply(job, id) {
        h := job["replyTo"]
        if !h
            return
        if !DllCall("IsWindow", "ptr", h, "int")
            return
        ok := 0
        try ok := DllCall("PostMessageW", "ptr", h, "uint", Ipc.WM_ACK
            , "ptr", id, "ptr", 0, "int")
        App.Log("IPC 回执：目标=" h " id=" id " 结果=" (ok ? "已投递" : "投递失败"))
    }

    ; ========================================================================
    ;  发送端（第二个实例 / 命令行 / 自检都用这套，别另写一份）
    ; ========================================================================

    static SendCopy(hwnd, payload) {
        n := StrPut(payload, "UTF-8")
        buf := Buffer(n, 0)
        StrPut(payload, buf, "UTF-8")
        cds := Buffer((A_PtrSize = 8) ? 24 : 12, 0)
        NumPut("ptr", Ipc.CD_MAGIC, cds, 0)
        NumPut("uint", n - 1, cds, A_PtrSize)
        NumPut("ptr", buf.Ptr, cds, (A_PtrSize = 8) ? 16 : 8)
        return SendMessage(Ipc.WM_COPY, 0, cds.Ptr, , "ahk_id " hwnd)
    }

    static SendText(hwnd, text, replyTo := 0) {
        j := '{"text":' JsonQuote(text) ',"format":"text"'
        if replyTo
            j .= ',"replyTo":' replyTo
        j .= "}"
        return Ipc.SendCopy(hwnd, j)
    }

    static FindAnchor() {
        return DllCall("FindWindowW", "ptr", 0, "wstr", "QuickNoteAnchor", "ptr")
    }

    ; ---- 小工具 -------------------------------------------------------------

    static Opt(m, key, def := "") => (IsObject(m) && m.Has(key)) ? m[key] : def
    static Has(m, key) => (IsObject(m) && m.Has(key)) ? 1 : 0

    static Num(m, key, def := 0) {
        v := Ipc.Opt(m, key, def)
        if IsNumber(v)
            return v
        try
            return Integer(v)
        catch
            return def
    }

    /* 纯文本 → 编辑区能直接显示的 HTML：只做转义和换行，**不解析 Markdown**。
       v1 的口径是"原样落进便签"，`**粗体**` 进去就该还是 `**粗体**`。
       将来要支持渲染，就在这里按 format 分支（把 body_md 交给页面 MD.render，
       body_html 留空即可 —— 那条路已经通了），下游不用动。 */
    static TextToHtml(text) {
        if (text = "")
            return ""
        t := StrReplace(text, "&", "&amp;")
        t := StrReplace(t, "<", "&lt;")
        t := StrReplace(t, ">", "&gt;")
        t := StrReplace(t, "`r`n", "`n")
        t := StrReplace(t, "`r", "`n")
        t := StrReplace(t, "`n", "<br>")
        return t
    }
}

; ---- 顶层包装：OnMessage 直接吃类静态方法引用会踩坑，统一走命名函数 --------
IpcOnWake(w, l, m, h) => Ipc.HandleWake(w, l, m, h)
IpcOnNew(w, l, m, h) => Ipc.HandleNew(w, l, m, h)
IpcOnList(w, l, m, h) => Ipc.HandleList(w, l, m, h)
IpcOnCopyData(w, l, m, h) => Ipc.HandleCopyData(w, l, m, h)
IpcDrain() => Ipc.Drain()
