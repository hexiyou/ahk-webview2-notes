#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\todo-store.ahk
#Include ..\lib\reminder.ahk

; 提醒调度内核：规则 → next_fire_at / tick / 幂等 / 错过 / 记账。
; 不建窗口、不碰 WebView2 —— 这一层出问题必须在最快的循环里抓到。
;
; ★ 测法：拨假时钟，不动库里的 next_fire_at。
;   Tick 每次都会先 RefreshAll 把 next_fire_at 按公式重算一遍（这是有意的：
;   next_fire_at 是派生值，不该被外人改）。所以"把触发点摆到眼前"这种做法
;   会被 tick 自己还原 —— 只有拨时钟才是真实路径。
;
; T0 取固定本地时刻 2026-06-15 12:00，断言里的"明天 09:00"就跟跑测试的
; 日子无关，也不会因为跨零点变成另一条结论。
logPath := A_ScriptDir "\..\data\_remind.log"
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

dbp := A_ScriptDir "\..\data\_remind.db"
for f in [dbp, dbp "-wal", dbp "-shm"]
    if FileExist(f)
        try FileDelete f

; 投递器换成记录器：真跑 TrayTip 会在无人值守时弹一堆气泡，也没法断言。
global FIRES := []
HookRec(fire) {
    global FIRES
    FIRES.Push(fire)
    return {ok: 1, detail: "rec"}
}
HookBoom(fire) {
    global FIRES
    FIRES.Push(fire)
    throw Error("boom")
}

H(ts) => FormatTime(Reminder.LocalStamp(ts), "MM-dd HH:mm")
LT(s) => Reminder.EpochOfLocal(s)          ; 本地时间串 → Unix 秒
FireCount(id) => Integer(Reminder.db().Scalar(
    "SELECT count(*) FROM todo_fires WHERE reminder_id=?", id))
FireState(id, at) => Reminder.db().Scalar(
    "SELECT state FROM todo_fires WHERE reminder_id=? AND fire_at=?", id, at)

