#Requires AutoHotkey v2.0
; ============================================================================
;  reminder.ahk —— 提醒调度内核（P2）
;
;  职责边界：
;    · 只管 "什么时候该响"：规则 → next_fire_at → tick → todo_fires 记账。
;    · 投递（SMTP / Webhook / 外部程序）是 P3 的事。这里只留一个 Hook，
;      默认实现是托盘提示 —— 进程内、非阻塞、不需要子进程。
;    · 不碰窗口、不碰 WebView2。页面要的数据由宿主转成 JSON。
;
;  三条不能破的约定：
;    1) 时间一律 Unix 秒（UTC），0 = 未设置。展示层的本地化在页面里做。
;    2) 所有判定用绝对时间比较，不用倒计时累加 —— 改系统时间、合盖唤醒
;       都不会让提醒漂移。
;    3) 主进程只挑作业 + 记账，绝不在这里做任何可能阻塞的事。AHK 是单
;       OS 线程的协作式调度，一次 10 秒超时会把所有便签窗口一起冻住。
;
;  幂等三层（设计文档 §5.4）：
;    数据  UNIQUE(todo_id, reminder_id, fire_at) + INSERT OR IGNORE
;    状态  发之前先写 'sending'
;    进程  子进程带 fire_id（P3）
; ============================================================================

class Reminder {
    static S := 0                    ; Store 实例（由 App 注入）
    static Clock := 0                ; 假时钟（测试注入；0 = 用真实时间）
    static Busy := false             ; tick 重入保护
    static Hook := 0                 ; 投递器：Hook(fire) -> {ok, detail}（自检用）
    /* P3 的派发器：Notifier(fire) -> {ok,pending} / 0。0 表示没接投递通道
       （探针单独 include 本文件时就是 0），这时一律走托盘提示。 */
    static Notifier := 0
    static GRACE := 600              ; 错过宽限：10 分钟内补发，更早只记 missed
    static SENDING_TIMEOUT := 300    ; sending 超过 5 分钟没回执 = 子进程崩了

    static Attach(store) {
        Reminder.S := store
        /* 事项的时间一改，它的规则就得重算。用钩子而不是直接调：probe-todo
           这类只测数据层的探针不加载 todo-store，硬引用会当场报错。 */
        try {
            TodoStore.OnTimesChange := ObjBindMethod(Reminder, "RefreshTodoByNote")
        } catch {
            ; 没有 TodoStore，忽略
        }
        return 1
    }

    static db() => Reminder.S.db

    /* 现在几点。测试把它拨到任意时刻，Tick 就跟着走假时钟 ——
       否则"跑一整天"这种验收只能等真实时间，等于没法测。 */
    static Now() => Reminder.Clock ? Reminder.Clock : Store.Now()

    ; ---- 时间转换 -----------------------------------------------------------

    /* 本地墙钟（YYYYMMDDHH24MISS 字符串）→ Unix 秒。
       DateDiff 把两个本地时间相减得到"墙钟差"，再叠上真实 UTC 秒数。
       国内无夏令时，所以墙钟差 == 真实流逝（设计文档 §5.2 写明了这个边界；
       以后要支持夏令时，这里是唯一改动点）。 */
    static EpochOfLocal(wall) {
        return DateDiff(wall, A_Now, "Seconds") + Store.Now()
    }

    /* Unix 秒 → 本地 14 位时间戳字符串（给 FormatTime / DateAdd 用）。
       ⚠ 别写成 DateAdd("19700101000000", ts)：那个基点是"本地 1970-01-01 00:00"，
       而 Unix 0 在 UTC+8 是"本地 08:00"，直接加会整体偏 8 小时。
       正确做法是从"现在"出发做相对位移 —— 它对任何时区都成立。 */
    static LocalStamp(ts) => DateAdd(A_Now, ts - Store.Now(), "Seconds")

    /* 给界面和日志看的本地时间文案；0 显示为空 */
    static Text(ts) => ts ? FormatTime(Reminder.LocalStamp(ts), "yyyy-MM-dd HH:mm") : ""

