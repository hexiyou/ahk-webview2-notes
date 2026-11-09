#Requires AutoHotkey v2.0
; ============================================================================
;  todo-store.ahk —— 待办事项的数据访问层
;
;  职责边界（和 store.ahk 一样重要）：
;    · 只管 todos 这张表和它带给 notes 的派生摘要，不碰窗口、不碰 WebView2。
;    · 时间一律 Unix 秒（UTC 整数），0 = 未设置。展示层的本地时间转换在页面里。
;    · 事项的正文正本是 todos.body_html / body_md / body_text，与普通便签同构。
;
;  ★ notes.body_* 对一张待办便签是**派生摘要**，由 _Refresh 在同一个事务里重算：
;      body_text  所有事项标题 + 正文，供搜索与列表摘要
;      body_md    "- [ ] 标题" 清单，供 Markdown 导出
;      body_html  事项正文拼起来，让列表的「含图片 / 含代码块」角标免费可用
;    所以任何"直接写待办便签正文"的路径都必须绕开（Store.SaveBody 里已拦）。
;
;  排序：seq 用留空隙的整数（1000 起步，插入取中值）。一次拖动只 UPDATE 一条；
;  只有缝隙耗尽（差 ≤ 1）才把这一页重新编号成 1000、2000……
; ============================================================================

class TodoStore {
    static S := 0                                  ; Store 实例（由 App 注入）
    static STATUSES := ["todo", "doing", "done", "canceled"]
    static SEQ_STEP := 1000
    static SOFT_MAX := 500                         ; 单页事项软上限（UI 层提示，不是库限制）

    static Attach(store) => TodoStore.S := store
    static db() => TodoStore.S.db

    ; ---- 读 -----------------------------------------------------------------

    /* 一个待办便签下的全部事项，按 seq 排。
       关联便签的标题随行查出来（LEFT JOIN），避免渲染时 N+1 次查询；
       被关联的便签已经删了就是空串，页面据此打「关联已失效」。 */
    static Items(noteID) {
        rows := TodoStore.db().Query("SELECT t.*, n.title AS link_title FROM todos t"
            . " LEFT JOIN notes n ON n.id = t.link_note_id"
            . " WHERE t.note_id=? ORDER BY t.seq, t.id", noteID)
        out := []
        for r in rows
            out.Push(TodoStore._Row(r))
        return out
    }

    static Get(id) {
        rows := TodoStore.db().Query("SELECT t.*, n.title AS link_title FROM todos t"
            . " LEFT JOIN notes n ON n.id = t.link_note_id WHERE t.id=?", id)
        return rows.Length ? TodoStore._Row(rows[1]) : 0
    }

    static Count(noteID) {
        return TodoStore.db().Scalar("SELECT count(*) FROM todos WHERE note_id=?", noteID)
    }

    /* 列表页要的一句话进度：{total, done, doing, canceled, overdue}
       overdue 现算不落库 —— 逾期是时间的函数，存下来就会过期。 */
    static Summary(noteID, now := 0) {
        if !now
            now := Store.Now()
        r := TodoStore.db().Query("SELECT"
            . " count(*) AS total,"
            . " sum(CASE WHEN status='done' THEN 1 ELSE 0 END) AS done,"
            . " sum(CASE WHEN status='doing' THEN 1 ELSE 0 END) AS doing,"
            . " sum(CASE WHEN status='canceled' THEN 1 ELSE 0 END) AS canceled,"
            . " sum(CASE WHEN status IN ('todo','doing') AND due_at>0 AND due_at<?"
            . " THEN 1 ELSE 0 END) AS overdue"
            . " FROM todos WHERE note_id=?", now, noteID)
        m := r.Length ? r[1] : Map()
        return {
            total: TodoStore._num(m, "total"),
            done: TodoStore._num(m, "done"),
            doing: TodoStore._num(m, "doing"),
            canceled: TodoStore._num(m, "canceled"),
            overdue: TodoStore._num(m, "overdue")
        }
    }

    ; ---- 写 -----------------------------------------------------------------

