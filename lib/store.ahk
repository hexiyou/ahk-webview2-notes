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
    static SCHEMA_VERSION := 1

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
        sql .= " created_at INTEGER NOT NULL DEFAULT 0,"
        sql .= " updated_at INTEGER NOT NULL DEFAULT 0);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_notes_updated ON notes(updated_at DESC);"
        sql .= "CREATE INDEX IF NOT EXISTS idx_notes_hidden ON notes(hidden);"
        this.db.Exec(sql)

        cur := this.db.Scalar("SELECT v FROM meta WHERE k='schema_version'")
        if (cur = "")
            this.db.Run("INSERT INTO meta(k,v) VALUES('schema_version',?)", String(Store.SCHEMA_VERSION))
        ; 后续版本按 cur 做增量迁移
    }

    ; ---- 读 -----------------------------------------------------------------

    ; 全部便签（含 hidden），最近更新的在前
    All() {
        return this._Rows(this.db.Query("SELECT * FROM notes ORDER BY pinned DESC, updated_at DESC, id DESC"))
    }

    ; 桌面上的那些：置顶优先
    Visible() {
        return this._Rows(this.db.Query("SELECT * FROM notes WHERE hidden=0 ORDER BY pinned DESC, updated_at DESC, id DESC"))
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
        sql .= " ORDER BY updated_at DESC, id DESC"
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
        sql .= " ORDER BY updated_at DESC, id DESC"
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

    ; 正文保存：一次写齐四种表示，updated_at 自动更新
    SaveBody(id, title, html, text, md, mode) {
        sql := "UPDATE notes SET title=?, body_html=?, body_text=?, body_md=?, mode=?, updated_at=? WHERE id=?"
        this.db.Run(sql, title, html, text, md, mode, Store.Now(), id)
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
