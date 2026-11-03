#Requires AutoHotkey v2.0
; ============================================================================
;  export.ahk —— 单张便签导出（TXT / Markdown / HTML / RTF）
;
;  为什么不写在 note-window 里：转换逻辑跟窗口没关系，放这儿能被自检直接调。
;  PDF 和 Word 不在这里：它们要建窗口 / 起 Word，副作用太大，各自一个模块
;  （lib\pdf.ahk、lib\word.ahk），由 App.ExportNote 转发。
;
;  四种格式的来源各不一样，别图省事都从 body_html 转：
;    TXT   ← body_text（已经是纯文本，正文里的富文本标记天然被过滤掉）
;    MD    ← body_md（正本）
;    HTML  ← body_html（正本），图片就地转成 data URI，导出的单个文件能单独看
;    RTF   ← body_md 解析（Markdown 是按行组织的，比从 HTML 里抠格式稳得多）
;
;  注意 AC：RTF 里所有非 ASCII 字符都要写成 \uNNNN? 转义，字体表也指定了中文字体，
;  否则 Word 打开是乱码。
;
;  ★ 图片：RTF 用 \pict\pngblip 直接内嵌（早年这里是 [图片] 占位符，用户反馈
;    导出后图全没了）；HTML 用 data URI。两条路都先过 PrepImage —— 大图先缩，
;    否则一张 20MB 的截图会让 RTF 变成 40MB（十六进制要翻倍）。
; ============================================================================

#Include clip.ahk       ; 借它的 GdipStart（include-once，重复带无害）

class Export {
    /* 大图先缩再嵌的门槛。图片在便签里最大也就 180px 高，导出时保留原图
       只是为了让"另存为"能留住细节；超过这个尺寸的图属于截图/相机原片，
       对便签来说是浪费 —— RTF 的十六进制还要再翻一倍。 */
    static IMG_BIG_BYTES := 4 * 1024 * 1024
    static IMG_BIG_PX := 3200
    static IMG_TARGET_PX := 1600
    ; ---- 对外入口 -----------------------------------------------------------

    static Save(note, fmt) {
        if !note
            return
        ext := fmt
        ; 注意：这个版本的 FileSelect 只接受 4 个参数（没有 DefaultExtension），
        ; 扩展名自己补，见下面 SplitPath 那一段
        f := FileSelect("S", Export.FileStem(note) "." ext
            , "导出便签 —— " note.title, Export.Filter(ext))
        if (f = "")
            return
        SplitPath f, , , &e
        if (StrLower(e) != ext)
            f .= "." ext
        try text := Export.Render(note, ext)
        catch as e {
            App.Toast("导出失败：" CleanComError(e.Message))
            return
        }
        try {
            ; TXT / MD / HTML 写 UTF-8 带 BOM：记事本、VS Code、浏览器都能正确认中文；
            ; RTF 内容全是 ASCII（中文已转义），写不写 BOM 都一样，按 UTF-8-RAW 来
            Export.WriteTo(f, ext, text)
        } catch as e {
            App.Toast("写文件失败：" CleanComError(e.Message))
            return
        }
        App.Toast("已导出 " StrUpper(ext) "：" f)
    }