    /* 新建事项，追加到列表末尾。返回新 id。
       opts：title / body_html / body_text / body_md / status / start_at / due_at /
             link_note_id / seq */
    static Add(noteID, opts := 0) {
        o := IsObject(opts) ? opts : Map()
        now := Store.Now()
        seq := TodoStore._num(o, "seq", 0)
        if (seq <= 0)
            seq := TodoStore._nextSeq(noteID)
        status := TodoStore._status(TodoStore._get(o, "status", "todo"))
        db := TodoStore.db()
        id := 0
        db.Begin()
        try {
            id := db.Run("INSERT INTO todos(note_id, seq, title, body_html,"
                . " body_text, body_md, status, start_at, due_at, link_note_id,"
                . " created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)"
                , noteID, seq
                , TodoStore._get(o, "title", "")
                , TodoStore._get(o, "body_html", "")
                , TodoStore._get(o, "body_text", "")
                , TodoStore._get(o, "body_md", "")
                , status
                , TodoStore._int(TodoStore._get(o, "start_at", 0))
                , TodoStore._int(TodoStore._get(o, "due_at", 0))
                , TodoStore._int(TodoStore._get(o, "link_note_id", 0))
                , now, now).lastId
            TodoStore._Refresh(noteID)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return id
    }

    /* 保存一个事项的正文。title 为空时按正文首行自动生成（与便签同一套规则），
       用户手动改过标题（title_locked=1）就不再跟着正文变。 */
    static Save(id, title, html, text, md) {
        it := TodoStore.Get(id)
        if !it
            return 0
        t := Trim(title)
        if (t = "")
            t := Store.AutoTitle(text)
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("UPDATE todos SET title=CASE WHEN title_locked=1"
                . " THEN title ELSE ? END, body_html=?, body_text=?, body_md=?,"
                . " updated_at=? WHERE id=?", t, html, text, md, Store.Now(), id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    ; 用户亲自命名：写进去并上锁
    static SetTitle(id, title) {
        it := TodoStore.Get(id)
        if !it
            return 0
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("UPDATE todos SET title=?, title_locked=1, updated_at=?"
                . " WHERE id=?", title, Store.Now(), id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    /* 状态流转。done / canceled 是终态：写对应的时间戳、清掉另一个；
       改回 todo / doing 时两个时间戳都清零（否则"完成后撤回"会留下一个假的完成时间）。
       进入终态时顺手把这张事项的提醒规则停掉（P2 的调度器只认 enabled）。 */
    static SetStatus(id, status) {
        it := TodoStore.Get(id)
        if !it
            return 0
        st := TodoStore._status(status)
        now := Store.Now()
        doneAt := (st = "done") ? now : 0
        cancelAt := (st = "canceled") ? now : 0
        terminal := (st = "done" || st = "canceled")
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("UPDATE todos SET status=?, done_at=?, canceled_at=?,"
                . " updated_at=? WHERE id=?", st, doneAt, cancelAt, now, id)
            if terminal
                db.Run("UPDATE todo_reminders SET enabled=0, next_fire_at=0,"
                    . " updated_at=? WHERE todo_id=?", now, id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    static SetTimes(id, startAt, dueAt) {
        it := TodoStore.Get(id)
        if !it
            return 0
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("UPDATE todos SET start_at=?, due_at=?, updated_at=?"
                . " WHERE id=?", TodoStore._int(startAt), TodoStore._int(dueAt), Store.Now(), id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    /* 关联一张普通便签。0 = 取消关联。
       不许关联自己所在的那张待办便签（会得到一个点进去回到原地的死循环）。 */
    static SetLink(id, noteID) {
        it := TodoStore.Get(id)
        if !it
            return 0
        target := TodoStore._int(noteID)
        if (target = it.note_id)
            return 0
        if (target > 0 && !TodoStore.S.Get(target))
            return 0
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("UPDATE todos SET link_note_id=?, updated_at=? WHERE id=?"
                , target, Store.Now(), id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    /* 移到第 idx 位（1 基）。拖动与上下箭头共用这一份实现。
       返回 1 = 成功（含"本来就在这个位置"），0 = 没这条 / 只有一条。 */
    static MoveTo(noteID, id, idx) {
        rows := TodoStore.db().Query("SELECT id, seq FROM todos WHERE note_id=?"
            . " ORDER BY seq, id", noteID)
        n := rows.Length
        if (n < 2)
            return 0
        seqMap := Map(), order := [], cur := 0
        for i, r in rows {
            seqMap[r["id"]] := r["seq"]
            if (r["id"] = id)
                cur := i
            else
                order.Push(r["id"])
        }
        if !cur
            return 0
        idx := Max(1, Min(Integer(idx), n))
        order.InsertAt(idx, id)
        if (idx = cur)
            return 1                            ; 没动，别写库

        lo := (idx > 1) ? seqMap[order[idx - 1]] : 0
        hi := (idx < n) ? seqMap[order[idx + 1]] : 0
        newSeq := 0, renumber := false
        if (lo = 0 && hi = 0)
            newSeq := TodoStore.SEQ_STEP
        else if (lo = 0)
            newSeq := (hi >= TodoStore.SEQ_STEP * 2) ? hi - TodoStore.SEQ_STEP : Floor(hi / 2)
        else if (hi = 0)
            newSeq := lo + TodoStore.SEQ_STEP
        else if (hi - lo >= 2)
            newSeq := lo + Floor((hi - lo) / 2)
        if (lo > 0 && newSeq <= lo) || (hi > 0 && newSeq >= hi)
            renumber := true
        /* 缝隙用完（相邻 seq 差 0 或 1）时整页重编号成 1000、2000……
           这是唯一会写 N 行的时刻，顺序绝对确定，代价可控。 */
        now := Store.Now()
        db := TodoStore.db()
        db.Begin()
        try {
            if renumber {
                for i, sid in order
                    db.Run("UPDATE todos SET seq=? WHERE id=?", i * TodoStore.SEQ_STEP, sid)
                db.Run("UPDATE todos SET updated_at=? WHERE id=?", now, id)
            } else {
                db.Run("UPDATE todos SET seq=?, updated_at=? WHERE id=?", newSeq, now, id)
            }
            TodoStore._Refresh(noteID)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    ; 恢复自动标题：解锁并按正文首行重算。返回新标题
    static ClearTitle(id) {
        it := TodoStore.Get(id)
        if !it
            return ""
        t := Store.AutoTitle(it.body_text)
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("UPDATE todos SET title=?, title_locked=0, updated_at=? WHERE id=?"
                , t, Store.Now(), id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return t
    }

    /* 物理删除。提醒规则一起删，触发历史（todo_fires）留着排查。 */
    static Delete(id) {
        it := TodoStore.Get(id)
        if !it
            return 0
        db := TodoStore.db()
        db.Begin()
        try {
            db.Run("DELETE FROM todo_reminders WHERE todo_id=?", id)
            db.Run("DELETE FROM todos WHERE id=?", id)
            TodoStore._Refresh(it.note_id)
            db.Commit()
        } catch as e {
            try db.Rollback()
            throw e
        }
        return 1
    }

    ; ---- 内部 ---------------------------------------------------------------

    static _nextSeq(noteID) {
        last := TodoStore.db().Scalar("SELECT max(seq) FROM todos WHERE note_id=?", noteID)
        return Integer(last ? last : 0) + TodoStore.SEQ_STEP
    }

    /* 重算这张待办便签的摘要（notes.body_*）。调用方负责包事务 —— 它必须和
       "写事项"在同一个事务里，否则中途失败会留下"事项变了、摘要还是旧的"。 */
    static _Refresh(noteID) {
        rows := TodoStore.db().Query("SELECT * FROM todos WHERE note_id=? ORDER BY seq, id"
            , noteID)
        text := "", md := "", html := ""
        for r in rows {
            title := r["title"]
            if (title = "")
                title := Store.AutoTitle(r["body_text"])
            if (title = "")
                title := "（无标题）"
            if (text != "")
                text .= "`n`n"
            text .= title
            if (Trim(r["body_text"]) != "")
                text .= "`n" r["body_text"]

            if (md != "")
                md .= "`n"
            md .= "- [" (r["status"] = "done" ? "x" : " ") "] " title

            html .= '<div class="qn-todo-item" data-status="' r["status"] '">'
            html .= '<div class="qn-todo-title">' TodoStore._esc(title) '</div>'
            html .= r["body_html"]
            html .= '</div>'
        }
        if (rows.Length)
            html := '<div class="qn-todo-list">' html '</div>'
        TodoStore.db().Run("UPDATE notes SET body_text=?, body_md=?, body_html=?,"
            . " updated_at=? WHERE id=?", text, md, html, Store.Now(), noteID)
    }

    static _Row(m) {
        st := TodoStore._status(TodoStore._get(m, "status", "todo"))
        linkID := TodoStore._num(m, "link_note_id")
        return {
            id: m["id"],
            note_id: m["note_id"],
            seq: TodoStore._num(m, "seq"),
            title: m["title"],
            title_locked: TodoStore._num(m, "title_locked"),
            body_html: m["body_html"],
            body_text: m["body_text"],
            body_md: m["body_md"],
            status: st,
            start_at: TodoStore._num(m, "start_at"),
            due_at: TodoStore._num(m, "due_at"),
            done_at: TodoStore._num(m, "done_at"),
            canceled_at: TodoStore._num(m, "canceled_at"),
            link_note_id: linkID,
            /* 关联便签已经不在了：link_note_id 还在，但 JOIN 不出标题。
               Store.Delete 会把它清零，这里是"库被手改过"时的兜底。 */
            link_title: TodoStore._get(m, "link_title", ""),
            link_ok: (linkID > 0 && TodoStore._get(m, "link_title", "") != "") ? 1 : 0,
            created_at: TodoStore._num(m, "created_at"),
            updated_at: TodoStore._num(m, "updated_at")
        }
    }

    static _status(v) {
        v := (v = "" || v = 0) ? "todo" : String(v)
        for s in TodoStore.STATUSES {
            if (s = v)
                return s
        }
        return "todo"
    }

    static _int(v) {
        if (v = "" || !IsNumber(v))
            return 0
        return Max(0, Integer(v))
    }

    static _num(m, key, def := 0) {
        if !(m is Map) || !m.Has(key)
            return def
        v := m[key]
        return (v = "") ? def : v
    }

    static _get(m, key, def := "") {
        if (m is Map)
            return m.Has(key) ? m[key] : def
        return m.HasProp(key) ? m.%key% : def
    }

    static _esc(s) {
        s := StrReplace(s, "&", "&amp;")
        s := StrReplace(s, "<", "&lt;")
        s := StrReplace(s, ">", "&gt;")
        return s
    }
}
