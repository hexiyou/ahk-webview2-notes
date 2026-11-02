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
;    body_html  富文本模式的正文字面（contenteditable 的 innerHTML）
;    body_text  纯文本副本，只用于搜索与列表摘要，不参与编辑
;    body_md    Markdown 源码（md 模式为正本；rich 模式是 html 转出的近似值）
;    mode       rich | md，决定打开时用哪个编辑器
;    hidden     0/1：仅"不在桌面显示"。列表与托盘仍能看到、能打开
;
;  注意：AHK v2 的续段字符串对缩进极敏感，SQL 一律逐行拼接，不用 "(" 续段。
; ============================================================================

class Store {
    static SCHEMA_VERSION := 2

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
        sql .= " created_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " updated_at INTEGER NOT NULL DEFAULT 0);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_notes_hidden ON notes(hidden);"
        this.db.Exec(sql)

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
        /* 版本号只说明"迁移跑过"，不说明"列真在"。踩过一次：上一版把
           title_locked 只加在迁移分支里，忘了写进 CREATE TABLE，结果新建的库
           版本号直接就是 2、迁移永远不跑，读行时 m["title_locked"] 抛
           "Item has no value"。所以这里不看版本，按 PRAGMA 实测补一次。 */
        this._EnsureColumn("notes", "title_locked", "INTEGER NOT NULL DEFAULT 0")
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
    Create(opts := {}) {
        now := Store.Now()
        sql := "INSERT INTO notes(title, body_html, body_text, body_md, mode, color,"
        sql .= " x, y, w, h, pinned, hidden, created_at, updated_at)"
        sql .= " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        r := this.db.Run(sql
            , Store._get(opts, "title", "")
            , Store._get(opts, "body_html", "")
            , Store._get(opts, "body_text", "")
            , Store._get(opts, "body_md", "")
            , Store._get(opts, "mode", "rich")
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

    /* 正文保存：一次写齐四种表示，updated_at 自动更新。
       title 用 CASE 保护：用户手动改过标题（title_locked=1）以后，正文第一行
       再怎么变都不许盖掉它 —— 否则"重命名"这个功能等于没做。 */
    SaveBody(id, title, html, text, md, mode) {
        sql := "UPDATE notes SET title=CASE WHEN title_locked=1 THEN title ELSE ? END,"
        sql .= " body_html=?, body_text=?, body_md=?, mode=?, updated_at=? WHERE id=?"
        this.db.Run(sql, title, html, text, md, mode, Store.Now(), id)
    }

    ; 用户指定标题：写进去并上锁
    SetTitle(id, title) {
        this.db.Run("UPDATE notes SET title=?, title_locked=1 WHERE id=?", title, id)
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

    ; 把某条提到最前（打开/编辑时用，让顺序符合"最近用过"）
    Touch(id) {
        this.db.Run("UPDATE notes SET updated_at=? WHERE id=?", Store.Now(), id)
    }

    Delete(id) {
        this.db.Run("DELETE FROM notes WHERE id=?", id)
    }

    Close() {
        this.db.Close()
    }

    ; ---- 内部 ---------------------------------------------------------------

    _Row(m) {
        return {
            id: m["id"],
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
