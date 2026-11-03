#Requires AutoHotkey v2.0
; ============================================================================
;  word.ahk —— 导出 Word（.docx）
;
;  路线：复用 HTML 导出 → 交给本机的 Microsoft Word 打开 → 收拾两处它自己的
;  毛病（图片挂成外链、<pre> 的背景被吃掉）→ SaveAs2 存成 docx。
;
;  ★ 为什么另起一个进程：Word 的 OLE 自动化一旦卡在它自己的模态框上（"文档恢复"、
;    首次运行的欢迎页、许可证提示…），调用的那一方会一直等。AHK 的 UI 是单线程，
;    在进程内调 Word 等于把**桌面上所有便签一起冻住**。所以真正碰 Word 的活儿
;    全部丢给子进程（--word-export），主进程只负责起进程、轮询退出、超时兜底。
;
;  ★ 为什么不用纯 AHK 写 OOXML：那是 500~700 行（自写 zip + CRC32 + document.xml
;    + 图片关系 + 编号 + 逐 run 着色），而且富文本映射会一直打补丁。这台机器上
;    Word 是现成的，用它是性价比最高的做法。没装 Office 的机器上会明确报错，
;    不会崩。
; ============================================================================

class Word {
    static Pending := 0             ; { pid, tmp, result, t0 }

    /* 同上：SetTimer 不接受未绑定的静态方法引用，绑定对象按名字缓存一份 */
    static Fn(name) {
        static cache := Map()
        if !cache.Has(name)
            cache[name] := ObjBindMethod(Word, name)
        return cache[name]
    }
    static TIMEOUT := 180000        ; 3 分钟（批量导出几十张也要够）

    ; ---- 环境判断 -----------------------------------------------------------

    /* Word 装没装。看注册表比"试着 ComObject 一下"轻，也不会因为 COM 注册残缺
       卡住；HKCR 是 HKCU/HKLM 的合并视图，读它最省事。 */
    static Available() {
        for key in ["HKCR\Word.Application\CLSID"
            , "HKCU\Software\Classes\Word.Application\CLSID"
            , "HKLM\SOFTWARE\Classes\Word.Application\CLSID"] {
            try {
                if RegRead(key)
                    return true
            }
        }
        return false
    }

    ; ---- 入口 ---------------------------------------------------------------

    static Save(note) {
        if !note
            return
        if !Word.Available() {
            App.Toast("这台机器上没找到 Microsoft Word，导出 Word 需要先装 Office")
            return
        }
        f := FileSelect("S", Export.FileStem(note) ".docx"
            , "导出 Word —— " note.title, "Word 文档 (*.docx)")
        if (f = "")
            return
        SplitPath f, , , &e
        if (StrLower(e) != "docx")
            f .= ".docx"
        Word.Start([{ note: note, path: f }])
    }

