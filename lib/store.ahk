#Requires AutoHotkey v2.0
; ============================================================================
;  store.ahk —— 便签数据访问层
;
;  职责边界（很重要，别越界）：
;    · 只管 SQLite 的读写与表结构，不碰窗口、不碰 WebView2、不认识 hwnd。
;    · 页面（JS）永远不直接访问数据库，一切写入都经由 bridge 转到这里。
;    · 所有时间戳都是 Unix 秒（UTC），只在展示层转本地时间。
;
;  表结构要点：
;    kind       note（普通便签）| todo（待办便签），决定用哪个页面与哪套菜单
;    body_html  富文本模式的正文字面（contenteditable 的 innerHTML）
;    body_text  纯文本副本，只用于搜索与列表摘要，不参与编辑
;    body_md    Markdown 源码（md 模式为正本；rich 模式是 html 转出的近似值）
;    mode       rich | md，决定打开时用哪个编辑器
;    hidden     0/1：仅"不在桌面显示"。列表与托盘仍能看到、能打开
;
;  ★ kind='todo' 的行，body_* 三列是 todos 表的**派生摘要**（见 TodoStore._Refresh），
;    不是用户正文。凡是想直接写正文的路径（SaveBody / 导入）必须先看 kind，
;    否则写进去的内容会被下一次摘要刷新无声覆盖。
;
;  注意：AHK v2 的续段字符串对缩进极敏感，SQL 一律逐行拼接，不用 "(" 续段。
; ============================================================================

class Store {
    static SCHEMA_VERSION := 4

    db := 0

    __New(dbPath) {
        SplitPath dbPath, , &dir
        if (dir && !DirExist(dir))
            DirCreate dir
        this.db := Sqlite(dbPath)
        this._Migrate()
        return this
    }

    ; ---- 初始化 -------------------------------------------------------------

