#Requires AutoHotkey v2.0
#ErrorStdOut UTF-8
#SingleInstance Off

#Include ..\lib\sqlite.ahk

out := []
try {
    dbPath := A_ScriptDir "\..\data\_probe.db"
    for f in [dbPath, dbPath "-wal", dbPath "-shm"]
        if FileExist(f)
            FileDelete f

    db := Sqlite(dbPath)
    out.Push("version=" Sqlite.Version())

    db.Exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INTEGER, f REAL, note TEXT)")
    r := db.Run("INSERT INTO t(name,n,f,note) VALUES(?,?,?,?)", "中文标题", 42, 1.5, "he said `"hi`"")
    out.Push("insert id=" r.lastId " changes=" r.changes)

    db.Run("INSERT INTO t(name,n,f,note) VALUES(?,?,?,?)", "second", -7, 0.25, Sqlite.NULL)

    rows := db.Query("SELECT * FROM t ORDER BY id")
    out.Push("rows=" rows.Length)
    for row in rows
        out.Push("  id=" row["id"] " name=" row["name"] " n=" row["n"] " f=" row["f"] " note=[" row["note"] "]")

    out.Push("scalar=" db.Scalar("SELECT count(*) FROM t"))
    out.Push("like=" db.Scalar("SELECT name FROM t WHERE name LIKE ?", "%中文%"))
    out.Push("empty=" (db.Scalar("SELECT name FROM t WHERE id=999") = "" ? "yes" : "no"))

    db.Tx(() => db.Run("UPDATE t SET n=? WHERE id=?", 100, 1))
    out.Push("after tx n=" db.Scalar("SELECT n FROM t WHERE id=1"))

    try {
        db.Run("INSERT INTO nope VALUES(1)")
        out.Push("ERROR: bad sql did not throw")
    } catch as e {
        out.Push("expected-error ok: " SubStr(e.Message, 1, 40))
    }

    db.Close()

    ; 重开验证落盘
    db2 := Sqlite(dbPath)
    out.Push("reopen count=" db2.Scalar("SELECT count(*) FROM t"))
    db2.Close()
} catch as e {
    out.Push("FATAL " e.Message " @" e.Line)
}

s := ""
for i, v in out
    s .= (i > 1 ? "`n" : "") v
try FileDelete A_ScriptDir "\..\data\_probe.log"
FileAppend s "`n", A_ScriptDir "\..\data\_probe.log", "UTF-8-RAW"
ExitApp
