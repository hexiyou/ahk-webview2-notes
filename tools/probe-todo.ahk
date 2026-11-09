#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\todo-store.ahk

; 待办数据层：v4 迁移 / 事项 CRUD / 排序 / 状态 / 摘要 / 关联失效。
; 不建窗口、不碰 WebView2 —— 这一层出问题必须在最快的循环里抓到。
logPath := A_ScriptDir "\..\data\_todo.log"
if FileExist(logPath)
    FileDelete logPath
W(s) => FileAppend(s "`n", logPath, "UTF-8-RAW")

global PASS := 0, FAIL := 0
Say(name, ok, detail := "") {
    global PASS, FAIL
    if ok
        PASS += 1
    else
        FAIL += 1
    W((ok ? "PASS " : "FAIL ") name (detail != "" ? "  [" detail "]" : ""))
}

; 先把上次的测试库清干净（含 -wal / -shm，否则旧事务会粘上来）
dbp := A_ScriptDir "\..\data\_todo.db"
for f in [dbp, dbp "-wal", dbp "-shm"]
    if FileExist(f)
        try FileDelete f

try {
    ; ---- 1. 全新的库 ------------------------------------------------------
    st := Store(dbp)
    TodoStore.Attach(st)
    Say("新库 schema_version=4", st.db.Scalar("SELECT v FROM meta WHERE k='schema_version'") = "4"
        , st.db.Scalar("SELECT v FROM meta WHERE k='schema_version'"))
    tabs := 0
    for r in st.db.Query("SELECT name FROM sqlite_master WHERE type='table'")
        if (r["name"] = "todos" || r["name"] = "todo_reminders" || r["name"] = "todo_fires")
            tabs += 1
    Say("三张待办表都建出来了", tabs = 3, tabs)

    ; ---- 2. 两种类型共存 --------------------------------------------------
    nid := st.Create(Map("title", "普通", "body_text", "正文", "body_md", "正文"
        , "body_html", "<div>正文</div>"))
    tid := st.Create(Map("kind", "todo", "title", "本周上线", "w", 460, "h", 540
        , "body_text", "这段不该被写进去"))
    Say("普通便签 kind=note", st.Get(nid).kind = "note", st.Get(nid).kind)
    Say("待办便签 kind=todo", st.Get(tid).kind = "todo", st.Get(tid).kind)
    Say("创建时传的正文对待办便签被忽略", st.Get(tid).body_text = ""
        , "[" st.Get(tid).body_text "]")
    Say("KindOf 两条路都对", st.KindOf(nid) = "note" && st.KindOf(tid) = "todo"
        , st.KindOf(nid) "/" st.KindOf(tid))
    Say("几何按传入值落库", st.Get(tid).w = 460 && st.Get(tid).h = 540
        , st.Get(tid).w "x" st.Get(tid).h)

    ; ---- 3. 事项默认值与 seq ---------------------------------------------
    a1 := TodoStore.Add(tid, Map("title", "写方案"))
    a2 := TodoStore.Add(tid, Map("title", "评审"))
    a3 := TodoStore.Add(tid, Map("title", "上线"))
    it1 := TodoStore.Get(a1)
    Say("默认状态 todo", it1.status = "todo", it1.status)
    Say("默认时间为 0（未设置）", it1.start_at = 0 && it1.due_at = 0
        , it1.start_at "/" it1.due_at)
    Say("seq 从 1000 起步、每次 +1000", it1.seq = 1000 && TodoStore.Get(a2).seq = 2000
        && TodoStore.Get(a3).seq = 3000, it1.seq "/" TodoStore.Get(a2).seq "/" TodoStore.Get(a3).seq)
    Say("列表按 seq 排", TodoStore.Items(tid).Length = 3
        && TodoStore.Items(tid)[1].title = "写方案"
        && TodoStore.Items(tid)[3].title = "上线")

    ; ---- 4. 摘要与派生正文 -----------------------------------------------
    Say("摘要 body_md 是清单", InStr(st.Get(tid).body_md, "- [ ] 写方案") = 1
        , "[" st.Get(tid).body_md "]")
    Say("摘要 body_text 带标题", InStr(st.Get(tid).body_text, "写方案") > 0)
    Say("摘要 body_html 带事项标题", InStr(st.Get(tid).body_html, "写方案") > 0)
    TodoStore.Delete(a3)
    Say("删事项后摘要同步", InStr(st.Get(tid).body_text, "上线") = 0
        , "[" st.Get(tid).body_text "]")

    ; ---- 5. 正文保存 / 自动标题 / 上锁 -----------------------------------
    TodoStore.Save(a1, "", '<div>第一行内容</div>', "第一行内容`n第二行", "第一行内容`n第二行")
    Say("空标题按正文首行生成", TodoStore.Get(a1).title = "第一行内容"
        , TodoStore.Get(a1).title)
    Say("保存正文后摘要跟着变", InStr(st.Get(tid).body_text, "第二行") > 0)
    TodoStore.SetTitle(a1, "手起的名字")
    TodoStore.Save(a1, "", '<div>换了首行</div>', "换了首行", "换了首行")
    Say("标题上锁后不被正文覆盖", TodoStore.Get(a1).title = "手起的名字"
        , TodoStore.Get(a1).title)
    Say("正文本身确实更新了", InStr(TodoStore.Get(a1).body_text, "换了首行") > 0)

    ; ---- 6. 状态流转 -----------------------------------------------------
    TodoStore.SetStatus(a1, "done")
    it := TodoStore.Get(a1)
    Say("done 写 done_at 并清 canceled_at", it.done_at > 0 && it.canceled_at = 0
        , it.done_at "/" it.canceled_at)
    Say("done 的清单项打勾", InStr(st.Get(tid).body_md, "- [x] 手起的名字") > 0
        , st.Get(tid).body_md)
    TodoStore.SetStatus(a1, "canceled")
    it := TodoStore.Get(a1)
    Say("改 canceled 后 done_at 清零", it.done_at = 0 && it.canceled_at > 0)
    TodoStore.SetStatus(a1, "todo")
    it := TodoStore.Get(a1)
    Say("改回 todo 两个时间戳都清", it.done_at = 0 && it.canceled_at = 0)
    TodoStore.SetStatus(a2, "bogus")
    Say("非法状态值退回 todo", TodoStore.Get(a2).status = "todo"
        , TodoStore.Get(a2).status)

    ; ---- 7. 排序（拖动 = MoveTo） ----------------------------------------
    b1 := TodoStore.Add(tid, Map("title", "B1"))
    b2 := TodoStore.Add(tid, Map("title", "B2"))
    ; 当前顺序：a1(手起的名字) / a2(评审) / B1 / B2
    TodoStore.MoveTo(tid, b2, 1)
    order := []
    for it in TodoStore.Items(tid)
        order.Push(it.title)
    Say("拖到第 1 位后顺序对", order[1] = "B2" && order.Length = 4, JoinArr(order))
    Say("拖动只改一条、seq 仍递增", IsAsc(TodoStore.Items(tid)))
    TodoStore.MoveTo(tid, b1, 4)
    order := []
    for it in TodoStore.Items(tid)
        order.Push(it.title)
    Say("拖到末位后顺序对", order[4] = "B1", JoinArr(order))
    TodoStore.MoveTo(tid, b1, 4)
    Say("原地不动不产生写库（返回 1 且顺序不变）", IsAsc(TodoStore.Items(tid)))

    ; 缝隙耗尽 → 整页重编号。先把 seq 按当前顺序压成 1、2、3、4（模拟长时间
    ; 反复相邻插入之后的"缝隙用完"），再把末位拖到第 2 位。
    i := 0
    for it in TodoStore.Items(tid)
        st.db.Run("UPDATE todos SET seq=? WHERE id=?", ++i, it.id)
    last := TodoStore.Items(tid)[4]
    TodoStore.MoveTo(tid, last.id, 2)
    its := TodoStore.Items(tid)
    Say("缝隙耗尽后重编号成 1000 步长"
        , its[1].seq = 1000 && its[2].seq = 2000 && its[3].seq = 3000 && its[4].seq = 4000
        , its[1].seq "/" its[2].seq "/" its[3].seq "/" its[4].seq)
    Say("重编号后顺序仍然对", its[2].id = last.id, JoinArr(Titles(tid)))

    ; ---- 8. 时间与逾期（注入 now，不等真实时间） --------------------------
    now := 1762736400
    TodoStore.SetTimes(b1, now - 86400, now - 3600)
    Say("时间落库", TodoStore.Get(b1).start_at = now - 86400
        && TodoStore.Get(b1).due_at = now - 3600)
    Say("逾期只在非终态计数", TodoStore.Summary(tid, now).overdue = 1
        , TodoStore.Summary(tid, now).overdue)
    TodoStore.SetStatus(b1, "done")
    Say("完成后不再算逾期", TodoStore.Summary(tid, now).overdue = 0
        , TodoStore.Summary(tid, now).overdue)
    s := TodoStore.Summary(tid, now)
    Say("汇总：总数/完成数", s.total = 4 && s.done = 1, s.total "/" s.done)
    TodoStore.SetTimes(b1, -5, -5)
    Say("负数时间被夹成 0", TodoStore.Get(b1).start_at = 0 && TodoStore.Get(b1).due_at = 0)

    ; ---- 9. 关联便签 -----------------------------------------------------
    Say("关联普通便签成功", TodoStore.SetLink(b1, nid) = 1)
    it := TodoStore.Get(b1)
    Say("关联后查得到标题", it.link_note_id = nid && it.link_title = "普通" && it.link_ok = 1
        , it.link_title)
    Say("不许关联自己所在的待办便签", TodoStore.SetLink(b1, tid) = 0)
    Say("关联不存在的便签被拒", TodoStore.SetLink(b1, 99999) = 0)
    st.Delete(nid)
    it := TodoStore.Get(b1)
    Say("被关联便签删除后关联清零、事项保留"
        , it.link_note_id = 0 && it.link_ok = 0 && TodoStore.Count(tid) = 4
        , it.link_note_id "/" it.link_title)

    ; ---- 10. 派生正文只读 ------------------------------------------------
    before := st.Get(tid).body_html
    r := st.SaveBody(tid, "不该写进去", "<div>x</div>", "x", "x", "rich")
    Say("SaveBody 对待办便签返回 0", r = 0, r)
    Say("SaveBody 真没写进去", st.Get(tid).body_html = before && st.Get(tid).title = "本周上线")

    ; ---- 11. 删待办便签连带清事项 ---------------------------------------
    st.db.Run("INSERT INTO todo_reminders(todo_id, kind) VALUES(?, 'offset')", b1)
    st.Delete(tid)
    Say("删便签后事项清空", st.db.Scalar("SELECT count(*) FROM todos WHERE note_id=?", tid) = 0)
    Say("删便签后提醒规则清空"
        , st.db.Scalar("SELECT count(*) FROM todo_reminders WHERE todo_id=?", b1) = 0)
    Say("删便签后便签行也没了", st.Get(tid) = 0)
    st.Close()

    ; ---- 12. 老库（v3）升级 ---------------------------------------------
    oldp := A_ScriptDir "\..\data\_todo_v3.db"
    for f in [oldp, oldp "-wal", oldp "-shm"]
        if FileExist(f)
            try FileDelete f
    odb := Sqlite(oldp)
    odb.Exec("CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);")
    odb.Exec("INSERT INTO meta(k,v) VALUES('schema_version','3');")
    odb.Exec("CREATE TABLE notes(id INTEGER PRIMARY KEY AUTOINCREMENT,"
        . " title TEXT NOT NULL DEFAULT '', body_html TEXT NOT NULL DEFAULT '',"
        . " body_text TEXT NOT NULL DEFAULT '', body_md TEXT NOT NULL DEFAULT '',"
        . " mode TEXT NOT NULL DEFAULT 'rich', color TEXT NOT NULL DEFAULT 'yellow',"
        . " x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,"
        . " w INTEGER NOT NULL DEFAULT 300, h INTEGER NOT NULL DEFAULT 280,"
        . " pinned INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0,"
        . " title_locked INTEGER NOT NULL DEFAULT 0, opacity INTEGER NOT NULL DEFAULT 100,"
        . " hotkey TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0,"
        . " updated_at INTEGER NOT NULL DEFAULT 0);")
    odb.Run("INSERT INTO notes(title, body_text) VALUES(?,?)", "老便签", "老正文")
    odb.Run("INSERT INTO notes(title, body_text, pinned) VALUES(?,?,1)", "老置顶", "x")
    odb.Exec("PRAGMA journal_mode=DELETE")
    odb.Close()

    ost := Store(oldp)
    Say("老库升到 v4", ost.db.Scalar("SELECT v FROM meta WHERE k='schema_version'") = "4"
        , ost.db.Scalar("SELECT v FROM meta WHERE k='schema_version'"))
    rows := ost.All()
    Say("老库两条数据都在", rows.Length = 2, rows.Length)
    Say("老行 kind 补成 note", rows[1].kind = "note" && rows[2].kind = "note"
        , rows[1].kind "/" rows[2].kind)
    txt := Map()
    for r in rows
        txt[r.title] := r.body_text
    Say("老行正文没被迁移动过", txt["老便签"] = "老正文" && txt["老置顶"] = "x"
        , txt["老便签"] "/" txt["老置顶"])
    Say("老行置顶保留", (rows[1].pinned + rows[2].pinned) = 1)
    x := ost.Create(Map("kind", "todo", "title", "t"))
    Say("升级后的库能建待办", x > 0 && ost.Get(x).kind = "todo", x)
    Say("升级后的库能筛 kind",
        ost.Query("", "default", 1, Map("kind", 1)).Length = 1
        && ost.Query("", "default", 1, Map("kind", 0)).Length = 2
        , ost.Query("", "default", 1, Map("kind", 1)).Length "/"
        . ost.Query("", "default", 1, Map("kind", 0)).Length)
    ost.Close()
} catch as e {
    W("FATAL " e.What " " e.Message " @" e.Line)
    FAIL += 1
}

W("=== 结束：PASS " PASS " / FAIL " FAIL)

; ---- 小工具 ---------------------------------------------------------------
JoinArr(a) {
    s := ""
    for v in a
        s .= (s = "" ? "" : " | ") v
    return s
}

Titles(tid) {
    out := []
    for it in TodoStore.Items(tid)
        out.Push(it.title)
    return out
}

IsAsc(items) {
    prev := -1
    for it in items {
        if (it.seq <= prev)
            return false
        prev := it.seq
    }
    return true
}
