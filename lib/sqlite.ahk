#Requires AutoHotkey v2.0
; ============================================================================
;  sqlite.ahk —— 极简 SQLite 封装（自带 lib\sqlite3.dll，官方 3.53.x x64）
;
;  设计约束（与便签项目强相关，改之前先读）：
;    1. 整个程序只有 AHK 主线程写库，页面永远不直接碰这个类，所有写入都从
;       消息桥进来。所以这里不加锁、不做连接池。
;    2. 文本一律 UTF-8：AHK 内部是 UTF-16，DllCall 的 "Str" 是 ANSI，两个都
;       不对，必须 StrPut(buf, "UTF-8") 后按 "Ptr" 传。
;    3. DllCall 的返回类型必须显式写 "Ptr"（默认 "Int" 会在 x64 上截断指针）。
;    4. 【踩过大坑】不能直接 DllCall("sqlite3.dll\xxx")。DLL 没按路径加载时
;       AHK 不会报错，而是直接访问违例、进程静默退出（0xc0000005），日志都
;       来不及写。所以一律先 LoadLibraryW 绝对路径，再按模块名调用。
;    5. 关闭用 sqlite3_close_v2：有未 finalize 的语句时它会延迟释放，不报 BUSY。
;
;  用法：
;      db := Sqlite("C:\path\notes.db")
;      db.Exec("CREATE TABLE t(a,b)")
;      db.Run("INSERT INTO t VALUES(?,?)", "你好", 42)                ; {changes,lastId}
;      rows := db.Query("SELECT * FROM t WHERE a LIKE ?", "%你%")     ; [Map,...]
;      v := db.Scalar("SELECT count(*) FROM t")
;      db.Close()
; ============================================================================

class SqliteNull {
}

class Sqlite {
    ; 实际用哪个模块名由 _Load 决定：优先系统 winsqlite3.dll（Win10 1607+ 自带，
    ; 3.43.x），没有才退回项目自带的 lib\sqlite3.dll。
    static DLL := "winsqlite3.dll"
    static NULL := SqliteNull()
    static _hmod := 0

    db := 0
    path := ""

    ; flags 默认 READWRITE | CREATE
    __New(path, flags := 0x00000002 | 0x00000004) {
        Sqlite._Load()
        this.path := path
        pPath := Sqlite._Utf8(path)
        ppDb := Buffer(A_PtrSize, 0)
        ; int sqlite3_open_v2(const char*, sqlite3**, int, const char*)
        rc := DllCall(Sqlite.DLL "\sqlite3_open_v2", "Ptr", pPath
            , "Ptr", ppDb, "Int", flags, "Ptr", 0, "Int")
        db := NumGet(ppDb, 0, "Ptr")
        if (rc != 0) {
            err := db ? this._ErrMsg(db) : "rc=" rc
            if (db)
                DllCall(Sqlite.DLL "\sqlite3_close_v2", "Ptr", db, "Int")
            throw Error("打开数据库失败（" rc "）：" err "`n" path)
        }
        this.db := db
        this.Exec("PRAGMA journal_mode=WAL")
        this.Exec("PRAGMA synchronous=NORMAL")
        this.Exec("PRAGMA busy_timeout=3000")
        this.Exec("PRAGMA foreign_keys=ON")
        return this
    }

    ; ---- 基础能力 -----------------------------------------------------------

