; ============================================================================
;  todo-export.ahk —— 待办包（.qntodo）的导出与导入
;
;  为什么是 JSON 而不是 zip：压缩要额外依赖（或者再手写一层 zip 解析），
;  而待办包的体积主要在图片，图片导出前已经降采样过。一个 UTF-8 JSON
;  用记事本能打开、能 diff，出问题时用户自己也看得懂。
;
;  ★ 图片是这个功能最大的坑：正文里存的是 file:///C:/…/data/images/xxx.png
;    这种**绝对路径**，直接把 body_html 搬到另一台机器，图全碎 —— 而且是
;    静默碎，打开才看见一个个破图。所以导出时把图抽进包、正文改写成
;    qnimg://原名；导入时再落盘、换回本机路径。
;
;  依赖：App.Store / App.DataDir / TodoStore / Reminder / Export（图片编解码）
; ============================================================================

class TodoExport {

    static SCHEMA := 1
    static KIND := "quicknote.todo"
    static SCHEME := "qnimg://"

    /* ---- 导出 ---------------------------------------------------------- */

    /* 返回 {ok, path, items, images, missing, bytes, msg} */
    static Save(noteID, path, opts := 0) {
        note := App.Store.Get(noteID)
        if !note
            return {ok: 0, msg: "便签不存在"}
        if (note.kind != "todo")
            return {ok: 0, msg: "只有待办便签能导出成 .qntodo"}
        withLinks := IsObject(opts) ? TodoExport._get(opts, "links", 1) : 1

        images := Map()            ; 原名 → base64（同一张图只存一份）
        missing := []              ; 源文件不在了的图名
        linkMap := Map()           ; 真 noteID → 导出期 id（n1、n2…）
        linkParts := []
        itemParts := []

        for it in TodoStore.Items(noteID) {
            html := TodoExport._Pack(it.body_html, images, missing)

            /* 关联便签：导出期用 n1/n2 这种临时 id，绝不能用真 id ——
               真 id 到另一台机器一定撞，撞上就是"关联到了别人的便签"。 */
            linkRef := ""
            if (withLinks && it.link_note_id) {
                if !linkMap.Has(it.link_note_id) {
                    ln := App.Store.Get(it.link_note_id)
                    if (ln && ln.kind = "note") {
                        eid := "n" (linkParts.Length + 1)
                        linkMap[it.link_note_id] := eid
                        lnHtml := TodoExport._Pack(ln.body_html, images, missing)
                        p := '{"exportId":' JsonQuote(eid)
                        p .= ',"title":' JsonQuote(ln.title)
                        p .= ',"bodyHtml":' JsonQuote(lnHtml)
                        p .= ',"bodyMd":' JsonQuote(ln.body_md)
                        linkParts.Push(p "}")
                    }
                }
                if linkMap.Has(it.link_note_id)
                    linkRef := linkMap[it.link_note_id]
            }

            s := '{"title":' JsonQuote(it.title)
            s .= ',"bodyHtml":' JsonQuote(html)
            s .= ',"bodyMd":' JsonQuote(it.body_md)
            s .= ',"bodyText":' JsonQuote(it.body_text)
            s .= ',"status":' JsonQuote(it.status)
            s .= ',"startAt":' it.start_at
            s .= ',"dueAt":' it.due_at
            s .= ',"seq":' it.seq
            s .= ',"linkNote":' JsonQuote(linkRef)
            s .= ',"reminders":[' TodoExport._RemJson(it.id) "]"
            itemParts.Push(s "}")
        }

        imgParts := []
        for name, b64 in images
            imgParts.Push(JsonQuote(name) ":" JsonQuote(b64))

        text := '{"schema":' TodoExport.SCHEMA
        text .= ',"kind":' JsonQuote(TodoExport.KIND)
        text .= ',"app":"QuickNote"'
        text .= ',"exportedAt":' Store.Now()
        text .= ',"note":{"title":' JsonQuote(note.title)
        text .= ',"color":' JsonQuote(note.color)
        text .= ',"createdAt":' note.created_at "}"
        text .= ',"linkedNotes":[' TodoExport._Join(linkParts, ",") "]"
        text .= ',"items":[' TodoExport._Join(itemParts, ",") "]"
        text .= ',"images":{' TodoExport._Join(imgParts, ",") "}}"

        try {
            f := FileOpen(path, "w", "UTF-8")
            if !f
                return {ok: 0, msg: "写不了这个位置：" path}
            f.Write(text)
            f.Close()
        } catch as e {
            return {ok: 0, msg: "写文件失败：" CleanComError(e.Message)}
        }

        return {ok: 1, path: path, items: itemParts.Length, images: images.Count
            , links: linkParts.Length, missing: missing.Length
            , bytes: StrLen(text)}
    }