    /* 批量导出：先选一个文件夹，再逐张写。
       ★ 不去逐张弹"另存为"——十张便签就是十个对话框，中途取消还会留下
         一半文件。选一次目录，剩下的交给代码。
       ★ 同名要加序号：便签标题重复很常见（"（无标题）"更是），
         直接覆盖的话"导出十张只剩一张"。 */
    static SaveMany(notes, fmt) {
        if !notes.Length
            return
        dir := FileSelect("D", A_Desktop, "批量导出 " StrUpper(fmt) " —— 选一个文件夹")
        if (dir = "")
            return
        dir := RTrim(dir, "\")
        used := Map()
        ok := 0, fail := 0
        for n in notes {
            path := Export.UniquePath(dir, Export.FileStem(n), fmt, used)
            try {
                Export.WriteTo(path, fmt, Export.Render(n, fmt))
                ok += 1
            } catch as e {
                fail += 1
                App.Log("批量导出失败：id=" n.id " / " CleanComError(e.Message))
            }
        }
        if (fail)
            App.Toast("导出完成：" ok " 张成功，" fail " 张失败（" dir "）")
        else
            App.Toast("已导出 " ok " 张到 " dir)
    }

    /* 给 dir 挑一个不撞名的文件路径。used 是本批已经用掉的（键是转小写的
       文件名）—— Windows 文件系统大小写不敏感，"Note.md" 和 "note.md" 是
       同一个文件，不转小写就会互相覆盖。
       目标目录里已经存在同名文件时也往后排：批量导出是"多出几份"，
       不该悄悄吃掉别人上次导出的东西。 */
    static UniquePath(dir, stem, fmt, used) {
        name := stem "." fmt
        i := 2
        while (used.Has(StrLower(name)) || FileExist(dir "\" name)) {
            name := stem " (" i ")." fmt
            i += 1
        }
        used[StrLower(name)] := 1
        return dir "\" name
    }

    ; 统一写盘入口：编码只在这一处决定
    static WriteTo(path, fmt, text) {
        enc := (fmt = "rtf") ? "UTF-8-RAW" : "UTF-8"
        fh := FileOpen(path, "w", enc)
        try fh.Write(text)
        finally fh.Close()
    }

    static Render(note, fmt) {
        switch fmt {
            case "txt": return Export.Txt(note)
            case "md": return Export.Md(note)
            case "html": return Export.Html(note)
            case "rtf": return Export.Rtf(note)
        }
        throw Error("不认识的格式：" fmt)
    }

    static Filter(fmt) {
        switch fmt {
            case "txt": return "纯文本 (*.txt)"
            case "md": return "Markdown (*.md)"
            case "html": return "网页 (*.html)"
            case "rtf": return "RTF 文档 (*.rtf)"
        }
        return "所有文件 (*.*)"
    }

    /* 文件名：标题里可能有 \ / : * ? " < > |，Windows 上直接非法。
       截到 60 字，空标题退回"便签"。 */
    static FileStem(note) {
        t := note.title
        if (Trim(t) = "")
            t := "便签"
        t := RegExReplace(t, '[\\/:*?"<>|]', "_")
        t := RegExReplace(t, "\s+", " ")
        t := Trim(t)
        if (StrLen(t) > 60)
            t := SubStr(t, 1, 60)
        return t = "" ? "便签" : t
    }

    ; ---- 四种格式 -----------------------------------------------------------

    static Txt(note) {
        return note.body_text
    }

    static Md(note) {
        return note.body_md
    }

    /* 自包含 HTML：图片一律内嵌成 data URI，导出的文件单独发给别人也能看。
       代价是文件变大（base64 约 4/3 倍），但便签里的图本来就不多。

       inlineImages := false 是给 Word 用的：Word 的 HTML 导入**不认 data URI**
       （那些图会直接消失），但认得 file:/// 本地路径 —— 它会把图挂成外链，
       再由 word.ahk 里的 BreakLink 变成真正内嵌。 */
    static Html(note, inlineImages := true) {
        body := note.body_html
        if (Trim(body) = "") {
            ; 只在 body_html 空而 md 有内容时兜底（正常保存流程两者都有）
            body := "<pre>" Export.HtmlEsc(note.body_md) "</pre>"
        }
        if inlineImages
            body := Export.InlineImages(body)

        title := note.title != "" ? note.title : "便签"
        css := ""
        css .= "body{margin:0;padding:2.2em 2em;background:#faf6e8;color:#3a3226;"
        css .= "font:16px/1.7 'Microsoft YaHei',system-ui,sans-serif;}"
        css .= "article{max-width:46em;margin:0 auto;}"
        css .= "h1,h2,h3{line-height:1.35;}"
        css .= "img{max-width:100%;height:auto;border-radius:6px;}"
        css .= "pre{background:rgba(0,0,0,.05);padding:.7em .9em;border-radius:6px;overflow:auto;}"
        css .= "code{font-family:Consolas,'Cascadia Mono',monospace;font-size:.94em;}"
        css .= "blockquote{margin:.6em 0;padding-left:.8em;border-left:3px solid rgba(0,0,0,.18);color:#57503f;}"
        css .= "hr{border:0;border-top:1px solid rgba(0,0,0,.15);margin:1.2em 0;}"
        css .= ".task-line{display:flex;align-items:flex-start;gap:.4em;margin:.2em 0;}"
        css .= ".chk{width:1.05em;height:1.05em;border:1.5px solid rgba(0,0,0,.38);"
        css .= "border-radius:4px;margin-top:.3em;flex:0 0 auto;}"
        css .= ".task-line[data-done='1'] .task-text{text-decoration:line-through;opacity:.6;}"
        /* 代码着色：导出页要把界面上看到的高亮一起带上，否则"我在便签里看到的
           明明是彩色的，导出来一片黑"这种事会一直被人投诉。
           色板直接读 ui\vendor 里那份主题（和界面共用一份，改一处两边都对），
           读不到就退回内置的紧凑版。 */
        css .= Export.HljsCss()
        css .= "@media print{body{background:#fff;}}"

        return "<!DOCTYPE html>`r`n"
            . "<html lang=`"zh-CN`">`r`n<head>`r`n"
            . "<meta charset=`"utf-8`">`r`n"
            . "<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">`r`n"
            . "<title>" Export.HtmlEsc(title) "</title>`r`n"
            . "<style>" css "</style>`r`n"
            . "</head>`r`n<body>`r`n<article>`r`n"
            . body
            . "`r`n</article>`r`n</body>`r`n</html>`r`n"
    }

    /* 给 Word 用的 HTML：图片留着 file://（Word 不认 data URI），并且把代码着色
       的 class 全部翻成内联 style。

       ★ 为什么必须翻：Word 的 HTML 导入只认**标签选择器**和**内联 style**，
         完全不认 class 选择器 —— 实测同一份 `<span class="hljs-keyword">` 经
         `style="color:#d73a49"` 才会变成彩色的 run，走 class 则是纯黑。
         颜色值就是 HljsCssFallback 那套，两边保持一致。 */
    static HtmlForWord(note) {
        html := Export.Html(note, false)
        m := Map(
            "keyword", "#d73a49", "doctag", "#d73a49", "type", "#d73a49",
            "selector-tag", "#d73a49", "built_in", "#d73a49",
            "string", "#032f62", "attr", "#032f62", "template-tag", "#032f62",
            "regexp", "#032f62",
            "title", "#6f42c1", "number", "#005cc5", "literal", "#005cc5",
            "symbol", "#005cc5", "bullet", "#005cc5",
            "comment", "#6a737d", "quote", "#6a737d", "meta", "#6a737d",
            "name", "#22863a", "tag", "#22863a", "selector-id", "#22863a",
            "selector-class", "#22863a",
            "variable", "#e36209", "params", "#e36209", "property", "#e36209")
        for tok, color in m {
            style := "color:" color
            if (tok = "comment" || tok = "quote")
                style .= ";font-style:italic"
            ; [^"]* 兜住 `class="hljs-title function_"` 这种一个元素挂两个类的情况
            html := RegExReplace(html, 'class="hljs-' tok '[^"]*"', 'style="' style '"')
        }
        return html
    }

    /* 代码着色的色板。界面和导出用同一份 CSS（ui\vendor\highlight-github.css），
       免得两边颜色慢慢跑偏。程序是单机便签，断网是常态，所以不能引 CDN。 */
    static HljsCss() {
        static cached := ""
        if (cached != "")
            return cached
        txt := ""
        try txt := FileRead(A_ScriptDir "\ui\vendor\highlight-github.css", "UTF-8")
        catch
            txt := ""
        if (Trim(txt) = "")
            txt := Export.HljsCssFallback()
        ; 主题自带的 .hljs 背景是纯白；导出页底色是浅米色，白底会像贴了块膏药
        txt := StrReplace(txt, "background:#fff", "background:transparent")
        txt := StrReplace(txt, "background: #fff", "background:transparent")
        ; 主题里给 code 留了 padding，导出页的 pre 已经有了，去掉免得双份
        txt := "pre code.hljs{display:block;padding:0;background:transparent}"
            . "code.hljs{padding:0;background:transparent}" txt
        cached := txt
        return cached
    }

    /* vendor 文件被删/没打包时的兜底：只保留最常用的几类 token。
       宁可颜色少一点，也不能让导出的 HTML 一片黑。 */
    static HljsCssFallback() {
        return ".hljs{color:#24292e}"
            . ".hljs-keyword,.hljs-doctag,.hljs-type,.hljs-selector-tag,.hljs-built_in{color:#d73a49}"
            . ".hljs-string,.hljs-attr,.hljs-template-tag,.hljs-regexp{color:#032f62}"
            . ".hljs-title,.hljs-title.function_,.hljs-title.class_{color:#6f42c1}"
            . ".hljs-number,.hljs-literal,.hljs-symbol,.hljs-bullet{color:#005cc5}"
            . ".hljs-comment,.hljs-quote,.hljs-meta{color:#6a737d;font-style:italic}"
            . ".hljs-name,.hljs-tag,.hljs-selector-id,.hljs-selector-class{color:#22863a}"
            . ".hljs-variable,.hljs-params,.hljs-property{color:#e36209}"
    }

    static HtmlEsc(s) {
        s := StrReplace(s, "&", "&amp;")
        s := StrReplace(s, "<", "&lt;")
        s := StrReplace(s, ">", "&gt;")
        return s
    }

    /* 图片内嵌：只处理 src="file:///..."，其它（http 外链）原样留着。
       注意不能用 RegExReplace 的回调形式 —— AHK 2.0 的第三个参数只接受字符串
       （传函数对象会报 "requires a String, but received a Func"），
       只能自己扫一遍 MatchCollection 再拼。 */
    static InlineImages(html) {
        out := ""
        pos := 1
        while RegExMatch(html, 'i)src="(file:///[^"]+)"', &m, pos) {
            out .= SubStr(html, pos, m.Pos - pos)
            data := Export.ReadBase64(Export.UrlToPath(m[1]))
            out .= data = "" ? m[0] : "src=`"" data "`""
            pos := m.Pos + m.Len
        }
        out .= SubStr(html, pos)
        return out
    }

    static UrlToPath(url) {
        p := RegExReplace(url, "^file:///", "")
        p := StrReplace(p, "/", "\")
        return Export.UrlDecode(p)
    }

    static UrlDecode(s) {
        ; 只处理 %XX，够用（文件名里的空格、中文都是这种形式）
        while RegExMatch(s, "%([0-9A-Fa-f]{2})", &m) {
            try s := StrReplace(s, m[0], Chr(Integer("0x" m[1])), , 1)
            catch
                break
        }
        return s
    }

    static ReadBase64(path) {
        p := Export.PrepImage(path)
        if !p
            return ""
        return "data:" Export.Mime(p.kind) ";base64," Export.B64Of(p.buf, p.size)
    }

    /* 原始字节 -> base64。CRYPT_STRING_BASE64 = 1，两遍调用：先问长度再真转。
       ★ 必须再或上 CRYPT_STRING_NOCRLF（0x40000000）：这个 API 默认每 64 个字符
         插一个 CRLF，塞进 data URI 里虽然浏览器能忍，但等于凭空多出一堆换行，
         导出文件也被撑大。 */
    static B64Of(buf, size) {
        flags := 1 | 0x40000000
        chars := 0
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", flags, "ptr", 0, "uint*", &chars)
            return ""
        if (chars = 0)
            return ""
        out := Buffer(chars * 2 + 4, 0)
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", flags, "ptr", out, "uint*", &chars)
            return ""
        return StrGet(out, "UTF-16")
    }

    /* 原始字节 -> 十六进制（RTF 的 \pict 要用）。CRYPT_STRING_HEXRAW = 0xC：
       AHK 里逐字节拼 hex 在 5MB 的图上要跑好几秒，这个 API 是 C 实现的。 */
    static HexOf(buf, size) {
        chars := 0
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", 0xC, "ptr", 0, "uint*", &chars)
            return ""
        if (chars = 0)
            return ""
        out := Buffer(chars * 2 + 4, 0)
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", 0xC, "ptr", out, "uint*", &chars)
            return ""
        /* ★ 实测：这个调用会带一个尾巴 CRLF（70 字节的图转出来 142 字符而不是
           140）。不剪掉的话，\pict 的十六进制和右花括号之间就夹了一对换行，
           Word 打开直接报"RTF 格式错误"。 */
        return Trim(StrGet(out, "UTF-16"), " `t`r`n")
    }

    /* ---- 图片准备：读字节，必要时先缩小 --------------------------------
       返回 { buf, size, w, h, kind }：
         kind 只会是 "png" / "jpeg" —— RTF 的 \pict 只认这两种 blip，
         HTML 的 data URI 也只声明这两种（GIF/BMP 一律先转成 PNG）。
       失败返回 0，调用方退化成占位文字。 */
    static PrepImage(path) {
        if !FileExist(path)
            return 0
        size := 0
        try size := FileGetSize(path)
        if (size <= 0)
            return 0

        info := Export.ImgSize(path)
        needConv := !info || (info.kind != "png" && info.kind != "jpeg")
        big := (size > Export.IMG_BIG_BYTES) || (info && info.w > Export.IMG_BIG_PX)

        if (needConv || big) {
            tmp := Export.GdipPng(path, big ? Export.IMG_TARGET_PX : 0)
            if (tmp != "") {
                out := Export.ReadRaw(tmp)
                try FileDelete tmp
                if out
                    return out
                return 0
            }
            ; 转不出来（WebP / 文件损坏）：原图能读就原样用，至少别丢
            if !needConv && info
                return Export.ReadRaw(path)
            return 0
        }
        return Export.ReadRaw(path)
    }

    static ReadRaw(path) {
        size := 0
        try size := FileGetSize(path)
        if (size <= 0)
            return 0
        buf := ""
        try {
            f := FileOpen(path, "r")
            buf := Buffer(size)
            f.RawRead(buf, size)
            f.Close()
        } catch {
            return 0
        }
        info := Export.ImgSize(path)
        w := info ? info.w : 0
        h := info ? info.h : 0
        kind := info ? info.kind : "png"
        if (kind != "png" && kind != "jpeg")
            kind := "png"
        return { buf: buf, size: size, w: w, h: h, kind: kind }
    }

    /* 从文件头读像素尺寸。只读前 256KB —— JPEG 的 SOF 段通常就在前面，
       没必要为了一张 20MB 的图把它整个读进内存。 */
    static ImgSize(path) {
        head := ""
        try {
            f := FileOpen(path, "r")
            n := f.Length < 262144 ? f.Length : 262144
            buf := Buffer(n, 0)
            f.RawRead(buf, n)
            f.Close()
            head := buf
        } catch {
            return 0
        }
        b0 := NumGet(head, 0, "uchar"), b1 := NumGet(head, 1, "uchar")
        b2 := NumGet(head, 2, "uchar"), b3 := NumGet(head, 3, "uchar")

        ; PNG：8 字节签名 + 4 字节长度 + "IHDR" + 宽高（大端）
        if (b0 = 0x89 && b1 = 0x50 && b2 = 0x4E && b3 = 0x47)
            return { kind: "png", w: Export.BE32(head, 16), h: Export.BE32(head, 20) }
        ; JPEG：扫 SOF0..SOF3 / SOF5..SOF15 段
        if (b0 = 0xFF && b1 = 0xD8) {
            off := 2
            while (off + 9 < 262144) {
                if (NumGet(head, off, "uchar") != 0xFF) {
                    off += 1
                    continue
                }
                marker := NumGet(head, off + 1, "uchar")
                if (marker = 0xFF) {
                    off += 1
                    continue
                }
                if (marker = 0xD8 || marker = 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
                    off += 2
                    continue
                }
                len := (NumGet(head, off + 2, "uchar") << 8) | NumGet(head, off + 3, "uchar")
                isSOF := (marker >= 0xC0 && marker <= 0xCF)
                    && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
                if isSOF {
                    h := (NumGet(head, off + 5, "uchar") << 8) | NumGet(head, off + 6, "uchar")
                    w := (NumGet(head, off + 7, "uchar") << 8) | NumGet(head, off + 8, "uchar")
                    return { kind: "jpeg", w: w, h: h }
                }
                if (len < 2)
                    break
                off += 2 + len
            }
            return { kind: "jpeg", w: 0, h: 0 }
        }
        ; GIF：6 字节头 + 逻辑屏宽高（小端）
        if (b0 = 0x47 && b1 = 0x49 && b2 = 0x46)
            return { kind: "gif", w: NumGet(head, 6, "ushort"), h: NumGet(head, 8, "ushort") }
        ; BMP：BITMAPINFOHEADER 的宽高（小端，可能有符号）
        if (b0 = 0x42 && b1 = 0x4D)
            return { kind: "bmp", w: Abs(NumGet(head, 18, "int")), h: Abs(NumGet(head, 22, "int")) }
        return 0
    }

    static BE32(buf, off) {
        return (NumGet(buf, off, "uchar") << 24) | (NumGet(buf, off + 1, "uchar") << 16)
            | (NumGet(buf, off + 2, "uchar") << 8) | NumGet(buf, off + 3, "uchar")
    }

    /* 用 GDI+ 把图转成 PNG 落一个临时文件，顺手可以缩到 targetW 宽（0 = 不缩）。
       返回临时文件路径，失败返回空串。
       ★ 必须先 GdiplusStartup，否则 GdipCreateBitmapFromFile 直接返回 1。 */
    static GdipPng(path, targetW := 0) {
        if !Clip.GdipStart()
            return ""
        pBitmap := 0
        if (DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", path, "ptr*", &pBitmap) != 0 || !pBitmap)
            return ""
        w := 0, h := 0
        DllCall("gdiplus\GdipGetImageWidth", "ptr", pBitmap, "uint*", &w)
        DllCall("gdiplus\GdipGetImageHeight", "ptr", pBitmap, "uint*", &h)
        if (w <= 0 || h <= 0) {
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
            return ""
        }

        src := pBitmap
        pScaled := 0
        if (targetW > 0 && w > targetW) {
            nh := Max(1, Round(h * targetW / w))
            ; PixelFormat32bppARGB = 0x26200A
            if (DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", targetW, "int", nh
                , "int", 0, "uint", 0x26200A, "ptr", 0, "ptr*", &pScaled) = 0 && pScaled) {
                g := 0
                if (DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pScaled, "ptr*", &g) = 0 && g) {
                    ; HighQualityBicubic = 7
                    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)
                    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 2)
                    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", g, "int", 4)
                    DllCall("gdiplus\GdipDrawImageRectI", "ptr", g, "ptr", pBitmap
                        , "int", 0, "int", 0, "int", targetW, "int", nh)
                    DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)
                    src := pScaled
                }
            }
        }

        tmp := A_Temp "\qn-img-" A_TickCount "-" Random(1000, 9999) ".png"
        clsid := Buffer(16, 0)
        ; PNG 编码器 {557CF406-1A04-11D3-9A73-0000F81EF32E}
        DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}"
            , "ptr", clsid)
        hr := DllCall("gdiplus\GdipSaveImageToFile", "ptr", src, "wstr", tmp
            , "ptr", clsid, "ptr", 0)
        if (pScaled)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pScaled)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
        if (hr != 0 || !FileExist(tmp)) {
            try FileDelete tmp
            return ""
        }
        return tmp
    }

    static Mime(ext) {
        switch StrLower(ext) {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "bmp": return "image/bmp"
        }
        return "image/png"
    }

    ; ---- RTF ----------------------------------------------------------------

    /* Markdown -> RTF。按行解析：标题 / 列表 / 待办 / 引用 / 代码块 / 分割线
       都是行级结构，行内再交给 RtfInline 处理粗体斜体这些。 */
    static Rtf(note) {
        md := note.body_md
        if (Trim(md) = "")
            md := note.body_text
        return Export.MdToRtf(md)
    }

    static MdToRtf(md) {
        out := "{\rtf1\ansi\ansicpg936\deff0"
        out .= "{\fonttbl{\f0\fnil\fcharset134 Microsoft YaHei;}{\f1\fmodern\fcharset0 Consolas;}}"
        out .= "\viewkind4\uc1\pard\f0\fs22 "
        inCode := false
        for line in StrSplit(md, "`n", "`r") {
            t := RTrim(line)
            if RegExMatch(t, "^\s*````") {
                inCode := !inCode
                out .= inCode ? "\f1\fs18 " : "\f0\fs22 "
                continue
            }
            if inCode {
                out .= Export.RtfEsc(t) "\line "
                continue
            }
            /* 整行就是一张图（Markdown 里的图基本都是单独成行的）：
               直接嵌成 \pict。以前这里走 RtfInline，被替换成"[图片]"，
               导出的 RTF 里图全丢了 —— 用户反馈的就是这个。 */
            if RegExMatch(t, "^\s*!\[([^\]]*)\]\(\s*<?([^)>\s]+)>?[^)]*\)\s*$", &m) {
                out .= Export.RtfImage(m[2], m[1])
                continue
            }
            if (Trim(t) = "") {
                out .= "\par "
                continue
            }
            if RegExMatch(t, "^\s*(-{3,}|\*{3,}|_{3,})\s*$") {
                out .= "\pard\brdrb\brdrs\brdrw10\brsp20 \par\pard "
                continue
            }
            if RegExMatch(t, "^\s*(#{1,6})\s+(.*)$", &m) {
                lvl := StrLen(m[1])
                sz := lvl = 1 ? 36 : (lvl = 2 ? 30 : 26)
                out .= "\pard\sb140\sa80\b\fs" sz " " Export.RtfInline(m[2]) "\b0\fs22\par\pard "
                continue
            }
            if RegExMatch(t, "^\s*[-*+]\s+\[([ xX])\]\s*(.*)$", &m) {
                mark := (Trim(m[1]) = "" ? "\u9744? " : "\u9745? ")
                out .= "\pard\fi-260\li520 " mark Export.RtfInline(m[2]) "\par\pard "
                continue
            }
            if RegExMatch(t, "^\s*[-*+]\s+(.*)$", &m) {
                out .= "\pard\fi-260\li520 \bullet\tab " Export.RtfInline(m[1]) "\par\pard "
                continue
            }
            if RegExMatch(t, "^\s*(\d+)[.)]\s+(.*)$", &m) {
                out .= "\pard\fi-260\li520 " m[1] ".\tab " Export.RtfInline(m[2]) "\par\pard "
                continue
            }
            if RegExMatch(t, "^\s*>\s?(.*)$", &m) {
                out .= "\pard\li520\sa60\i " Export.RtfInline(m[1]) "\i0\par\pard "
                continue
            }
            out .= "\pard " Export.RtfInline(t) "\par "
        }
        return out "}"
    }

    /* Markdown 的一行图片 -> RTF 的 \pict。
       \picw/\pich 是源图像素尺寸，\picwgoal/\pichgoal 是显示尺寸（twips，
       1 英寸 = 1440）。按 96dpi 算 15 twips/px，但最宽 9000 twips（约 15.9cm），
       否则一张 1920px 的截图会顶满整页宽。
       失败时退回一句占位文字：至少让人知道那里原本有图。 */
    static RtfImage(src, alt := "") {
        return "\pard\qc" Export.RtfImageData(src, alt) "\par\pard "
    }

    /* 一张图的 RTF 片段：拿到字节就拼 \pict，拿不到就退化成一句占位文字。
       行内和整行两条路都走这儿，保证"找不到图"时两边的说法一致。 */
    static RtfImageData(src, alt := "") {
        p := Export.PrepImage(Export.LocalPath(src))
        if !p {
            name := (Trim(alt) = "") ? "图片" : alt
            return "{" Export.RtfEsc("[" name "：找不到图片文件]") "}"
        }
        blip := (p.kind = "jpeg") ? "\jpegblip" : "\pngblip"
        w := p.w > 0 ? p.w : 1600
        h := p.h > 0 ? p.h : 900
        gw := w * 15
        gh := h * 15
        if (gw > 9000) {
            gh := Round(gh * 9000 / gw)
            gw := 9000
        }
        hex := Export.HexOf(p.buf, p.size)
        if (hex = "")
            return "{" Export.RtfEsc("[图片读不出来]") "}"
        return "{\pict" blip "\picw" w "\pich" h
            . "\picwgoal" gw "\pichgoal" gh " " hex "}"
    }

    /* 图片地址 -> 本地路径。Markdown 里存的是 file:///（页面插入时写的），
       也可能有人手写了盘符路径。 */
    static LocalPath(src) {
        src := Trim(src)
        if (SubStr(src, 1, 8) = "file:///")
            return Export.UrlToPath(src)
        return src
    }

    /* 行内：先做 RTF 转义（\ { } 和非 ASCII），再在最外层套格式命令。
       这个顺序很关键 —— 反过来的话，我们自己插入的 \b 之类会被二次转义。

       行内图片（![x](y) 夹在文字中间）也要嵌进去。做法是先用一串 ASCII
       标记占位，等转义和粗斜体正则都跑完了再换回来 —— 直接嵌的话，\pict
       里的十六进制字母会被 `\*\*(.+?)\*\*` 这类正则误伤，花括号也会打乱配对。 */
    static RtfInline(s) {
        pics := []
        while RegExMatch(s, "!\[([^\]]*)\]\(\s*<?([^)>\s]+)>?[^)]*\)", &m) {
            pics.Push(Export.RtfImageData(m[2], m[1]))
            s := SubStr(s, 1, m.Pos - 1) "QNIMGM" (pics.Length - 1) "QNIMGE" SubStr(s, m.Pos + m.Len)
        }
        t := Export.RtfEsc(s)
        t := RegExReplace(t, "\[([^\]]*)\]\(([^)]*)\)"
            , "{\field{\*\fldinst{HYPERLINK `"$2`"}}{\fldrslt{\ul $1}}}")
        t := RegExReplace(t, "\*\*([^*]+)\*\*", "{\b $1}")
        t := RegExReplace(t, "\*([^*]+)\*", "{\i $1}")
        t := RegExReplace(t, "~~([^~]+)~~", "{\strike $1}")
        t := RegExReplace(t, "``([^``]+)``", "{\f1 $1}")
        Loop pics.Length
            t := StrReplace(t, "QNIMGM" (A_Index - 1) "QNIMGE", pics[A_Index])
        return t
    }

    /* RTF 只认 ASCII：中文必须写成 \uNNNN?（NNNN 是 16 位有符号数）。
       "\"、"{"、"}" 三个字符在 RTF 里是语法字符，必须转义。 */
    static RtfEsc(s) {
        out := ""
        Loop StrLen(s) {
            ch := SubStr(s, A_Index, 1)
            c := Ord(ch)
            if (c = 92)
                out .= "\\"
            else if (c = 123)
                out .= "\{"
            else if (c = 125)
                out .= "\}"
            else if (c = 9)
                out .= "\tab "
            else if (c < 32)
                continue
            else if (c > 127) {
                n := c > 32767 ? c - 65536 : c
                out .= "\u" n "?"
            } else
                out .= ch
        }
        return out
    }
}
