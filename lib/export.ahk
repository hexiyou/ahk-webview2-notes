#Requires AutoHotkey v2.0
; ============================================================================
;  export.ahk —— 单张便签导出（TXT / Markdown / HTML / RTF）
;
;  为什么不写在 note-window 里：转换逻辑跟窗口没关系，放这儿能被自检直接调，
;  以后加 PDF、Word 之类也只动这一个文件。
;
;  四种格式的来源各不一样，别图省事都从 body_html 转：
;    TXT   ← body_text（已经是纯文本，正文里的富文本标记天然被过滤掉）
;    MD    ← body_md（正本）
;    HTML  ← body_html（正本），图片就地转成 data URI，导出的单个文件能单独看
;    RTF   ← body_md 解析（Markdown 是按行组织的，比从 HTML 里抠格式稳得多）
;
;  注意 AC：RTF 里所有非 ASCII 字符都要写成 \uNNNN? 转义，字体表也指定了中文字体，
;  否则 Word 打开是乱码。
; ============================================================================

class Export {
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
            enc := ext = "rtf" ? "UTF-8-RAW" : "UTF-8"
            fh := FileOpen(f, "w", enc)
            fh.Write(text)
            fh.Close()
        } catch as e {
            App.Toast("写文件失败：" CleanComError(e.Message))
            return
        }
        App.Toast("已导出 " StrUpper(ext) "：" f)
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
       代价是文件变大（base64 约 4/3 倍），但便签里的图本来就不多。 */
    static Html(note) {
        body := note.body_html
        if (Trim(body) = "") {
            ; 只在 body_html 空而 md 有内容时兜底（正常保存流程两者都有）
            body := "<pre>" Export.HtmlEsc(note.body_md) "</pre>"
        }
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
        if !FileExist(path)
            return ""
        size := 0
        try {
            f := FileOpen(path, "r")
            size := f.Length
            if (size <= 0) {
                f.Close()
                return ""
            }
            buf := Buffer(size)
            f.RawRead(buf, size)
            f.Close()
        } catch {
            return ""
        }
        ; CRYPT_STRING_BASE64 = 1，两遍调用：先问长度再真转
        chars := 0
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", 1, "ptr", 0, "uint*", &chars)
            return ""
        if (chars = 0)
            return ""
        out := Buffer(chars * 2 + 4, 0)
        if !DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", size
            , "uint", 1, "ptr", out, "uint*", &chars)
            return ""
        b64 := StrGet(out, "UTF-16")
        SplitPath path, , , &ext
        return "data:" Export.Mime(ext) ";base64," b64
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

    /* 行内：先做 RTF 转义（\ { } 和非 ASCII），再在最外层套格式命令。
       这个顺序很关键 —— 反过来的话，我们自己插入的 \b 之类会被二次转义。 */
    static RtfInline(s) {
        t := Export.RtfEsc(s)
        ; 替换进去的"[图片]"也要过一遍转义，否则裸中文就混进 RTF 了
        t := RegExReplace(t, "!\[([^\]]*)\]\([^)]*\)", Export.RtfEsc("[图片]"))
        t := RegExReplace(t, "\[([^\]]*)\]\(([^)]*)\)"
            , "{\field{\*\fldinst{HYPERLINK `"$2`"}}{\fldrslt{\ul $1}}}")
        t := RegExReplace(t, "\*\*([^*]+)\*\*", "{\b $1}")
        t := RegExReplace(t, "\*([^*]+)\*", "{\i $1}")
        t := RegExReplace(t, "~~([^~]+)~~", "{\strike $1}")
        t := RegExReplace(t, "``([^``]+)``", "{\f1 $1}")
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