    /* 短文案：11-09 08:30 */
    static Short(ts) => ts ? FormatTime(Reminder.LocalStamp(ts), "MM-dd HH:mm") : ""

    /* 时长人话：5400 → "1 小时 30 分钟" */
    static Human(sec) {
        if (sec < 0)
            sec := -sec
        if (sec < 60)
            return sec " 秒"
        m := Floor(sec / 60)
        if (m < 60)
            return m " 分钟"
        h := Floor(m / 60), r := Mod(m, 60)
        if (m < 1440)
            return r ? h " 小时 " r " 分钟" : h " 小时"
        d := Floor(m / 1440), rh := Mod(h, 24)
        return rh ? d " 天 " rh " 小时" : d " 天"
    }

    ; ---- 规则 → 下一个触发时刻（纯函数，不写库） ----------------------------

    /* rule 归一化后的结构见 _Row。todo 为 0 或终态一律不排。
       返回 0 表示"这条规则当前不该有下一个时间点"。 */
    static NextFireAt(rule, todo, now := 0) {
        if !now
            now := Reminder.Now()
        if (rule.enabled = 0)
            return 0
        if (!todo || todo.status = "done" || todo.status = "canceled")
            return 0
        if (rule.kind = "daily")
            return Reminder._NextDaily(rule, todo, now)
        return Reminder._NextOffset(rule, todo, now)
    }

    /* offset：锚点前 N 分钟，一次性。
       允许返回过去的时间 —— 交给 Tick 按宽限判定"补发"还是"错过"，
       这样"程序 8:29 启动、规则本该 8:30 响"这种情况不会因为启动晚了
       1 秒就永远不响。 */
    static _NextOffset(rule, todo, now) {
        anchor := (rule.anchor = "due") ? todo.due_at : todo.start_at
        if (anchor = 0)
            return 0
        if (rule.last_fired_at > 0)
            return 0
        return anchor - rule.offset_min * 60
    }

    /* daily：从锚点（计划开始）前 N 天起，每天 at_time 响一次，到锚点停。
       按"日历天"推进而不是 +86400 秒：两者在国内等价，但日历天不受夏令时
       影响，也让"跨日 23:59"这种边界不容易算错。 */
    static _NextDaily(rule, todo, now) {
        if (todo.start_at = 0)
            return 0
        loop 400 {
            d := Reminder._AtTime(todo.start_at, -rule.days_before + A_Index - 1, rule.at_time)
            if (d = 0)
                return 0
            if (d <= now)
                continue
            if (d >= todo.start_at)
                return 0
            return d
        }
        /* 400 天都没找到（时钟被拨到几年后之类）：这条规则作废，
           不返回一个荒唐的时间点让它接着响。 */
        return 0
    }

    /* "锚点所在本地日期 + days 天" 的 HH:MM，转回 Unix 秒。
       days 可以是负数（往前数）。hhmm 不合法返回 0。 */
    static _AtTime(ts, days, hhmm) {
        if !RegExMatch(hhmm, "^(\d{1,2}):(\d{2})$", &m)
            return 0
        hh := Integer(m[1]), mm := Integer(m[2])
        if (hh > 23 || mm > 59)
            return 0
        day := FormatTime(DateAdd(Reminder.LocalStamp(ts), days, "Days"), "yyyyMMdd")
        return Reminder.EpochOfLocal(day . Format("{:02}", hh) . Format("{:02}", mm) . "00")
    }

    ; ---- 规则描述 -----------------------------------------------------------

