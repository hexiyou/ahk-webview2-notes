#Requires AutoHotkey v2.0
; ============================================================================
;  pdf.ahk —— 把便签打成 PDF
;
;  不引外部依赖：WebView2 自带 Chromium 的排版/打印引擎（ICoreWebView2_7 的
;  PrintToPdfAsync），给个路径就直接出文件，没有打印对话框，也不用去模拟 Ctrl+P。
;
;  为什么不用「Microsoft Print to PDF」打印机：那要弹系统打印对话框、要选打印机、
;  还要等假脱机，无人值守根本没法用；而且它打的是窗口当前内容，不是"排好版的文档"。
;
;  流程：建一个屏幕外的隐藏窗口 + WebView2 → 载入 Export.Html(note) 写出的临时
;  文件 → 等 NavigationCompleted → 打印 → 删临时文件 → 下一张。
;
;  ★ 两个必须守住的点（都实测踩过）：
;    1) 绝对不能在 NavigationCompleted 回调里 await —— 文件都写出来了，Promise
;       却永远不回调，进程就卡在那儿。必须 SetTimer 退到独立线程再 await。
;    2) Chromium 默认纸张是 Letter（612×792pt），不显式设 A4 会怪；
;       ShouldPrintBackgrounds 默认关，不开的话代码块灰底、引用块全打不出来。
; ============================================================================

class Pdf {
    static Ctx := 0                 ; App.Ctx（dataDir / dllPath）
    static Jobs := []               ; [{note, path}]
    static Idx := 1
    static Ok := 0
    static Fail := 0
    static Done := 0                ; 全部结束后的回调 (ok, fail)
    static Win := 0                 ; { gui, wvc, wv }
    static Temp := ""
    static Printing := 0
    static Busy := 0

    /* ★ SetTimer / 事件回调要的是"可调用对象"，而 Pdf.Boot 这种写法在 AHK v2 里
       取不到静态方法的函数对象（会报 Invalid callback function）。ObjBindMethod
       每次调用都造一个新对象，直接传给 SetTimer 又可能注册出两个计时器，
       所以这里按名字缓存一份。 */
    static Fn(name) {
        static cache := Map()
        if !cache.Has(name)
            cache[name] := ObjBindMethod(Pdf, name)
        return cache[name]
    }

    ; A4 + 1.5cm 边距（单位英寸；1cm = 0.3937in）
    static PAGE_W := 8.27
    static PAGE_H := 11.69
    static MARGIN := 0.5906

    ; ---- 入口 ---------------------------------------------------------------

    static Save(note) {
        if !note
            return
        f := FileSelect("S", Export.FileStem(note) ".pdf"
            , "导出 PDF —— " note.title, "PDF 文档 (*.pdf)")
        if (f = "")
            return
        SplitPath f, , , &e
        if (StrLower(e) != "pdf")
            f .= ".pdf"
        Pdf.Start([{ note: note, path: f }])
    }