    static _RemJson(todoID) {
        out := []
        for r in Reminder.ForTodo(todoID) {
            s := '{"kind":' JsonQuote(r.kind)
            s .= ',"anchor":' JsonQuote(r.anchor)
            s .= ',"offsetMin":' r.offset_min
            s .= ',"atTime":' JsonQuote(r.at_time)
            s .= ',"daysBefore":' r.days_before
            /* notify 本来就是一段 JSON，直接内联，别再包一层引号 */
            s .= ',"notify":' (Trim(r.notify) = "" ? "{}" : r.notify)
            s .= ',"enabled":' (r.enabled ? 1 : 0)
            out.Push(s "}")
        }
        return TodoExport._Join(out, ",")
    }

    /* --- 图片：本机绝对路径 → qnimg://原名 ---
       找不到源文件时保留原 src，并在 missing 里记一笔：留着至少用户能看到
       "这张图原本在哪"，抹掉就彻底没线索了。 */
    static _Pack(html, images, missing) {
        if (html = "" || !InStr(html, "file:///"))
            return html
        out := ""
        pos := 1
        while RegExMatch(html, 'i)src="(file:///[^"]+)"', &m, pos) {
            out .= SubStr(html, pos, m.Pos - pos)
            file := Export.UrlToPath(m[1])
            name := TodoExport._BaseName(file)
            if TodoExport._IsImage(name) {
                if !images.Has(name) {
                    p := Export.PrepImage(file)
                    if p
                        images[name] := Export.B64Of(p.buf, p.size)
                    else
                        missing.Push(name)
                }
                if (images.Has(name) && images[name] != "")
                    out .= 'src="' TodoExport.SCHEME name '"'
                else
                    out .= m[0]
            } else {
                out .= m[0]         ; 不是 data\images 里的图，别动它
            }
            pos := m.Pos + m.Len
        }
        out .= SubStr(html, pos)
        return out
    }

    /* ---- 导入 ---------------------------------------------------------- */

    /* 只校验并取摘要，不落库。给"导入到一张新便签"用：先确认包是好的，
       再建便签 —— 否则校验失败会白留一张空待办在列表里。 */
    static Peek(path) {
        if !FileExist(path)
            return {ok: 0, msg: "找不到文件：" path}
        text := ""
        try text := FileRead(path, "UTF-8")
        catch as e
            return {ok: 0, msg: "读不了文件：" CleanComError(e.Message)}
        v := TodoExport._Validate(text)
        if !v.ok
            return {ok: 0, msg: v.msg}
        noteRaw := JsonRaw(text, "note", "{")
        title := (noteRaw != "") ? JsonStr(noteRaw, "title", "") : ""
        if (Trim(title) = "")
            title := "导入的待办"
        return {ok: 1, title: title
            , items: JsonItems(JsonRaw(text, "items", "[")).Length}
    }

    /* 校验一份包的文本。Load / Peek 共用，别让两处的判定标准走偏。 */
    static _Validate(text) {
        if (Trim(text) = "")
            return {ok: 0, msg: "文件是空的"}
        k := JsonStr(text, "kind", "")
        if (k != TodoExport.KIND)
            return {ok: 0, msg: "这不是待办包（kind=" (k = "" ? "缺失" : k) "）"}
        schema := JsonNum(text, "schema", 0)
        if (schema <= 0)
            return {ok: 0, msg: "包里没有版本号，不敢导"}
        if (schema > TodoExport.SCHEMA)
            return {ok: 0, msg: "这个包由更新版本的程序导出（schema " schema
                . "），请先升级程序"}
        return {ok: 1, schema: schema}
    }