    /* "开始前 30 分钟" / "截止前 1 小时" / "开始前 3 天每天 09:00" */
    static Describe(rule, todo := 0) {
        if (rule.kind = "daily") {
            s := "开始前 " rule.days_before " 天每天 " rule.at_time
            if (todo && todo.start_at = 0)
                s .= "（需先设置计划开始时间）"
            return s
        }
        anchor := (rule.anchor = "due") ? "截止" : "开始"
        if (rule.offset_min = 0)
            return anchor "时"
        if (rule.offset_min < 60)
            return anchor "前 " rule.offset_min " 分钟"
        if (Mod(rule.offset_min, 1440) = 0)
            return anchor "前 " (rule.offset_min // 1440) " 天"
        if (Mod(rule.offset_min, 60) = 0)
            return anchor "前 " (rule.offset_min // 60) " 小时"
        return anchor "前 " (rule.offset_min // 60) " 小时 " (Mod(rule.offset_min, 60)) " 分钟"
    }

    /* 这条规则"为什么排不出下一个时间点"。空串 = 排得出来。
       和 StopReason 分开，是因为"排不出来"不一定等于"被关掉了"：
       用户刚加了一条 daily 还没设开始时间，规则是启用的，但它排不出来。 */
    static _NoScheduleReason(rule, todo) {
        if (rule.kind = "daily") {
            if (!todo || todo.start_at = 0)
                return "先设置计划开始时间"
            return ""
        }
        anchor := todo ? ((rule.anchor = "due") ? todo.due_at : todo.start_at) : 0
        if (anchor = 0)
            return "先设置" ((rule.anchor = "due") ? "预计完成" : "计划开始") "时间"
        if (rule.last_fired_at > 0)
            return "已提醒过，不会再触发"
        return ""
    }

    /* 规则为什么停了。UI 要显示原因，不能静默消失（§5.8）。 */
    static StopReason(rule, todo) {
        if (rule.enabled && rule.next_fire_at > 0)
            return ""
        why := Reminder._NoScheduleReason(rule, todo)
        if (why != "")
            return why
        if (rule.last_fired_at > 0)
            return "已提醒"
        if (todo && (todo.status = "done" || todo.status = "canceled"))
            return "事项已结束"
        if (rule.enabled)
            return ""
        return "已关闭"
    }

    ; ---- 读 -----------------------------------------------------------------

    /* 一张事项的全部规则，按创建顺序（老规则在上面，界面不会跳来跳去） */
    static ForTodo(todoID) {
        todo := TodoStore.Get(todoID)
        rows := Reminder.db().Query("SELECT * FROM todo_reminders WHERE todo_id=?"
            . " ORDER BY id", todoID)
        out := []
        for r in rows {
            rule := Reminder._Row(r)
            rule.text := Reminder.Describe(rule, todo)
            rule.next_text := Reminder.Short(rule.next_fire_at)
            rule.stop := Reminder.StopReason(rule, todo)
            out.Push(rule)
        }
        return out
    }

    static Get(id) {
        rows := Reminder.db().Query("SELECT * FROM todo_reminders WHERE id=?", id)
        return rows.Length ? Reminder._Row(rows[1]) : 0
    }

    static Count(todoID) {
        return Integer(Reminder.db().Scalar(
            "SELECT count(*) FROM todo_reminders WHERE todo_id=? AND enabled=1", todoID))
    }

    /* 一张便签下还有几条"活着"的规则（列表页与卡片上的 N 条） */
    static CountByNote(noteID) {
        return Integer(Reminder.db().Scalar("SELECT count(*) FROM todo_reminders r"
            . " JOIN todos t ON t.id=r.todo_id"
            . " WHERE t.note_id=? AND r.enabled=1", noteID))
    }

    ; ---- 写 -----------------------------------------------------------------

    /* 加一条规则。opts 缺省值 = "开始前 30 分钟"（最常用的那条）。
       返回 {id, next, warn}，warn 非空表示"算出的时候已经过去了" —— 保存时
       就该提示，而不是等 10 分钟后悄悄记一条 missed（§5.5）。 */
    static Add(todoID, opts := 0) {
        todo := TodoStore.Get(todoID)
        if !todo
            return 0
        kind := Reminder._get(opts, "kind", "offset")
        if (kind != "daily")
            kind := "offset"
        anchor := Reminder._get(opts, "anchor", "start")
        if (anchor != "due")
            anchor := "start"
        offsetMin := Integer(Reminder._get(opts, "offset_min", 30))
        if (offsetMin < 0)
            offsetMin := 0
        if (offsetMin > 60 * 24 * 30)
            offsetMin := 60 * 24 * 30
        atTime := Reminder._get(opts, "at_time", "09:00")
        daysBefore := Integer(Reminder._get(opts, "days_before", 1))
        if (daysBefore < 0)
            daysBefore := 0
        if (daysBefore > 60)
            daysBefore := 60
        /* notify 是通道配置的 JSON（{"smtp":{"on":1}} 这种）。空串 = 没配通道，
           投递时退回托盘提示 —— P2 建的老规则就是这样，行为不变。 */
        ntfy := Reminder._get(opts, "notify", "")
        now := Reminder.Now()
        db := Reminder.db()
        res := db.Run("INSERT INTO todo_reminders(todo_id, kind, anchor, offset_min, at_time,"
            . " days_before, notify, enabled, next_fire_at, last_fired_at,"
            . " created_at, updated_at) VALUES(?,?,?,?,?,?,?,1,0,0,?,?)"
            , todoID, kind, anchor, offsetMin, atTime, daysBefore, ntfy, now, now)
        id := Integer(res.lastId)
        next := Reminder.RefreshRule(id, now)
        rule := Reminder.Get(id)
        warn := ""
        if (next > 0 && next < now)
            warn := "这个提醒时间已经过了（" Reminder.Text(next)
                . "），不会触发，请调整时间或换一条规则"
        else if (next = 0)
            warn := Reminder.StopReason(rule, todo)
        return {id: id, next: next, warn: warn}
    }

    /* 改一条规则的通道配置。传空串 = 退回托盘。 */
    static SetNotify(id, notifyTxt) {
        rule := Reminder.Get(id)
        if !rule
            return 0
        Reminder.db().Run("UPDATE todo_reminders SET notify=?, updated_at=? WHERE id=?"
            , notifyTxt, Reminder.Now(), id)
        return 1
    }

    static Delete(id) {
        return Reminder.db().Run("DELETE FROM todo_reminders WHERE id=?", id).changes
    }

    /* 开关一条规则。重新打开时顺手重算 —— 关着的时候 next_fire_at 会被清零，
       不重算打开也是死的。 */
    static SetEnabled(id, on) {
        r := Reminder.Get(id)
        if !r
            return 0
        now := Reminder.Now()
        Reminder.db().Run("UPDATE todo_reminders SET enabled=?, updated_at=? WHERE id=?"
            , on ? 1 : 0, now, id)
        if on
            Reminder.RefreshRule(id, now)
        else
            Reminder.db().Run("UPDATE todo_reminders SET next_fire_at=0 WHERE id=?", id)
        return 1
    }

    /* 重算一条规则的时间点，只在真的变了才写库。返回新的 next_fire_at。 */
    static RefreshRule(id, now := 0) {
        if !now
            now := Reminder.Now()
        r := Reminder.Get(id)
        if !r
            return 0
        todo := TodoStore.Get(r.todo_id)
        next := Reminder.NextFireAt(r, todo, now)
        if (next != r.next_fire_at)
            Reminder.db().Run("UPDATE todo_reminders SET next_fire_at=?, updated_at=?"
                . " WHERE id=?", next, now, id)
        return next
    }

    static RefreshTodo(todoID, now := 0) {
        if !now
            now := Reminder.Now()
        rows := Reminder.db().Query("SELECT id FROM todo_reminders WHERE todo_id=?", todoID)
        n := 0
        for r in rows {
            Reminder.RefreshRule(r["id"], now)
            n += 1
        }
        return n
    }

    static RefreshTodoByNote(noteID, now := 0) {
        for it in TodoStore.Items(noteID)
            Reminder.RefreshTodo(it.id, now)
        return 1
    }

    /* 全量对齐。每次 tick 都跑一遍，代价是一条带索引的查询 + 一两次比较，
       换来的是"不管哪个调用方忘了 Refresh 都不会留下过期的调度"。
       事项字段一起 JOIN 出来，避免每条规则再单独查一次 todos（N+1）。
       只处理非终态事项：终态的规则由 SetStatus 停掉，不该被重新排上。 */
    static RefreshAll(now := 0) {
        if !now
            now := Reminder.Now()
        rows := Reminder.db().Query("SELECT r.*, t.status AS t_status,"
            . " t.start_at AS t_start, t.due_at AS t_due, t.title AS t_title"
            . " FROM todo_reminders r JOIN todos t ON t.id=r.todo_id"
            . " WHERE t.status NOT IN ('done','canceled')")
        n := 0
        for m in rows {
            rule := Reminder._Row(m)
            /* 已经到点、正等着本 tick 处理的规则不能重算：daily 的公式用的是
               "严格大于 now"，now 正好等于触发点时会直接跳到明天 —— 于是
               这条规则永远错过自己那一格，永远不响。这是本文件最容易踩的
               一个 off-by-one，--selftest 与 probe-remind 各有一条盯着它。 */
            if (rule.next_fire_at > 0 && rule.next_fire_at <= now)
                continue
            todo := {id: rule.todo_id, status: m["t_status"], start_at: Integer(m["t_start"])
                , due_at: Integer(m["t_due"]), title: m["t_title"]}
            next := Reminder.NextFireAt(rule, todo, now)
            if (next != rule.next_fire_at) {
                Reminder.db().Run("UPDATE todo_reminders SET next_fire_at=?, updated_at=?"
                    . " WHERE id=?", next, now, rule.id)
                n += 1
            }
        }
        return n
    }

    ; ---- 调度 ---------------------------------------------------------------

    /* 主循环。返回 {sent, ok, failed, missed}，方便自检直接断言。
       now 可注入 —— 这是整个引擎可测的前提。 */
    static Tick(now := 0) {
        out := {sent: 0, ok: 0, failed: 0, missed: 0, pending: 0}
        if !now
            now := Reminder.Now()
        if Reminder.Busy
            return out
        Reminder.Busy := true
        try {
            Reminder._MarkStaleSending(now)
            Reminder.RefreshAll(now)
            for r in Reminder._Due(now) {
                res := Reminder._Fire(r, now)
                if (res = "")
                    continue
                out.sent += 1
                if (res = "ok")
                    out.ok += 1
                else if (res = "missed")
                    out.missed += 1
                else if (res = "pending")
                    out.pending += 1          ; 已交给子进程，回执还没回来
                else
                    out.failed += 1
            }
        } finally {
            Reminder.Busy := false
        }
        return out
    }

    /* 到点该处理的规则。JOIN 排除终态事项 —— 规则理论上已经被停掉了，
       这里再挡一次，防的是"库被手改过 / 老版本留下的脏数据"。 */
    static _Due(now) {
        return Reminder.db().Query("SELECT r.* FROM todo_reminders r"
            . " JOIN todos t ON t.id=r.todo_id"
            . " WHERE r.enabled=1 AND r.next_fire_at>0 AND r.next_fire_at<=?"
            . " AND t.status NOT IN ('done','canceled')"
            . " ORDER BY r.next_fire_at, r.id", now)
    }

    static _Fire(r, now) {
        todo := TodoStore.Get(r["todo_id"])
        if (!todo || todo.status = "done" || todo.status = "canceled") {
            Reminder.db().Run("UPDATE todo_reminders SET enabled=0, next_fire_at=0,"
                . " updated_at=? WHERE id=?", now, r["id"])
            return ""
        }
        fireAt := Integer(r["next_fire_at"])
        late := now - fireAt

        /* 超过宽限：不发，只留一条 missed 让人能查到"那天没响"。
           早上开机收到 12 条昨晚的提醒只会让人把提醒功能关掉（§5.5）。 */
        if (late > Reminder.GRACE) {
            Reminder._InsertFire(todo, r, fireAt, "missed"
                , "晚了 " Reminder.Human(late), now)
            Reminder.Advance(r["id"], fireAt, now)
            return "missed"
        }

        /* 唯一索引是最后一道闸：同一 (事项, 规则, 时刻) 只可能有一条。
           返回 0 说明这一时刻已经发过（上一轮 tick / 上次运行），
           直接推进规则，绝不再投递一次。 */
        if !Reminder._InsertFire(todo, r, fireAt, "sending", "", now) {
            Reminder.Advance(r["id"], fireAt, now)
            return ""
        }

        fire := Reminder._FireInfo(todo, r, fireAt, late)
        fire.fire_id := Reminder.FireID(todo.id, r["id"], fireAt)
        res := Reminder.Deliver(fire)
        /* 子进程模式：状态停在 sending，等下一次 tick 扫回执再落 ok/failed。
           这里绝不能先写成 ok —— 邮件还在发，库上已经显示"已提醒"了。 */
        if Reminder._IsPending(res) {
            Reminder.Advance(r["id"], fireAt, now)
            return "pending"
        }
        ok := (res && res.ok) ? 1 : 0
        detail := Trim((late > 0 ? "late " late "s " : "")
            . Reminder._get(res, "detail", ""))
        Reminder.db().Run("UPDATE todo_fires SET state=?, detail=?, finished_at=?"
            . " WHERE todo_id=? AND reminder_id=? AND fire_at=?"
            , ok ? "ok" : "failed", detail, Store.Now()
            , todo.id, r["id"], fireAt)
        Reminder.Advance(r["id"], fireAt, now)
        return ok ? "ok" : "failed"
    }

    /* 发完之后把规则推到下一个点。
       offset 是单次规则 → 停（enabled=0，UI 上显示"已提醒"）。
       daily → 先记 last_fired_at 再重算，公式会自己跳过今天。 */
    static Advance(id, fireAt, now) {
        r := Reminder.Get(id)
        if !r
            return 0
        todo := TodoStore.Get(r.todo_id)
        if (r.kind = "offset" || !todo || todo.status = "done" || todo.status = "canceled") {
            Reminder.db().Run("UPDATE todo_reminders SET enabled=0, next_fire_at=0,"
                . " last_fired_at=?, updated_at=? WHERE id=?", fireAt, now, id)
            return 1
        }
        Reminder.db().Run("UPDATE todo_reminders SET last_fired_at=?, updated_at=?"
            . " WHERE id=?", fireAt, now, id)
        r := Reminder.Get(id)
        next := Reminder._NextDaily(r, todo, now)
        Reminder.db().Run("UPDATE todo_reminders SET next_fire_at=?, enabled=?,"
            . " updated_at=? WHERE id=?", next, next > 0 ? 1 : 0, now, id)
        return 1
    }

    /* 子进程崩了会留下永远 sending 的行。不能让它挡住后续 —— 也不自动重试，
       重试是 P3 的事（只对可重试错误重试一次）。 */
    static _MarkStaleSending(now) {
        return Reminder.db().Run("UPDATE todo_fires SET state='failed',"
            . " detail = CASE WHEN detail='' THEN ? ELSE detail || ? END,"
            . " finished_at=?"
            . " WHERE state='sending' AND started_at>0 AND started_at<?"
            , "超时未回执", " · 超时未回执", now, now - Reminder.SENDING_TIMEOUT).changes
    }

    /* 唯一索引保证 (todo, 规则, 时刻) 只有一行，所以插完反查是安全的。
       派发作业要用行 id 命名文件、回收回执也要按 id 回写。 */
    static FireID(todoID, remID, fireAt) {
        return Integer(Reminder.db().Scalar(
            "SELECT id FROM todo_fires WHERE todo_id=? AND reminder_id=? AND fire_at=?"
            , todoID, remID, fireAt))
    }

    /* 投递结果是 Object（派发器）或 Map（自检里的 Hook）。
       Object 用 HasProp，Map 用 Has —— 混着写会在自检里抛
       'has no property named "pending"'，整轮 tick 直接不跑。 */
    static _IsPending(res) {
        if !IsObject(res)
            return false
        if res is Map
            return res.Has("pending") && res["pending"]
        return res.HasProp("pending") && res.pending
    }

    static _InsertFire(todo, r, fireAt, state, detail, now) {
        return Reminder.db().Run("INSERT OR IGNORE INTO todo_fires"
            . "(todo_id, reminder_id, fire_at, state, detail, started_at)"
            . " VALUES(?,?,?,?,?,?)", todo.id, r["id"], fireAt, state, detail, now).changes
    }

    ; ---- 投递 ---------------------------------------------------------------

    /* 一条提醒的完整事实。P3 的三种通道都吃这一份，P2 的托盘提示也吃它。 */
    static _FireInfo(todo, r, fireAt, late) {
        rule := Reminder._Row(r)
        note := Reminder.S ? Reminder.S.Get(todo.note_id) : 0
        fire := {
            todo_id: todo.id,
            note_id: todo.note_id,
            reminder_id: rule.id,
            fire_at: fireAt,
            late: late,
            title: todo.title != "" ? todo.title : "（无标题）",
            note_title: note ? note.title : "",
            status: todo.status,
            status_text: Reminder.StatusText(todo.status),
            start_at: todo.start_at,
            due_at: todo.due_at,
            rule_text: Reminder.Describe(rule, todo),
            notify: rule.notify
        }
        fire.message := Reminder.Message(fire)
        return fire
    }

    /* §6.5 的统一消息体：三种通道都用这一段，不各写一套。 */
    static Message(fire) {
        s := "待办：" fire.title "`n"
        if (fire.note_title != "")
            s .= "便签：" fire.note_title "`n"
        s .= "状态：" fire.status_text "`n"
        if (fire.start_at || fire.due_at)
            s .= "计划：" (fire.start_at ? Reminder.Text(fire.start_at) : "未设置")
                . " → " (fire.due_at ? Reminder.Text(fire.due_at) : "未设置") "`n"
        s .= "提醒：" fire.rule_text
        if (fire.late > 0)
            s .= "（晚了 " Reminder.Human(fire.late) "）"
        return s
    }

    static StatusText(st) {
        if (st = "doing")
            return "进行中"
        if (st = "done")
            return "已完成"
        if (st = "canceled")
            return "已取消"
        return "未开始"
    }

    /* Hook 存在就交给它（自检 / P3 的子进程派发），否则托盘提示。
       不能因为投递抛异常就把 tick 弄死 —— 一条提醒失败不该影响其它提醒。 */
    static Deliver(fire) {
        try {
            if IsObject(Reminder.Hook)
                return Reminder.Hook.Call(fire)
            /* 派发器返回 0 = 这条规则没配任何外部通道，退回托盘提示。
               所以 P2 建的老规则（notify 是空串）行为一字不变。 */
            if IsObject(Reminder.Notifier) {
                res := Reminder.Notifier.Call(fire)
                if IsObject(res)
                    return res
            }
            return Reminder._Tray(fire)
        } catch as e {
            return {ok: 0, detail: "投递异常：" Reminder._scrub(e.Message)}
        }
    }

    /* P2 的默认通道：托盘提示。非阻塞、不弹模态框 —— 模态框会把整个程序冻住。 */
    static _Tray(fire) {
        try {
            TrayTip(fire.message, "待办提醒", 0x1)
            return {ok: 1, detail: "托盘提示"}
        } catch as e {
            return {ok: 0, detail: "托盘提示失败：" Reminder._scrub(e.Message)}
        }
    }

    /* 报错信息进库前先抹一遍：P3 接上 SMTP 之后，异常里可能带凭据。 */
    static _scrub(s) {
        s := RegExReplace(s, "i)(pass(word)?|token|secret|authorization)\s*[=:]\s*\S+", "$1=***")
        return SubStr(Trim(s), 1, 200)
    }

    ; ---- 内部 ---------------------------------------------------------------

    static _Row(m) {
        return {
            id: m["id"],
            todo_id: m["todo_id"],
            kind: (m["kind"] = "daily") ? "daily" : "offset",
            anchor: (m["anchor"] = "due") ? "due" : "start",
            offset_min: Integer(m["offset_min"]),
            at_time: m["at_time"] != "" ? m["at_time"] : "09:00",
            days_before: Integer(m["days_before"]),
            notify: m["notify"],
            enabled: Integer(m["enabled"]),
            next_fire_at: Integer(m["next_fire_at"]),
            last_fired_at: Integer(m["last_fired_at"]),
            created_at: Integer(m["created_at"]),
            updated_at: Integer(m["updated_at"])
        }
    }

    static _get(obj, key, def := "") {
        if !obj
            return def
        if (obj is Map)
            return obj.Has(key) ? obj[key] : def
        return obj.HasProp(key) ? obj.%key% : def
    }
}
