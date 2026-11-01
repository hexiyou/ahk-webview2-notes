#Requires AutoHotkey v2.0
#ErrorStdOut UTF-8
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
logPath := A_ScriptDir "\..\data\_store.log"
if FileExist(logPath)
    FileDelete logPath
W(s) => FileAppend(s "`n", logPath, "UTF-8-RAW")
out := []
try {
    dbp := A_ScriptDir "\..\data\_store.db"
    for f in [dbp, dbp "-wal", dbp "-shm"]
        if FileExist(f)
            FileDelete f
    st := Store(dbp)
    W("count0=" st.Count())
    id1 := st.Create(Map("title", "买菜", "body_html", "<p>鸡蛋、牛奶</p>", "body_text", "鸡蛋、牛奶", "body_md", "鸡蛋、牛奶", "color", "yellow", "x", 100, "y", 120))
    id2 := st.Create(Map("title", "工作", "body_text", "写周报", "hidden", 1, "pinned", 1, "color", "blue"))
    W("ids=" id1 "," id2 " count=" st.Count())
    W("visible=" st.Visible().Length " (hidden 那条应被排除)")
    n := st.Get(id1)
    W("get1 title=" n.title " color=" n.color " x=" n.x " y=" n.y " mode=" n.mode)
    st.SaveBody(id1, "买菜（改）", "<p>鸡蛋、牛奶、面包</p>", "鸡蛋、牛奶、面包", "鸡蛋、牛奶、面包", "rich")
    W("after save title=" st.Get(id1).title)
    W("search 面包 -> " st.Search("面包").Length "  条；search 周报(隐藏) -> " st.Search("周报").Length " 条")
    st.SetGeometry(id1, 10, 20, 400, 500)
    st.SetPinned(id1, 1)
    g := st.Get(id1)
    W("geo=" g.x "," g.y "," g.w "," g.h " pinned=" g.pinned)
    W("visible now=" st.Visible().Length " 第一条=" st.Visible()[1].title)
    st.SetHidden(id1, 1)
    W("hide1 -> visible=" st.Visible().Length)
    st.SetHidden(id1, 0)
    W("show1 -> visible=" st.Visible().Length)
    st.Delete(id2)
    W("after delete count=" st.Count())
    st.Close()

    st2 := Store(dbp)
    W("reopen count=" st2.Count() " first=" st2.All()[1].title)
    st2.Close()
} catch as e {
    W("FATAL " e.What " " e.Message " @" e.Line)
}