    static SaveMany(notes) {
        if !notes.Length
            return
        dir := FileSelect("D", A_Desktop, "批量导出 PDF —— 选一个文件夹")
        if (dir = "")
            return
        dir := RTrim(dir, "\")
        used := Map()
        jobs := []
        for n in notes
            jobs.Push({ note: n, path: Export.UniquePath(dir, Export.FileStem(n), "pdf", used) })
        Pdf.Start(jobs)
    }

    /* 统一入口。jobs 里每项是 {note, path}。
       真正干活的地方在 SetTimer 起的独立线程里 —— 建 WebView2 要 await，
       而 await 在这个进程里只有独立线程才跑得通。 */
    static Start(jobs, onDone := 0) {
        if Pdf.Busy {
            App.Toast("正在导出 PDF，请等这一批跑完")
            return
        }
        if !jobs.Length
            return
        Pdf.Jobs := jobs
        Pdf.Idx := 1
        Pdf.Ok := 0
        Pdf.Fail := 0
        Pdf.Done := onDone
        Pdf.Printing := 0
        Pdf.Busy := 1
        SetTimer(Pdf.Fn("Boot"), -1)
    }

    static Boot() {
        g := Gui("-Caption +ToolWindow +AlwaysOnTop", "QuickNote PDF")
        g.MarginX := 0
        g.MarginY := 0
        ; 屏幕外：够大够高就行，内容按 A4 排版，跟窗口尺寸没关系
        g.Show("x-32000 y-32000 w820 h1160 NoActivate")
        ctx := Pdf.Ctx
        try {
            wvc := WebView2.CreateControllerAsync(g.Hwnd, 0, ctx.dataDir
                , "", ctx.dllPath).await()
        } catch as e {
            App.Log("PDF 导出：建 WebView2 失败 " CleanComError(e.Message))
            try g.Destroy()
            Pdf.Busy := 0
            App.Toast("PDF 导出失败：WebView2 起不来")
            return
        }
        wv := wvc.CoreWebView2
        try wvc.DefaultBackgroundColor := 0xFFFFFFFF
        try wvc.Fill()
        try wvc.IsVisible := 1
        try {
            wv.Settings.AreDefaultContextMenusEnabled := 0
            wv.Settings.IsStatusBarEnabled := 0
            wv.Settings.AreDevToolsEnabled := 0
        }
        Pdf.Win := { gui: g, wvc: wvc, wv: wv }
        try wv.add_NavigationCompleted(Pdf.Fn("OnNav"))
        Pdf.Next()
    }

    ; ---- 状态机 -------------------------------------------------------------

    static Next() {
        if (Pdf.Idx > Pdf.Jobs.Length) {
            Pdf.Finish()
            return
        }
        job := Pdf.Jobs[Pdf.Idx]
        Pdf.Printing := 0
        Pdf.Temp := Pdf.WriteTemp(Export.Html(job.note))
        if (Pdf.Temp = "") {
            Pdf.StepFail("写临时文件失败")
            return
        }
        ; 9 秒还不来 NavigationCompleted 就当失败，别把整批卡死在这儿
        SetTimer(Pdf.Fn("NavTimeout"), -9000)
        try Pdf.Win.wv.Navigate(Pdf.FileUrl(Pdf.Temp))
        catch as e {
            App.Log("PDF 导出：导航失败 " CleanComError(e.Message))
            Pdf.StepFail("页面打不开")
        }
    }

    static OnNav(sender, args) {
        if (!Pdf.Busy || Pdf.Printing)
            return
        SetTimer(Pdf.Fn("NavTimeout"), 0)
        if !args.IsSuccess {
            ; 页面自己报错也会走到这儿（比如临时文件被删了）
            Pdf.StepFail("页面加载失败")
            return
        }
        Pdf.Printing := 1
        ; ★ 从这里退出去再打印：这个回调里 await 会永远等不到
        SetTimer(Pdf.Fn("DoPrint"), -30)
    }

    static NavTimeout() {
        if (!Pdf.Busy || Pdf.Printing)
            return
        App.Log("PDF 导出：页面加载超时")
        Pdf.StepFail("页面加载超时")
    }

    static DoPrint() {
        if (!Pdf.Busy || !Pdf.Win)
            return
        job := Pdf.Jobs[Pdf.Idx]
        wv := Pdf.Win.wv
        ps := 0
        try ps := wv.Environment.CreatePrintSettings()
        if ps {
            try {
                ps.PageWidth := Pdf.PAGE_W
                ps.PageHeight := Pdf.PAGE_H
                ps.MarginTop := Pdf.MARGIN
                ps.MarginBottom := Pdf.MARGIN
                ps.MarginLeft := Pdf.MARGIN
                ps.MarginRight := Pdf.MARGIN
                ps.ShouldPrintBackgrounds := 1      ; 不写这个，代码块灰底全没
                ps.ShouldPrintHeaderAndFooter := 0
            }
        }
        p := 0
        try {
            p := ps ? wv.PrintToPdfAsync(job.path, ps) : wv.PrintToPdfAsync(job.path, 0)
        } catch as e {
            App.Log("PDF 导出：PrintToPdf 调用失败 " CleanComError(e.Message))
            Pdf.StepFail("打印调用失败")
            return
        }
        ; ps 是 WebView2.Base 的子类，__Delete 里自己会 ObjRelease，别再手动放一次

        ok := 0
        try ok := p.await()                     ; 1 = 成功
        catch as e {
            App.Log("PDF 导出：等待打印结果异常 " CleanComError(e.Message))
        }
        size := 0
        try size := FileExist(job.path) ? FileGetSize(job.path) : 0
        if (ok = 1 && size > 800) {
            Pdf.Ok += 1
        } else {
            Pdf.Fail += 1
            App.Log("PDF 导出失败：" job.path "（返回值 " ok "，大小 " size "）")
        }
        Pdf.CleanTemp()
        Pdf.Idx += 1
        Pdf.Next()
    }

    static StepFail(msg) {
        Pdf.Fail += 1
        App.Log("PDF 导出跳过一张：" msg)
        Pdf.CleanTemp()
        Pdf.Idx += 1
        Pdf.Next()
    }

    static Finish() {
        SetTimer(Pdf.Fn("NavTimeout"), 0)
        Pdf.CleanTemp()
        Pdf.CloseWin()
        ok := Pdf.Ok, fail := Pdf.Fail
        Pdf.Busy := 0
        cb := Pdf.Done
        Pdf.Done := 0
        if (cb)
            cb(ok, fail)
        if (fail)
            App.Toast("PDF 导出：" ok " 张成功，" fail " 张失败（详见 app.log）")
        else if ok
            App.Toast("已导出 " ok " 张 PDF")
    }

    static CloseWin() {
        if !Pdf.Win
            return
        w := Pdf.Win
        Pdf.Win := 0
        ; ★ 先关 controller 再销毁 Gui：反过来的话 WebView2 会对一个已经没了的
        ;   hwnd 做清理，偶尔留下一个空壳进程。Close 不保证存在（老接口），包 try。
        try w.wvc.Close()
        try w.gui.Destroy()
    }

    ; ---- 小工具 -------------------------------------------------------------

    static WriteTemp(html) {
        p := A_Temp "\qn-pdf-" A_TickCount "-" Random(100, 999) ".html"
        try {
            f := FileOpen(p, "w", "UTF-8")
            f.Write(html)
            f.Close()
        } catch {
            return ""
        }
        return p
    }

    static CleanTemp() {
        if (Pdf.Temp = "")
            return
        try FileDelete Pdf.Temp
        Pdf.Temp := ""
    }

    static FileUrl(p) {
        return "file:///" StrReplace(StrReplace(p, "\", "/"), " ", "%20")
    }
}