try {
    st := Store(dbp)
    TodoStore.Attach(st)
    Reminder.Attach(st)
    Reminder.Hook := HookRec

    T0 := LT("20260615120000")             ; 2026-06-15 12:00 本地
    Reminder.Clock := T0
    Say("假时钟生效", Reminder.Now() = T0, Reminder.Now())
    Say("本地→Unix→本地 往返一致", Reminder.Text(T0) = "2026-06-15 12:00", Reminder.Text(T0))
    Say("LocalStamp 不偏时区（+8 那个坑）"
        , Reminder.Text(LT("20260616090000")) = "2026-06-16 09:00"
        , Reminder.Text(LT("20260616090000")))
    Say("EpochOfLocal 自反"
        , Reminder.EpochOfLocal(FormatTime(Reminder.LocalStamp(T0), "yyyyMMddHHmmss")) = T0)

    nid := st.Create(Map("title", "工作", "body_text", "x", "body_md", "x", "body_html", "<div>x</div>"))
    tid := st.Create(Map("kind", "todo", "title", "本周上线"))
    a1 := TodoStore.Add(tid, Map("title", "写方案"))
    a2 := TodoStore.Add(tid, Map("title", "评审"))
    a3 := TodoStore.Add(tid, Map("title", "长跑"))

    ; a1：明天 12:00 开始，后天 22:00 截止
    S := LT("20260616120000")
    D := LT("20260617220000")
    TodoStore.SetTimes(a1, S, D)
    Say("事项时间落库", TodoStore.Get(a1).start_at = S && TodoStore.Get(a1).due_at = D
        , H(TodoStore.Get(a1).start_at) "/" H(TodoStore.Get(a1).due_at))

    ; ---- 1. offset 规则 ---------------------------------------------------
    o1 := Reminder.Add(a1, Map("kind", "offset", "anchor", "start", "offset_min", 30))
    Say("offset(start,30) 排在开始前 30 分钟", o1.next = S - 1800, H(o1.next))
    Say("时间没到：不带警告", o1.warn = "", o1.warn)

    o2 := Reminder.Add(a1, Map("kind", "offset", "anchor", "due", "offset_min", 0))
    Say("offset(due,0) 就是截止时刻", o2.next = D, H(o2.next))

    o3 := Reminder.Add(a2, Map("kind", "offset", "anchor", "start", "offset_min", 1440))
    Say("没设时间：排不上，并说清原因"
        , o3.next = 0 && InStr(o3.warn, "计划开始") > 0, "[" o3.warn "]")
    Say("排不上的规则仍是启用的（用户补上时间就活）", Reminder.Get(o3.id).enabled = 1)

    Say("规则只挂在各自的事项上"
        , Reminder.ForTodo(a1).Length = 2 && Reminder.ForTodo(a2).Length = 1
        , Reminder.ForTodo(a1).Length "/" Reminder.ForTodo(a2).Length)

    ; ---- 2. 到点才发 ------------------------------------------------------
    Reminder.Clock := LT("20260616112900")
    Say("还差 1 分钟：不发", Reminder.Tick().sent = 0)
    Reminder.Clock := LT("20260616113000")
    r := Reminder.Tick()
    Say("到点：发一条，记 ok", r.sent = 1 && r.ok = 1
        && FireState(o1.id, LT("20260616113000")) = "ok", r.sent "/" r.ok)
    Say("offset 规则发完就停", Reminder.Get(o1.id).enabled = 0
        && Reminder.Get(o1.id).next_fire_at = 0, Reminder.Get(o1.id).enabled)
    Say("last_fired_at 记的是触发时刻"
        , Reminder.Get(o1.id).last_fired_at = LT("20260616113000")
        , Reminder.Text(Reminder.Get(o1.id).last_fired_at))
    Say("停掉后能说清原因"
        , Reminder.StopReason(Reminder.Get(o1.id), TodoStore.Get(a1)) = "已提醒过，不会再触发"
        , Reminder.StopReason(Reminder.Get(o1.id), TodoStore.Get(a1)))

    ; ---- 3. 幂等 ----------------------------------------------------------
    Say("同一时刻再 tick：不发", Reminder.Tick().sent = 0)
    Say("todo_fires 没有多出来", FireCount(o1.id) = 1, FireCount(o1.id))
    /* 重启后最危险的一种：库里的规则还是"启用、没发过"（比如上一次退出时
       只写了 fire 没写 rule），但同一 fire_at 的历史已经在库里。唯一索引挡住。 */
    Reminder.db().Run("UPDATE todo_reminders SET enabled=1, last_fired_at=0 WHERE id=?", o1.id)
    Say("规则被还原成未发状态也只发一次", Reminder.Tick().sent = 0)
    Say("历史仍只有 1 条", FireCount(o1.id) = 1, FireCount(o1.id))
    Reminder.db().Run("UPDATE todo_reminders SET enabled=0, next_fire_at=0 WHERE id=?", o1.id)

    ; ---- 4. 时钟来回拨 ----------------------------------------------------
    Reminder.Clock := LT("20260616090000")
    Say("时钟往回拨：不发", Reminder.Tick().sent = 0)
    Reminder.Clock := LT("20260616113000")
    Say("再拨回来：也不重复发", Reminder.Tick().sent = 0 && FireCount(o1.id) = 1, FireCount(o1.id))

    ; ---- 5. 补发与错过 ----------------------------------------------------
    /* o4 应该在 11:00 响；假时钟直接跳到 11:10（正好晚 10 分钟）→ 补发。 */
    o4 := Reminder.Add(a1, Map("kind", "offset", "anchor", "start", "offset_min", 60))
    Say("o4 排在 11:00", o4.next = LT("20260616110000"), H(o4.next))
    Reminder.Clock := LT("20260616111000")
    r := Reminder.Tick()
    Say("晚 10 分钟：补发（ok 而不是 missed）", r.ok = 1 && r.missed = 0
        && FireState(o4.id, LT("20260616110000")) = "ok", r.ok "/" r.missed)
    Say("补发的 detail 标了 late", InStr(Reminder.db().Scalar(
        "SELECT detail FROM todo_fires WHERE reminder_id=?", o4.id), "late") > 0
        , Reminder.db().Scalar("SELECT detail FROM todo_fires WHERE reminder_id=?", o4.id))

    /* o5 应该在 10:00 响；跳到 10:11（晚 601 秒）→ 只记 missed。 */
    o5 := Reminder.Add(a1, Map("kind", "offset", "anchor", "start", "offset_min", 120))
    Say("o5 排在 10:00", o5.next = LT("20260616100000"), H(o5.next))
    Say("还没到点时不发", Reminder.Tick(LT("20260616095900")).sent = 0)
    r := Reminder.Tick(LT("20260616101001"))
    Say("晚 601 秒：记 missed，不发", r.missed = 1 && r.ok = 0, r.missed "/" r.ok)
    Say("missed 写清晚了多久", InStr(Reminder.db().Scalar(
        "SELECT detail FROM todo_fires WHERE reminder_id=?", o5.id), "晚了") > 0
        , Reminder.db().Scalar("SELECT detail FROM todo_fires WHERE reminder_id=?", o5.id))
    Say("missed 之后规则也停", Reminder.Get(o5.id).enabled = 0)

    ; ---- 6. daily 规则（纯计算） ------------------------------------------
    Reminder.Clock := T0                       ; 上一段把时钟推到了 6/16，拨回来
    TodoStore.SetTimes(a2, LT("20260618120000"), 0)      ; 大后天 12:00 开始
    d1 := Reminder.Add(a2, Map("kind", "daily", "days_before", 2, "at_time", "09:00"))
    Say("daily：开始前 2 天的 09:00（今天 12:00 已过 → 明天）"
        , d1.next = LT("20260616090000"), H(d1.next))

    /* days_before=3 → 候选点是 6/15 09:00（今天，已经过了）、6/16 09:00。
       公式必须跳过已经过去的那个，而不是把今天这条当成"没发生"。 */
    d2 := Reminder.Add(a2, Map("kind", "daily", "days_before", 3, "at_time", "09:00"))
    Say("已过的那个点跳过，落到明天 09:00", d2.next = LT("20260616090000"), H(d2.next))

    ; 算出来的点一旦够到开始时间就停
    TodoStore.SetTimes(a2, LT("20260616090000"), 0)
    Say("daily 算出的点 >= 开始时间 → 停"
        , Reminder.RefreshRule(d2.id) = 0, H(Reminder.Get(d2.id).next_fire_at))

    ; 跨日：开始前一天的 23:00 还落在今天，不能跳到明天
    TodoStore.SetTimes(a2, LT("20260617003000"), 0)
    Reminder.Clock := LT("20260616120000")
    dx := Reminder.Add(a2, Map("kind", "daily", "days_before", 1, "at_time", "23:00"))
    Say("跨日：今天 23:00 就是它，不跳到明天", dx.next = LT("20260616230000"), H(dx.next))
    Reminder.Clock := T0
    TodoStore.SetTimes(a2, LT("20260618120000"), 0)

    ; ---- 7. 非法参数 ------------------------------------------------------
    bad := Reminder.Add(a2, Map("kind", "daily", "days_before", 1, "at_time", "25:00"))
    Say("at_time 不合法 → 排不上", bad.next = 0, bad.next)
    weird := Reminder.Get(Reminder.Add(a1, Map("kind", "offset", "anchor", "xx"
        , "offset_min", -5)).id)
    Say("anchor 乱填按 start、负数 offset 当 0"
        , weird.anchor = "start" && weird.offset_min = 0, weird.anchor "/" weird.offset_min)

    ; ---- 8. 文案 ----------------------------------------------------------
    Say("Describe：开始前 30 分钟"
        , Reminder.Describe(Reminder.Get(o1.id)) = "开始前 30 分钟"
        , Reminder.Describe(Reminder.Get(o1.id)))
    Say("Describe：截止时", Reminder.Describe(Reminder.Get(o2.id)) = "截止时"
        , Reminder.Describe(Reminder.Get(o2.id)))
    Say("Describe：开始前 1 天", Reminder.Describe(Reminder.Get(o3.id)) = "开始前 1 天"
        , Reminder.Describe(Reminder.Get(o3.id)))
    Say("Describe：1 小时 30 分钟"
        , Reminder.Describe({kind: "offset", anchor: "start", offset_min: 90})
        = "开始前 1 小时 30 分钟"
        , Reminder.Describe({kind: "offset", anchor: "start", offset_min: 90}))
    Say("Describe：daily", Reminder.Describe(Reminder.Get(d1.id)) = "开始前 2 天每天 09:00"
        , Reminder.Describe(Reminder.Get(d1.id)))
    Say("Human：秒 / 分 / 时分 / 天时"
        , Reminder.Human(45) = "45 秒" && Reminder.Human(300) = "5 分钟"
        && Reminder.Human(5400) = "1 小时 30 分钟" && Reminder.Human(90000) = "1 天 1 小时"
        , Reminder.Human(45) "/" Reminder.Human(300) "/" Reminder.Human(5400)
        "/" Reminder.Human(90000))
    Say("Human：整点不拖尾巴", Reminder.Human(7200) = "2 小时", Reminder.Human(7200))
    Say("StatusText 四态"
        , Reminder.StatusText("doing") = "进行中" && Reminder.StatusText("todo") = "未开始"
        && Reminder.StatusText("done") = "已完成" && Reminder.StatusText("canceled") = "已取消")

    ; ---- 9. daily 连续排 --------------------------------------------------
    /* a3 单独拉一条：开始 6/20 12:00，days_before=5 → 第一个点是 6/16 09:00，
       发完必须自己滚到 6/17 09:00（还没到开始时间）。 */
    TodoStore.SetTimes(a3, LT("20260620120000"), 0)
    d3 := Reminder.Add(a3, Map("kind", "daily", "days_before", 5, "at_time", "09:00"))
    Say("daily 第一个点", d3.next = LT("20260616090000"), H(d3.next))
    Reminder.Clock := LT("20260616090000")
    Reminder.Tick()
    Say("daily 发完自动滚到下一天"
        , Reminder.Get(d3.id).next_fire_at = LT("20260617090000")
        , H(Reminder.Get(d3.id).next_fire_at))
    Say("daily 发完仍然启用", Reminder.Get(d3.id).enabled = 1)
    Say("daily last_fired_at 有值"
        , Reminder.Get(d3.id).last_fired_at = LT("20260616090000")
        , Reminder.Text(Reminder.Get(d3.id).last_fired_at))
    Reminder.Clock := T0

    ; ---- 10. 终态停止 -----------------------------------------------------
    TodoStore.SetStatus(a2, "done")
    Say("事项变 done：规则全停"
        , Reminder.Get(d1.id).enabled = 0 && Reminder.Get(d2.id).enabled = 0
        && Reminder.Get(dx.id).enabled = 0)
    Say("终态事项的规则一条都排不上", Reminder.db().Scalar(
        "SELECT count(*) FROM todo_reminders r JOIN todos t ON t.id=r.todo_id"
        . " WHERE t.status='done' AND (r.enabled=1 OR r.next_fire_at>0)") = 0)
    /* 库被手改过（enabled 又变 1）也不该发 —— _Due 里 JOIN status 是第二道闸 */
    Reminder.db().Run("UPDATE todo_reminders SET enabled=1, next_fire_at=? WHERE id=?", T0, d2.id)
    /* 注意这里不能断言"这条规则一条历史都没有"——它 6/16 09:00 已经发过。
       要断言的是"T0 这一刻没有新记录产生"。 */
    n0 := FireCount(d2.id)
    Say("脏数据：终态事项仍然不发", Reminder.Tick(T0).sent = 0 && FireCount(d2.id) = n0
        , FireCount(d2.id) " vs " n0)
    TodoStore.SetStatus(a2, "todo")
    Say("改回 todo 不自动复活已停的规则", Reminder.Get(d1.id).enabled = 0
        && Reminder.Get(dx.id).enabled = 0)

    ; ---- 11. 事项时间改了，规则跟着走 -------------------------------------
    o6 := Reminder.Add(a1, Map("kind", "offset", "anchor", "start", "offset_min", 10))
    Say("先按老开始时间排", o6.next = S - 600, H(o6.next))
    TodoStore.SetTimes(a1, LT("20260617120000"), 0)
    Say("改开始时间后钩子自动重算"
        , Reminder.Get(o6.id).next_fire_at = LT("20260617120000") - 600
        , H(Reminder.Get(o6.id).next_fire_at))
    Say("已发过的那条不会被改时间复活", Reminder.Get(o1.id).enabled = 0)

    ; ---- 12. 投递器 -------------------------------------------------------
    FIRES := []
    Reminder.Clock := LT("20260617115000")
    r := Reminder.Tick()
    Say("钩子收到了 fire", FIRES.Length = 1, FIRES.Length)
    if (FIRES.Length) {
        f := FIRES[1]
        Say("fire 带齐标题/便签/状态/规则", f.title = "写方案" && f.note_title = "本周上线"
            && f.status_text = "未开始" && InStr(f.rule_text, "开始前 10 分钟") > 0
            , f.title "/" f.note_title "/" f.status_text "/" f.rule_text)
        Say("消息体含标题行、便签行、提醒行", InStr(f.message, "待办：写方案") > 0
            && InStr(f.message, "便签：本周上线") > 0
            && InStr(f.message, "提醒：开始前 10 分钟") > 0, f.message)
        Say("消息体里的换行是真换行", InStr(f.message, "`n") > 0)
    } else {
        Say("fire 带齐标题/便签/状态/规则", false, "没有 fire")
        Say("消息体含标题行、便签行、提醒行", false, "没有 fire")
        Say("消息体里的换行是真换行", false, "没有 fire")
    }

    Reminder.Hook := HookBoom
    o7 := Reminder.Add(a1, Map("kind", "offset", "anchor", "start", "offset_min", 5))
    Reminder.Clock := LT("20260617115500")
    Reminder.Tick()
    Say("投递抛异常 → 记 failed，tick 不崩", FireState(o7.id, LT("20260617115500")) = "failed"
        , FireState(o7.id, LT("20260617115500")))
    Say("异常信息写进 detail（已抹凭据）", InStr(Reminder.db().Scalar(
        "SELECT detail FROM todo_fires WHERE reminder_id=?", o7.id), "boom") > 0
        , Reminder.db().Scalar("SELECT detail FROM todo_fires WHERE reminder_id=?", o7.id))
    Reminder.Hook := HookRec

    ; ---- 13. sending 卡死兜底 ---------------------------------------------
    o8 := Reminder.Add(a1, Map("kind", "offset", "anchor", "start", "offset_min", 1))
    Reminder.db().Run("INSERT INTO todo_fires(todo_id, reminder_id, fire_at, state, started_at)"
        . " VALUES(?,?,?,'sending',?)", a1, o8.id, T0 - 9000, T0 - 400)
    Reminder.Tick(T0)
    Say("sending 超过 5 分钟 → failed", FireState(o8.id, T0 - 9000) = "failed"
        , FireState(o8.id, T0 - 9000))
    Say("超时原因写进 detail", InStr(Reminder.db().Scalar(
        "SELECT detail FROM todo_fires WHERE reminder_id=? AND fire_at=?", o8.id, T0 - 9000)
        , "超时") > 0)

    ; ---- 14. 计数与清理 ---------------------------------------------------
    nExpect := Integer(Reminder.db().Scalar(
        "SELECT count(*) FROM todo_reminders WHERE todo_id=? AND enabled=1", a1))
    Say("Count 只数启用的", Reminder.Count(a1) = nExpect, Reminder.Count(a1) " vs " nExpect)
    Say("CountByNote 跨事项汇总", Reminder.CountByNote(tid) >= Reminder.Count(a1)
        , Reminder.CountByNote(tid))
    nRules := Integer(Reminder.db().Scalar("SELECT count(*) FROM todo_reminders"))
    nFires := Integer(Reminder.db().Scalar("SELECT count(*) FROM todo_fires"))
    TodoStore.Delete(a1)
    Say("删事项连带删规则"
        , Integer(Reminder.db().Scalar("SELECT count(*) FROM todo_reminders")) < nRules
        , Reminder.db().Scalar("SELECT count(*) FROM todo_reminders") " vs " nRules)
    Say("触发历史不跟着删（要能查那天到底发了没）"
        , Integer(Reminder.db().Scalar("SELECT count(*) FROM todo_fires")) = nFires)

    ; ---- 15. 便签删掉之后 ------------------------------------------------
    st.Delete(tid)
    Say("删待办便签连带清掉所有规则", Integer(Reminder.db().Scalar(
        "SELECT count(*) FROM todo_reminders r JOIN todos t ON t.id=r.todo_id"
        . " WHERE t.note_id=?", tid)) = 0)
    Say("便签没了也不会把 tick 弄崩", Reminder.Tick(T0).sent = 0)
} catch as e {
    Say("探针自身抛异常：" e.Message, false, e.What " @ " e.Line)
}

W("")
W("=== 结束：PASS " PASS " / FAIL " FAIL " ===")
ExitApp(FAIL = 0 ? 0 : 1)