    /* noteID：目标待办便签。
       opts.replace=1 → 先清空它的事项再导（否则追加到末尾）。
       返回 {ok, items, reminders, images, missingImages, msg} */
    static Load(path, noteID, opts := 0) {
        if !FileExist(path)
            return {ok: 0, msg: "找不到文件：" path}
        text := ""
        try text := FileRead(path, "UTF-8")
        catch as e
            return {ok: 0, msg: "读不了文件：" CleanComError(e.Message)}

        /* schema 必须校验。版本比本程序高就拒绝 —— "尽力而为地导入"
           只会导出一堆看起来正常、实际字段错位的事项，比直接拒绝糟得多。 */
        v := TodoExport._Validate(text)
        if !v.ok
            return {ok: 0, msg: v.msg}

        todoNote := App.Store.Get(noteID)
        if !todoNote
            return {ok: 0, msg: "目标便签不存在"}
        if (todoNote.kind != "todo")
            return {ok: 0, msg: "只能导入到待办便签里"}

        /* 图片先解出来备用：事项正文和关联便签正文都可能引用同一张图，
           落盘只做一次，后面都从 written 里取文件名。 */
        imgsRaw := JsonRaw(text, "images", "{")
        images := Map()
        if (imgsRaw != "") {
            for key in JsonKeys(imgsRaw)
                images[key] := JsonStr(imgsRaw, key, "")
        }
        written := Map()
        missImgs := []

        replaced := 0
        if (IsObject(opts) && TodoExport._get(opts, "replace", 0)) {
            for it in TodoStore.Items(noteID)
                TodoStore.Delete(it.id)
            replaced := 1
        }

        /* 关联便签先建，拿到新 id 才能给事项填 link_note_id */
        linkMap := Map()
        for lnTxt in JsonItems(JsonRaw(text, "linkedNotes", "[")) {
            eid := JsonStr(lnTxt, "exportId", "")
            if (eid = "")
                continue
            html := TodoExport._Unpack(JsonStr(lnTxt, "bodyHtml", ""), images, written, missImgs)
            md := JsonStr(lnTxt, "bodyMd", "")
            nid := App.Store.Create(Map("kind", "note"
                , "title", JsonStr(lnTxt, "title", "")
                , "body_html", html
                , "body_md", md
                , "body_text", TodoExport._TextOf(md != "" ? md : html)))
            linkMap[eid] := nid
        }

        n := 0
        nrem := 0
        for itTxt in JsonItems(JsonRaw(text, "items", "[")) {
            html := TodoExport._Unpack(JsonStr(itTxt, "bodyHtml", ""), images, written, missImgs)
            linkRef := JsonStr(itTxt, "linkNote", "")
            lid := 0
            if (linkRef != "" && linkMap.Has(linkRef))
                lid := linkMap[linkRef]

            id := TodoStore.Add(noteID, Map(
                "title", JsonStr(itTxt, "title", "")
                , "body_html", html
                , "body_md", JsonStr(itTxt, "bodyMd", "")
                , "body_text", JsonStr(itTxt, "bodyText", "")
                , "status", JsonStr(itTxt, "status", "todo")
                , "start_at", JsonNum(itTxt, "startAt", 0)
                , "due_at", JsonNum(itTxt, "dueAt", 0)
                , "seq", JsonNum(itTxt, "seq", 0)
                , "link_note_id", lid))
            n++

            for rs in JsonItems(JsonRaw(itTxt, "reminders", "[")) {
                ntf := JsonRaw(rs, "notify", "{")
                if (ntf = "{}" || ntf = "")
                    ntf := ""
                res := Reminder.Add(id, Map(
                    "kind", JsonStr(rs, "kind", "offset")
                    , "anchor", JsonStr(rs, "anchor", "start")
                    , "offset_min", JsonNum(rs, "offsetMin", 30)
                    , "at_time", JsonStr(rs, "atTime", "09:00")
                    , "days_before", JsonNum(rs, "daysBefore", 0)
                    , "notify", ntf))
                if IsObject(res) {
                    nrem++
                    /* 导出时是关掉的规则，导入后也保持关掉：
                       重新打开 = 可能立刻补发一条旧提醒，那不是用户要的。 */
                    if !JsonBool(rs, "enabled", 1)
                        Reminder.SetEnabled(res.id, 0)
                }
            }
        }

        msg := "已导入 " n " 个事项、" nrem " 条提醒"
        if (written.Count > 0)
            msg .= "、" written.Count " 张图片"
        if (missImgs.Length > 0)
            msg .= "；" missImgs.Length " 张图片缺失"
        return {ok: 1, items: n, reminders: nrem, images: written.Count
            , missingImages: missImgs.Length, replaced: replaced, msg: msg}
    }