    static SaveMany(notes) {
        if !notes.Length
            return
        if !Word.Available() {
            App.Toast("这台机器上没找到 Microsoft Word，导出 Word 需要先装 Office")
            return
        }
        dir := FileSelect("D", A_Desktop, "批量导出 Word —— 选一个文件夹")
        if (dir = "")
            return
        dir := RTrim(dir, "\")
        used := Map()
        jobs := []
        for n in notes
            jobs.Push({ note: n, path: Export.UniquePath(dir, Export.FileStem(n), "docx", used) })
        Word.Start(jobs)
    }

    /* 主进程这边：把所有便签先写成 HTML（图片保留 file:// 引用，Word 不认 data URI），
       再写一份清单，起子进程去挨个转换。整个过程都在后台，便签窗口照常能用。 */
    static Start(jobs) {
        if Word.Pending {
            App.Toast("上一批 Word 导出还没结束")
            return
        }
        tmp := A_Temp "\qn-word-" A_TickCount
        try DirCreate tmp
        catch {
            App.Toast("Word 导出失败：临时目录建不出来")
            return
        }
        manifest := tmp "\jobs.tsv"
        lines := ""
        for i, j in jobs {
            htmlPath := tmp "\" i ".html"
            try Word.WriteUtf8(htmlPath, Export.HtmlForWord(j.note))
            catch as e {
                App.Log("Word 导出：写 HTML 失败 " CleanComError(e.Message))
                continue
            }
            lines .= htmlPath "`t" j.path "`n"
        }
        if (lines = "") {
            try DirDelete tmp, true
            App.Toast("Word 导出失败：没有可转换的内容")
            return
        }
        try FileAppend lines, manifest, "UTF-8-RAW"
        catch {
            try DirDelete tmp, true
            App.Toast("Word 导出失败：清单写不出来")
            return
        }

        result := tmp "\result.txt"
        cmd := Word.CmdLine() ' --word-export "' manifest '" --result "' result '"'
        /* ★ 这个版本的 AHK v2 里 Run() 的返回值是空串（老版本才返回 PID），
           PID 必须用输出参数取，否则 ProcessExist("") 恒为 0 —— 表现是
           "刚起进程就判定它已退出"，导出永远失败。 */
        pid := 0
        try Run(cmd, , "Hide", &pid)
        catch as e {
            App.Log("Word 导出：起子进程失败 " CleanComError(e.Message))
            try DirDelete tmp, true
            App.Toast("Word 导出失败：后台进程起不来")
            return
        }
        Word.Pending := { pid: pid, tmp: tmp, result: result, t0: A_TickCount }
        App.Log("Word 导出：子进程 pid=" pid "，共 " jobs.Length " 个")
        App.Toast("正在用 Word 生成 " jobs.Length " 个文档…")
        SetTimer(Word.Fn("Poll"), 300)
    }

    static Poll() {
        p := Word.Pending
        if !p {
            SetTimer(Word.Fn("Poll"), 0)
            return
        }
        if ProcessExist(p.pid) {
            if (A_TickCount - p.t0 > Word.TIMEOUT) {
                try ProcessClose p.pid
                Word.Close("Word 导出超时，已中止（Word 可能卡在某个对话框上）")
            }
            return
        }
        Word.Close("")
    }

    static Close(err) {
        SetTimer(Word.Fn("Poll"), 0)
        p := Word.Pending
        Word.Pending := 0
        if !p
            return
        res := ""
        try res := FileRead(p.result, "UTF-8")
        ok := 0, fail := 0, msg := ""
        if RegExMatch(res, "ok=(\d+)", &m1)
            ok := m1[1] + 0
        if RegExMatch(res, "fail=(\d+)", &m2)
            fail := m2[1] + 0
        if RegExMatch(res, "err=(.*)", &m3)
            msg := Trim(m3[1])
        try DirDelete p.tmp, true

        if (err != "") {
            App.Toast(err)
            return
        }
        if (ok = 0 && fail = 0) {
            App.Log("Word 导出：子进程没留下结果（可能崩了）")
            App.Toast("Word 导出失败：后台进程异常退出，详见 app.log")
            return
        }
        if (fail > 0)
            App.Toast("Word 导出：" ok " 个成功，" fail " 个失败" (msg != "" ? "（" msg "）" : ""))
        else
            App.Toast("已导出 " ok " 个 Word 文档")
    }

    ; ---- 子进程侧 -----------------------------------------------------------

    /* 跑在 --word-export 的独立进程里。返回进程退出码：
       0 全成功 / 2 没装 Word / 3 Word 起不来 / 4 有失败。 */
    static ExportManifest(manifest, resultPath) {
        if !Word.Available() {
            Word.WriteUtf8(resultPath, "ok=0`nfail=0`nerr=这台机器上没装 Microsoft Word`n")
            return 2
        }
        app := 0
        try app := ComObject("Word.Application")
        catch as e {
            Word.WriteUtf8(resultPath
                , "ok=0`nfail=0`nerr=启动 Word 失败：" CleanComError(e.Message) "`n")
            return 3
        }
        try app.Visible := false
        try app.DisplayAlerts := 0
        try app.AutomationSecurity := 3        ; msoAutomationSecurityForceDisable，不跑宏
        try app.ScreenUpdating := false

        ok := 0, fail := 0, errs := ""
        text := ""
        try text := FileRead(manifest, "UTF-8")
        catch as e {
            try app.Quit()
            Word.WriteUtf8(resultPath, "ok=0`nfail=0`nerr=读清单失败：" CleanComError(e.Message) "`n")
            return 4
        }
        for line in StrSplit(StrReplace(text, "`r", ""), "`n") {
            if (Trim(line) = "")
                continue
            parts := StrSplit(line, "`t")
            if (parts.Length < 2) {
                fail += 1
                continue
            }
            htmlPath := parts[1], outPath := parts[2]
            doc := 0
            try {
                doc := app.Documents.Open(htmlPath, false, true)   ; 不确认转换、只读
                Word.FixDoc(doc)
                doc.SaveAs2(outPath, 16)                          ; wdFormatXMLDocument
                doc.Close(false)
                ok += 1
            } catch as e {
                fail += 1
                errs .= CleanComError(e.Message) "；"
                if doc
                    try doc.Close(false)
            }
        }
        try app.Quit()
        Word.WriteUtf8(resultPath
            , "ok=" ok "`nfail=" fail "`nerr=" StrReplace(errs, "`n", " ") "`n")
        return fail ? 4 : 0
    }

    /* 收拾 Word 从 HTML 导入时留下的两个坑：

       1) 图片一律存成 file:// 外链（TargetMode="External"，docx 里没有 media），
          发给别人一打开就是裂图。BreakLink 会把图真正嵌进文档 —— 实测之后
          word/media/image1.png 才出现，大小和原图一致。
       2) <pre> 的背景色不会导入（document.xml 里 w:shd 一个都没有），
          代码块变成一片白。按等宽字体把段落找出来补一层底纹。
       顺带把页边距设成 1.5cm，和 PDF 那边保持一致。 */
    static FixDoc(doc) {
        try {
            doc.PageSetup.TopMargin := 42.5      ; 1.5cm = 42.52pt
            doc.PageSetup.BottomMargin := 42.5
            doc.PageSetup.LeftMargin := 42.5
            doc.PageSetup.RightMargin := 42.5
        }
        ; 1) 图片断链
        try {
            n := doc.InlineShapes.Count
            Loop n {
                try {
                    s := doc.InlineShapes.Item(A_Index)
                    s.LinkFormat.SavePictureWithDocument := true
                    s.LinkFormat.BreakLink()
                }
            }
        }
        ; 2) 代码块底纹
        /* ★ 用 Item(i) 逐段取，别写 `for p in doc.Paragraphs`：
           Word 的集合走 IEnumVARIANT，AHK 这边枚举时偶发卡死（实测整个进程
           挂在那儿，连日志都不写了）。按下标取既稳又快。 */
        try {
            cnt := doc.Paragraphs.Count
            Loop cnt {
                try {
                    p := doc.Paragraphs.Item(A_Index)
                    if Word.IsCodePara(p)
                        p.Shading.BackgroundPatternColor := 0xE5EDF0   ; #F0EDE5 的 BGR
                }
            }
        }
    }

    static IsCodePara(p) {
        name := ""
        try name := p.Range.Font.Name
        if (name = "") {
            ; 混排段落 Font.Name 会是空串，退回看样式名
            try name := p.Style.NameLocal
        }
        if InStr(name, "Consolas") || InStr(name, "Courier") || InStr(name, "Cascadia")
            return true
        style := ""
        try style := p.Style.NameLocal
        return InStr(style, "预设格式") || InStr(style, "Preformatted")
    }

    ; ---- 小工具 -------------------------------------------------------------

    /* 子进程命令行。编译成 exe 之后 A_AhkPath 是空的，得直接用 exe 自己。 */
    static CmdLine() {
        if A_IsCompiled
            return '"' A_ScriptFullPath '"'
        return '"' A_AhkPath '" "' A_ScriptFullPath '"'
    }

    /* 写 UTF-8 带 BOM：Word 认 BOM，没有 BOM 的 HTML 它偶尔会按 ANSI 猜，
       中文变乱码。 */
    static WriteUtf8(path, text) {
        f := FileOpen(path, "w", "UTF-8")
        try f.Write(text)
        finally f.Close()
    }
}