    ; 执行一段（可多条）SQL，不取结果
    ; int sqlite3_exec(sqlite3*, const char *sql, callback, void *arg, char **errmsg)
    Exec(sql) {
        pSql := Sqlite._Utf8(sql)
        rc := DllCall(Sqlite.DLL "\sqlite3_exec", "Ptr", this.db
            , "Ptr", pSql, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Int")
        if (rc != 0)
            throw Error("SQL 执行失败（" rc "）：" this._ErrMsg() "`nSQL: " SubStr(sql, 1, 300))
        return this
    }

    ; 执行单条带参 SQL，返回受影响行数与自增 id
    Run(sql, params*) {
        stmt := this._Prepare(sql)
        try {
            this._Bind(stmt, params)
            rc := DllCall(Sqlite.DLL "\sqlite3_step", "Ptr", stmt, "Int")
            if (rc != 100 && rc != 101)
                throw Error("SQL 执行失败（" rc "）：" this._ErrMsg() "`nSQL: " SubStr(sql, 1, 300))
            return {
                changes: DllCall(Sqlite.DLL "\sqlite3_changes", "Ptr", this.db, "Int"),
                lastId: DllCall(Sqlite.DLL "\sqlite3_last_insert_rowid", "Ptr", this.db, "Int64")
            }
        } finally {
            DllCall(Sqlite.DLL "\sqlite3_finalize", "Ptr", stmt)
        }
    }

    ; 查询，返回 Array[Map]；列名做键，NULL -> ""
    Query(sql, params*) {
        stmt := this._Prepare(sql)
        try {
            this._Bind(stmt, params)
            nCol := DllCall(Sqlite.DLL "\sqlite3_column_count", "Ptr", stmt, "Int")
            cols := []
            loop nCol {
                pName := DllCall(Sqlite.DLL "\sqlite3_column_name", "Ptr", stmt
                    , "Int", A_Index - 1, "Ptr")
                cols.Push(pName ? StrGet(pName, "UTF-8") : "col" A_Index)
            }
            rows := []
            loop {
                rc := DllCall(Sqlite.DLL "\sqlite3_step", "Ptr", stmt, "Int")
                if (rc = 101)
                    break
                if (rc != 100)
                    throw Error("SQL 查询失败（" rc "）：" this._ErrMsg())
                row := Map()
                loop nCol {
                    i := A_Index - 1
                    typ := DllCall(Sqlite.DLL "\sqlite3_column_type", "Ptr", stmt, "Int", i, "Int")
                    if (typ = 5)                                  ; NULL
                        row[cols[A_Index]] := ""
                    else if (typ = 1)                             ; INTEGER
                        row[cols[A_Index]] := DllCall(Sqlite.DLL "\sqlite3_column_int64"
                            , "Ptr", stmt, "Int", i, "Int64")
                    else if (typ = 2)                             ; FLOAT
                        row[cols[A_Index]] := DllCall(Sqlite.DLL "\sqlite3_column_double"
                            , "Ptr", stmt, "Int", i, "Double")
                    else {                                        ; TEXT / BLOB
                        p := DllCall(Sqlite.DLL "\sqlite3_column_text", "Ptr", stmt, "Int", i, "Ptr")
                        row[cols[A_Index]] := p ? StrGet(p, "UTF-8") : ""
                    }
                }
                rows.Push(row)
            }
            return rows
        } finally {
            DllCall(Sqlite.DLL "\sqlite3_finalize", "Ptr", stmt)
        }
    }

    ; 首行首列；无行返回 ""
    Scalar(sql, params*) {
        rows := this.Query(sql, params*)
        if !rows.Length
            return ""
        for k, v in rows[1]
            return v
        return ""
    }

    ; ---- 事务 ---------------------------------------------------------------

    Begin() => this.Exec("BEGIN IMMEDIATE")
    Commit() => this.Exec("COMMIT")
    Rollback() => this.Exec("ROLLBACK")

    ; 包一层：出错回滚并继续抛出
    Tx(fn) {
        this.Begin()
        try {
            r := fn()
            this.Commit()
            return r
        } catch as e {
            try this.Rollback()
            throw e
        }
    }

    Close() {
        if (this.db) {
            DllCall(Sqlite.DLL "\sqlite3_close_v2", "Ptr", this.db, "Int")
            this.db := 0
        }
    }

    __Delete() {
        this.Close()
    }

    ; ---- 内部 ---------------------------------------------------------------

    ; 显式按绝对路径加载，见文件头第 4 条
    static _Load() {
        if (Sqlite._hmod)
            return
        ; 1) 系统自带（零分发，Win10 1607+ 一定存在）
        sys := A_WinDir "\System32\winsqlite3.dll"
        if FileExist(sys) {
            h := DllCall("LoadLibraryW", "Str", sys, "Ptr")
            if h {
                Sqlite._hmod := h
                Sqlite.DLL := "winsqlite3.dll"
                return
            }
        }
        ; 2) 项目自带兜底
        candidates := [
            A_LineFile "\..\sqlite3.dll",
            A_LineFile "\..\lib\sqlite3.dll",
            A_ScriptDir "\lib\sqlite3.dll",
            A_ScriptDir "\sqlite3.dll",
        ]
        path := ""
        for c in candidates {
            if FileExist(c) {
                path := c
                break
            }
        }
        if (path = "")
            throw Error("找不到可用的 SQLite 库（winsqlite3.dll 与 lib\sqlite3.dll 都没有）。")
        h := DllCall("LoadLibraryW", "Str", path, "Ptr")
        if !h
            throw Error("加载 SQLite 库失败：" path)
        Sqlite._hmod := h
        Sqlite.DLL := "sqlite3.dll"
    }

    _Prepare(sql) {
        pSql := Sqlite._Utf8(sql)
        pStmt := Buffer(A_PtrSize, 0)
        rc := DllCall(Sqlite.DLL "\sqlite3_prepare_v2", "Ptr", this.db
            , "Ptr", pSql, "Int", -1, "Ptr", pStmt, "Ptr", 0, "Int")
        if (rc != 0)
            throw Error("SQL 准备失败（" rc "）：" this._ErrMsg() "`nSQL: " SubStr(sql, 1, 300))
        stmt := NumGet(pStmt, 0, "Ptr")
        if (!stmt)
            throw Error("SQL 为空或只有注释：" SubStr(sql, 1, 120))
        return stmt
    }

    _Bind(stmt, params) {
        for i, v in params {
            if (v is SqliteNull)
                DllCall(Sqlite.DLL "\sqlite3_bind_null", "Ptr", stmt, "Int", i)
            else if (v is Integer)
                DllCall(Sqlite.DLL "\sqlite3_bind_int64", "Ptr", stmt, "Int", i, "Int64", v)
            else if (v is Float)
                DllCall(Sqlite.DLL "\sqlite3_bind_double", "Ptr", stmt, "Int", i, "Double", v)
            else
                this._BindText(stmt, i, String(v))
        }
    }

    _BindText(stmt, idx, s) {
        buf := Sqlite._Utf8(s)
        ; 第 5 参 SQLITE_TRANSIENT = (sqlite3_destructor_type)-1，让 SQLite 自己复制
        DllCall(Sqlite.DLL "\sqlite3_bind_text", "Ptr", stmt, "Int", idx
            , "Ptr", buf, "Int", -1, "Ptr", -1)
    }

    _ErrMsg(db := 0) {
        target := db ? db : this.db
        if !target
            return "(db 未打开)"
        p := DllCall(Sqlite.DLL "\sqlite3_errmsg", "Ptr", target, "Ptr")
        return p ? StrGet(p, "UTF-8") : ""
    }

    static _Utf8(s) {
        buf := Buffer(StrPut(s, "UTF-8"))
        StrPut(s, buf, "UTF-8")
        return buf
    }

    static Version() {
        Sqlite._Load()
        p := DllCall(Sqlite.DLL "\sqlite3_libversion", "Ptr")
        return p ? StrGet(p, "UTF-8") : ""
    }
}