    /* --- 图片：qnimg://原名 → 本机文件 --- */
    static _Unpack(html, images, written, missImgs) {
        if (html = "" || !InStr(html, TodoExport.SCHEME))
            return html
        out := ""
        pos := 1
        while RegExMatch(html, 'i)src="qnimg://([^"]+)"', &m, pos) {
            out .= SubStr(html, pos, m.Pos - pos)
            name := m[1]
            final := TodoExport._Claim(name, images, written)
            if (final != "")
                out .= 'src="' TodoExport._FileUrl(App.DataDir "\images\" final) '"'
            else {
                /* 包里没这张图（或者解码失败）：保留占位并记一笔。
                   静默删掉 src 会留一个空 img，用户以为图丢了却查不出原因。 */
                if !TodoExport._Has(missImgs, name)
                    missImgs.Push(name)
                out .= m[0]
            }
            pos := m.Pos + m.Len
        }
        out .= SubStr(html, pos)
        return out
    }

    /* 落盘一次，之后同名图都复用。目标同名文件已存在就加 -1、-2…
       —— 不能用原名硬覆盖：那会悄悄改掉本机另一张便签正在用的图。 */
    static _Claim(name, images, written) {
        if written.Has(name)
            return written[name]
        if !images.Has(name)
            return ""
        b64 := images[name]
        if (Trim(b64) = "")
            return ""
        dir := App.DataDir "\images"
        try DirCreate(dir)
        stem := name
        ext := ""
        dot := InStr(name, ".", , -1)
        if (dot > 1) {
            stem := SubStr(name, 1, dot - 1)
            ext := SubStr(name, dot)
        }
        final := TodoExport._SafeName(name)
        i := 0
        while FileExist(dir "\" final) {
            i++
            final := TodoExport._SafeName(stem) "-" i ext
        }
        if !TodoExport.B64ToFile(b64, dir "\" final)
            return ""
        written[name] := final
        return final
    }

    /* 包是外部文件，文件名一律当不可信输入：路径分隔符、冒号、控制字符
       都可能把落盘位置带出 data\images。 */
    static _SafeName(name) {
        s := RegExReplace(name, '[\\/:*?"<>|\x00-\x1f]', "_")
        s := RegExReplace(s, "^\.+", "_")
        if (Trim(s) = "")
            s := "img"
        return s
    }

    /* base64 → 文件。CRYPT_STRING_BASE64 = 1，同样两遍：先问长度再真转。 */
    static B64ToFile(b64, path) {
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
        try {
            f := FileOpen(path, "w")
            if !f
                return 0
            f.RawWrite(buf, size)
            f.Close()
        } catch {
            return 0
        }
        return size
    }

    /* ---- 小工具 -------------------------------------------------------- */

    static _FileUrl(path) {
        s := StrReplace(path, "\", "/")
        s := StrReplace(s, "%", "%25")
        s := StrReplace(s, " ", "%20")
        return "file:///" s
    }

    static _BaseName(path) {
        return RegExReplace(path, "^.*[\\/]", "")
    }

    static _IsImage(name) {
        return RegExMatch(name, "i)\.(png|jpe?g|gif|webp|bmp)$") ? 1 : 0
    }

    /* 纯文本兜底：从 Markdown / HTML 里抠一段能搜索的文字。
       这里**不追求精确**，正文正本是 body_md，body_text 只是给搜索和
       列表摘要用的。 */
    static _TextOf(s) {
        s := RegExReplace(s, "s)<[^>]*>", " ")
        s := RegExReplace(s, "s)[#*_`>`\-]{1,6} ", " ")
        return Trim(RegExReplace(s, "\s+", " "))
    }

    static _Has(arr, v) {
        for x in arr {
            if (x = v)
                return 1
        }
        return 0
    }

    static _Join(arr, sep) {
        out := ""
        for i, v in arr
            out .= (i > 1 ? sep : "") v
        return out
    }

    static _get(obj, key, def := "") {
        if !IsObject(obj)
            return def
        if (obj is Map)
            return obj.Has(key) ? obj[key] : def
        return obj.HasProp(key) ? obj.%key% : def
    }
}