    _Migrate() {
        sql := "CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);"
        sql .= "CREATE TABLE IF NOT EXISTS notes("
        sql .= " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        sql .= " title TEXT NOT NULL DEFAULT '',"
        sql .= " body_html TEXT NOT NULL DEFAULT '',"
        sql .= " body_text TEXT NOT NULL DEFAULT '',"
        sql .= " body_md TEXT NOT NULL DEFAULT '',"
        sql .= " mode TEXT NOT NULL DEFAULT 'rich',"
        sql .= " color TEXT NOT NULL DEFAULT 'yellow',"
        sql .= " x INTEGER NOT NULL DEFAULT 0,"
        sql .= " y INTEGER NOT NULL DEFAULT 0,"
        sql .= " w INTEGER NOT NULL DEFAULT 300,"
        sql .= " h INTEGER NOT NULL DEFAULT 280,"
        sql .= " pinned INTEGER NOT NULL DEFAULT 0,"
        sql .= " hidden INTEGER NOT NULL DEFAULT 0,"
        sql .= " title_locked INTEGER NOT NULL DEFAULT 0,"
        sql .= " opacity INTEGER NOT NULL DEFAULT 100,"
        sql .= " hotkey TEXT NOT NULL DEFAULT '',"
        sql .= " kind TEXT NOT NULL DEFAULT 'note',"
        sql .= " created_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " updated_at INTEGER NOT NULL DEFAULT 0);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_notes_hidden ON notes(hidden);"
        /* ★ idx_notes_kind 不在这里建：老库的 notes 还没有 kind 列，
           在这儿建索引会 no such column（自检抓到过）。补列之后再建。 */
        /* ---- v4：待办（事项 / 提醒规则 / 触发记账） -----------------------
           新表一律 IF NOT EXISTS 无条件建。理由见下面 _EnsureColumn 那段注释：
           新建的库版本号已经是 4，`if (cur < 4)` 那段永远不跑，靠它建表等于没建。 */
        sql .= "CREATE TABLE IF NOT EXISTS todos("
        sql .= " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        sql .= " note_id INTEGER NOT NULL,"
        sql .= " seq INTEGER NOT NULL DEFAULT 1000,"
        sql .= " title TEXT NOT NULL DEFAULT '',"
        sql .= " title_locked INTEGER NOT NULL DEFAULT 0,"
        sql .= " body_html TEXT NOT NULL DEFAULT '',"
        sql .= " body_text TEXT NOT NULL DEFAULT '',"
        sql .= " body_md TEXT NOT NULL DEFAULT '',"
        sql .= " status TEXT NOT NULL DEFAULT 'todo',"
        sql .= " start_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " due_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " done_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " canceled_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " link_note_id INTEGER NOT NULL DEFAULT 0,"
        sql .= " created_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " updated_at INTEGER NOT NULL DEFAULT 0);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_todos_note ON todos(note_id, seq);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_todos_due ON todos(due_at);"
        sql .= "CREATE TABLE IF NOT EXISTS todo_reminders("
        sql .= " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        sql .= " todo_id INTEGER NOT NULL,"
        sql .= " kind TEXT NOT NULL DEFAULT 'offset',"
        sql .= " anchor TEXT NOT NULL DEFAULT 'start',"
        sql .= " offset_min INTEGER NOT NULL DEFAULT 0,"
        sql .= " at_time TEXT NOT NULL DEFAULT '09:00',"
        sql .= " days_before INTEGER NOT NULL DEFAULT 1,"
        sql .= " notify TEXT NOT NULL DEFAULT '',"
        sql .= " enabled INTEGER NOT NULL DEFAULT 1,"
        sql .= " next_fire_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " last_fired_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " created_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " updated_at INTEGER NOT NULL DEFAULT 0);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_rem_next ON todo_reminders(enabled, next_fire_at);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_rem_todo ON todo_reminders(todo_id);"
        sql .= "CREATE TABLE IF NOT EXISTS todo_fires("
        sql .= " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        sql .= " todo_id INTEGER NOT NULL,"
        sql .= " reminder_id INTEGER NOT NULL,"
        sql .= " fire_at INTEGER NOT NULL,"
        sql .= " state TEXT NOT NULL DEFAULT 'sending',"
        sql .= " detail TEXT NOT NULL DEFAULT '',"
        sql .= " started_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " finished_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " UNIQUE(todo_id, reminder_id, fire_at));"
        sql .= "CREATE INDEX IF NOT EXISTS idx_fires_todo ON todo_fires(todo_id, fire_at DESC);"
        this.db.Exec(sql)

        /* 版本号只说明"迁移跑过"，不说明"列真在"。踩过一次：上一版把
           title_locked 只加在迁移分支里，忘了写进 CREATE TABLE，结果新建的库
           版本号直接就是 2、迁移永远不跑，读行时 m["title_locked"] 抛
           "Item has no value"。所以这里不看版本，按 PRAGMA 实测补一次 ——
           而且必须放在建 idx_notes_kind **之前**：老库的 notes 还没有 kind 列，
           先建索引就是 no such column（自检当场抓到）。 */
        this._EnsureColumn("notes", "title_locked", "INTEGER NOT NULL DEFAULT 0")
        this._EnsureColumn("notes", "opacity", "INTEGER NOT NULL DEFAULT 100")
        this._EnsureColumn("notes", "hotkey", "TEXT NOT NULL DEFAULT ''")
        this._EnsureColumn("notes", "kind", "TEXT NOT NULL DEFAULT 'note'")
        this.db.Exec("CREATE INDEX IF NOT EXISTS idx_notes_kind ON notes(kind)")

        cur := this.db.Scalar("SELECT v FROM meta WHERE k='schema_version'")
        if (cur = "") {
            this.db.Run("INSERT INTO meta(k,v) VALUES('schema_version',?)", String(Store.SCHEMA_VERSION))
            return
        }
        ; ---- 增量迁移：老库按版本号往上补 ----
        /* v1 -> v2：标题可以手动指定。不加这一列的话，"用户起的名字"会被下一次
           正文保存时按第一行重算掉。 */
        if (cur < 2) {
            this._EnsureColumn("notes", "title_locked", "INTEGER NOT NULL DEFAULT 0")
            this.db.Run("UPDATE meta SET v=? WHERE k='schema_version'", "2")
        }
        /* v2 -> v3：每张便签自己的透明度（30~100）与全局快捷键（空 = 没设）。
           opacity 存整数百分比而不是 0~255：菜单里就是"80%"，读写不用来回换。 */
        if (cur < 3) {
            this._EnsureColumn("notes", "opacity", "INTEGER NOT NULL DEFAULT 100")
            this._EnsureColumn("notes", "hotkey", "TEXT NOT NULL DEFAULT ''")
            this.db.Run("UPDATE meta SET v=? WHERE k='schema_version'", "3")
        }
        /* v3 -> v4：便签类型。老行一律 'note'，走原来的页面与菜单，行为零变化；
           新建库的 CREATE TABLE 里已经带了这一列，这里只是给老库补。
           列本身在上面已经按 PRAGMA 补过了，这里只更新版本号。 */
        if (cur < 4)
            this.db.Run("UPDATE meta SET v=? WHERE k='schema_version'", "4")
    }

    /* 列存在就跳过，不存在就 ALTER。注意 SQLite 的 ALTER TABLE ADD COLUMN
       不支持 IF NOT EXISTS，只能自己先查 PRAGMA。 */
    _EnsureColumn(table, col, decl) {
        for r in this.db.Query("PRAGMA table_info(" table ")") {
            if (r["name"] = col)
                return
        }
        try this.db.Exec("ALTER TABLE " table " ADD COLUMN " col " " decl)
    }

    ; ---- 读 -----------------------------------------------------------------

    /* 排序只用 created_at，不用 updated_at。
       教训：按"最近更新"排的话，打开/编辑一张便签就会把它顶到最前，列表看着
       就是"一点就乱跳"。用户要的是稳定顺序，所以固定成
           置顶优先 → 新建的在前 → id 兜底（同一秒建的多张也有确定顺序）
       想按"最近编辑"排是以后加排序选项的事，不能是默认行为。 */
    static ORDER := " ORDER BY pinned DESC, created_at DESC, id DESC"

    ; 全部便签（含 hidden）
    All() {
        return this._Rows(this.db.Query("SELECT * FROM notes" . Store.ORDER))
    }

    /* 排序 + 过滤 + 关键字，一次拼出来。列表窗口只走这一个入口 ——
       拆成三份实现的话，"排序改了、过滤还在用上一版"这类错很难发现。

       sort    default（置顶优先、新建在前）| title | created | updated
       desc    1 = 倒序（只对 title/created/updated 有意义，default 是固定的）
       filter  Map，键 hotkey / pinned / shown / image / code / kind 取 0 或 1，
               缺键 = 不限。1 表示"有快捷键 / 已置顶 / 已展开 / 含图片 / 含代码块 /
               是待办便签"，0 表示前半句的反面（kind 的 0 = 普通便签）。
               多个条件是 AND：勾了"已置顶"又勾"含图片"，就是既置顶又有图。

       为什么过滤也放 SQL：图片/代码块要看正文内容（body_html），而列表页拿不到
       正文 —— 它只有宿主推过去的摘要。放这里还能让"搜索"和"过滤"天然叠加。 */
    Query(term := "", sort := "default", desc := 1, filter := 0) {
        where := ""
        if (f := Store._FilterSql(filter)) != ""
            where .= " WHERE " f
        t := Trim(term)
        if (t != "") {
            like := "%" t "%"
            cond := "(title LIKE ? OR body_text LIKE ? OR body_md LIKE ?)"
            where .= (where = "") ? " WHERE " cond : " AND " cond
        }
        sql := "SELECT * FROM notes" where Store._SortSql(sort, desc)
        if (t != "")
            return this._Rows(this.db.Query(sql, like, like, like))
        return this._Rows(this.db.Query(sql))
    }

    static _SortSql(sort, desc) {
        d := desc ? " DESC" : " ASC"
        switch sort {
            case "title": return " ORDER BY title" d ", id" d
            case "created": return " ORDER BY created_at" d ", id" d
            case "updated": return " ORDER BY updated_at" d ", id" d
        }
        return Store.ORDER
    }

    /* 过滤条件 → WHERE 片段。值和列名都是写死的（不从外部拼），
       唯一的输入只是"挑哪一条"，没有注入面。 */
    static _FilterSql(filter) {
        if !IsObject(filter)
            return ""
        /* 三个反引号不能直接写在字符串里（AHK 的转义字符就是它），拼出来 */
        static bt3 := Chr(96) . Chr(96) . Chr(96)
        rules := Map(
            "hotkey", ["hotkey<>''", "hotkey=''"],
            "pinned", ["pinned=1", "pinned=0"],
            "shown",  ["hidden=0", "hidden=1"],
            "kind",   ["kind='todo'", "kind='note'"],
            "image",  ["body_html LIKE '%<img%'", "body_html NOT LIKE '%<img%'"],
            "code",   ["(body_html LIKE '%<pre%' OR body_md LIKE '%" bt3 "%')"
                     , "(body_html NOT LIKE '%<pre%' AND body_md NOT LIKE '%" bt3 "%')"])
        out := ""
        for key, pair in rules {
            if !filter.Has(key)
                continue
            v := filter[key]
            if (v = "" || v < 0)          ; -1 / 空 = 不限
                continue
            sql := pair[v ? 1 : 2]
            out .= (out = "") ? sql : " AND " sql
        }
        return out
    }

    ; 桌面上的那些：置顶优先
    Visible() {
        return this._Rows(this.db.Query("SELECT * FROM notes WHERE hidden=0" . Store.ORDER))
    }

    Get(id) {
        rows := this.db.Query("SELECT * FROM notes WHERE id=?", id)
        return rows.Length ? this._Row(rows[1]) : 0
    }

    Count() => this.db.Scalar("SELECT count(*) FROM notes")

    ; 关键字搜索：标题 / 纯文本 / md 源码，中文直接 LIKE
    Search(term) {
        t := Trim(term)
        if (t = "")
            return this.All()
        like := "%" t "%"
        sql := "SELECT * FROM notes WHERE hidden=0"
        sql .= " AND (title LIKE ? OR body_text LIKE ? OR body_md LIKE ?)"
        sql .= Store.ORDER
        return this._Rows(this.db.Query(sql, like, like, like))
    }

    ; 与 Search 相同，但**包含**已收起的。列表面板用这个，
    ; 便签本体的搜索（将来）用 Search —— 语义上"桌面搜索"不该翻出收起的。
    SearchAll(term) {
        t := Trim(term)
        if (t = "")
            return this.All()
        like := "%" t "%"
        sql := "SELECT * FROM notes WHERE (title LIKE ? OR body_text LIKE ? OR body_md LIKE ?)"
        sql .= Store.ORDER
        return this._Rows(this.db.Query(sql, like, like, like))
    }

    ; ---- 写 -----------------------------------------------------------------

    ; opts 是 Map（也兼容对象），没给的字段取默认值。返回新 id
    /* kind='todo' 时不写正文：那三列是摘要，由 TodoStore._Refresh 算。
       这里传进来的 body_* 对待办便签一律无效（传了也不写），避免"创建时塞了
       一段文字、下一秒被摘要刷掉"这种看得见但说不清的怪事。 */
    Create(opts := {}) {
        now := Store.Now()
        kind := Store._get(opts, "kind", "note")
        if (kind != "todo")
            kind := "note"
        isTodo := (kind = "todo")
        sql := "INSERT INTO notes(kind, title, body_html, body_text, body_md, mode, color,"
        sql .= " x, y, w, h, pinned, hidden, created_at, updated_at)"
        sql .= " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        r := this.db.Run(sql
            , kind
            , Store._get(opts, "title", "")
            , isTodo ? "" : Store._get(opts, "body_html", "")
            , isTodo ? "" : Store._get(opts, "body_text", "")
            , isTodo ? "" : Store._get(opts, "body_md", "")
            , isTodo ? "rich" : Store._get(opts, "mode", "rich")
            , Store._get(opts, "color", "yellow")
            , Store._get(opts, "x", 0)
            , Store._get(opts, "y", 0)
            , Store._get(opts, "w", 300)
            , Store._get(opts, "h", 280)
            , Store._get(opts, "pinned", 0)
            , Store._get(opts, "hidden", 0)
            , now, now)
        return r.lastId
    }

    ; 这张便签是什么类型（'note' / 'todo'）。查不到行时返回 ""，由调用方决定
    KindOf(id) {
        return this.db.Scalar("SELECT kind FROM notes WHERE id=?", id)
    }

    /* 正文保存：一次写齐四种表示，updated_at 自动更新。
       title 用 CASE 保护：用户手动改过标题（title_locked=1）以后，正文第一行
       再怎么变都不许盖掉它 —— 否则"重命名"这个功能等于没做。

       返回 1 = 写了；0 = 拒写（kind='todo'）。待办便签的正文在 todos 表里，
       notes 这三列只是摘要缓存，从这条路写进去会被下一次摘要刷新无声覆盖。 */
    SaveBody(id, title, html, text, md, mode) {
        if (this.KindOf(id) = "todo")
            return 0
        sql := "UPDATE notes SET title=CASE WHEN title_locked=1 THEN title ELSE ? END,"
        sql .= " body_html=?, body_text=?, body_md=?, mode=?, updated_at=? WHERE id=?"
        this.db.Run(sql, title, html, text, md, mode, Store.Now(), id)
        return 1
    }

    ; 用户指定标题：写进去并上锁
    SetTitle(id, title) {
        this.db.Run("UPDATE notes SET title=?, title_locked=1 WHERE id=?", title, id)
    }

    /* 自动标题：写进去但**不上锁**。和 SetTitle 必须分开 ——
       外部进程塞进来的正文一开始没有标题，得先按首行生成一个给列表看，
       但用户之后改正文首行时它应该继续跟着变（SetTitle 是"用户亲自命名"，
       语义完全不同，混用会把标题钉死）。 */
    SetAutoTitle(id, title) {
        this.db.Run("UPDATE notes SET title=?, title_locked=0 WHERE id=?", title, id)
    }

    ; 恢复自动标题：解锁并按正文第一行重算。返回新标题
    ClearTitle(id) {
        n := this.Get(id)
        if !n
            return ""
        t := Store.AutoTitle(n.body_text)
        this.db.Run("UPDATE notes SET title=?, title_locked=0 WHERE id=?", t, id)
        return t
    }

    /* 自动标题 = 正文第一行非空内容，超过 60 字截断。
       从这里算而不是从页面算，是因为"恢复自动标题"是从宿主菜单触发的，
       那时手里只有库里的 body_text（已经是纯文本了，正好拿来用）。 */
    static AutoTitle(text) {
        for line in StrSplit(text, "`n", "`r") {
            t := Trim(RegExReplace(line, "[ \t]+", " "))
            if (t != "")
                return StrLen(t) > 60 ? SubStr(t, 1, 60) "…" : t
        }
        return ""
    }

    SetGeometry(id, x, y, w, h) {
        this.db.Run("UPDATE notes SET x=?, y=?, w=?, h=? WHERE id=?", x, y, w, h, id)
    }

    SetPinned(id, pinned) {
        this.db.Run("UPDATE notes SET pinned=? WHERE id=?", pinned ? 1 : 0, id)
    }

    SetHidden(id, hidden) {
        this.db.Run("UPDATE notes SET hidden=?, updated_at=? WHERE id=?", hidden ? 1 : 0, Store.Now(), id)
    }

    SetColor(id, color) {
        this.db.Run("UPDATE notes SET color=? WHERE id=?", color, id)
    }

    /* 透明度：整数百分比，30~100。夹一下再写 —— 菜单点不到 0，
       但 IPC / 手改库都可能传进来离谱的值，写进库里就再也恢复不了。 */
    SetOpacity(id, pct) {
        pct := Max(30, Min(100, Integer(pct)))
        this.db.Run("UPDATE notes SET opacity=? WHERE id=?", pct, id)
    }

    ; 快捷键：空串表示取消。合法性/冲突由 App 那层管，这里只落库
    SetHotkey(id, key) {
        this.db.Run("UPDATE notes SET hotkey=? WHERE id=?", key, id)
    }

    ; 把某条提到最前（打开/编辑时用，让顺序符合"最近用过"）
    Touch(id) {
        this.db.Run("UPDATE notes SET updated_at=? WHERE id=?", Store.Now(), id)
    }

    /* 删便签。两种类型都要收尾：
         · 待办便签 —— 它的事项与提醒规则一起删（todo_fires 历史留着，
           事后能查"那天到底发没发"）；不做级联是因为"删一张便签顺手删一堆
           事项"正是用户最不想的意外，所以只删它自己名下的。
         · 被别的待办事项关联的普通便签 —— 把指向它的 link_note_id 清 0，
           事项保留、界面上打「关联已失效」，不连带删事项。 */
    Delete(id) {
        nid := Integer(id)
        if (this.KindOf(nid) = "todo") {
            this.db.Exec("DELETE FROM todo_reminders WHERE todo_id IN"
                . " (SELECT id FROM todos WHERE note_id=" nid ")")
            this.db.Exec("DELETE FROM todos WHERE note_id=" nid)
        }
        this.db.Run("UPDATE todos SET link_note_id=0 WHERE link_note_id=?", nid)
        this.db.Run("DELETE FROM notes WHERE id=?", nid)
    }

    Close() {
        this.db.Close()
    }

    ; ---- 内部 ---------------------------------------------------------------

    _Row(m) {
        return {
            id: m["id"],
            ; v4 之前没有这一列；Has 兜一下，否则升级瞬间整个列表读不出来
            kind: (m.Has("kind") && m["kind"] != "") ? m["kind"] : "note",
            title: m["title"],
            body_html: m["body_html"],
            body_text: m["body_text"],
            body_md: m["body_md"],
            mode: m["mode"],
            color: m["color"],
            x: m["x"],
            y: m["y"],
            w: m["w"],
            h: m["h"],
            pinned: m["pinned"] ? 1 : 0,
            hidden: m["hidden"] ? 1 : 0,
            title_locked: (m.Has("title_locked") && m["title_locked"]) ? 1 : 0,
            ; 老库（v3 之前）没有这两列；Has 兜一下，否则升级瞬间整个列表读不出来
            opacity: (m.Has("opacity") && m["opacity"]) ? m["opacity"] : 100,
            hotkey: m.Has("hotkey") ? m["hotkey"] : "",
            created_at: m["created_at"],
            updated_at: m["updated_at"]
        }
    }

    _Rows(rows) {
        out := []
        for r in rows
            out.Push(this._Row(r))
        return out
    }

    static _get(obj, key, def) {
        if (obj is Map)
            return obj.Has(key) ? obj[key] : def
        return obj.HasProp(key) ? obj.%key% : def
    }

    ; Unix 秒（UTC）
    static Now() {
        return DateDiff(A_NowUTC, "19700101000000", "Seconds")
    }
}
