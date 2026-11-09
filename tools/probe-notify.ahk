#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常无人值守跑，一个框就能把整轮测试挂死。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\todo-store.ahk
#Include ..\lib\reminder.ahk
#Include ..\lib\notify.ahk

; App 桩：本文件不加载 note.ahk，Notify 只用到 App.DataDir 与 App.ResolveDataDir。
class App {
    static DataDir := A_ScriptDir "\..\data\_nt"
    static ResolveDataDir() => App.DataDir
}

; 投递通道：DPAPI / 通道解析 / 作业序列化 / run / webhook / smtp / 回执回收。
; 不需要 WebView2 —— 这一层是最容易"看起来没坏但发不出去"的地方。
;
; webhook 用本机 TcpListener 收，不去连公网：测试不能依赖网络和别人的可用性。

ROOT := A_ScriptDir "\..\data\_nt"
logPath := A_ScriptDir "\..\data\_notify.log"
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

; 探针自己的异常也要落日志：没有这个，一次未捕获异常就是"日志断在半截"，
; 只能靠猜是哪一行。
OnError(Boom)
Boom(e, mode) {
    ; Extra 才是"到底是哪个变量/哪一行"的真线索。AHK 的 VarUnset 只把
    ; 变量名放在 Extra 里，光看 Message 只能知道"有个变量没赋值"。
    x := ""
    try x := e.Extra
    W("!! 异常：" e.Message " | " x " @" e.Line "`n" e.Stack)
    return 0
}

/* Dispatch 会把本文件当成子进程再拉起来（A_ScriptFullPath 就是这个脚本），
   这条分支必须在主体之前。参数：--notify <job> --result <res> */
if (A_Args.Length >= 4 && A_Args[1] = "--notify") {
    ok := Notify.RunJob(A_Args[2], A_Args[4])
    ExitApp ok ? 0 : 1
}

; ---- 环境 ----------------------------------------------------------------
if !DirExist(ROOT)
    DirCreate ROOT
appDir := ROOT
for f in ["x.txt", "hook.txt", "echo.ps1"]
    if FileExist(ROOT "\" f)
        try FileDelete ROOT "\" f

; 清掉上一次 notify 目录里的残留
if DirExist(Notify.Dir())
    loop files, Notify.Dir() "\*.*", "F"
        try FileDelete A_LoopFilePath
Notify.EnsureDir()

; 库：Collect 要回写 todo_fires，得有一张真的表
dbPath := ROOT "\notes.db"
for f in [dbPath, dbPath "-wal", dbPath "-shm"]
    if FileExist(f)
        try FileDelete f
S := Store(dbPath)
TodoStore.Attach(S)
Reminder.Attach(S)

; 造一条事项（Collect 的断言需要一个真实 fire 行）
nid := S.Create(Map("title", "投递测试", "body_text", "", "body_md", "", "body_html", "", "kind", "todo"))
tid := TodoStore.Add(nid, Map("title", "提交季度报表", "status", "todo"))
rid := Integer(Reminder.Add(tid, Map("kind", "offset", "anchor", "start", "offset_min", 30)).id)

Fire() {
    return {
        fire_id: 0, todo_id: 0, note_id: 0, fire_at: 1762734600, late: 0,
        title: "提交季度报表", note_title: "本周上线", status: "todo",
        status_text: "未开始", start_at: 1762736400, due_at: 1762822800,
        rule_text: "开始前 30 分钟", message: "待办：提交季度报表`n状态：未开始`n提醒：开始前 30 分钟",
        notify: ""
    }
}

; ===== 1. DPAPI ==========================================================
secret := "cqufylgoxsylbiig"
enc := Dpapi.Protect(secret)
Say("加密后不是明文", enc != "" && enc != secret, "len=" StrLen(enc))
Say("密文认得出（版本号 01 00 00 00）", Dpapi.LooksEncrypted(enc))
Say("解密回原文", Dpapi.Unprotect(enc) = secret)
Say("坏密文返回空串而不是抛异常", Dpapi.Unprotect("AQAAANCMnd8BFdERjHoAwE") = "")
Say("明文不会被误判成密文", !Dpapi.LooksEncrypted(secret))
Say("空串原样返回空", Dpapi.Unprotect("") = "")

; ===== 2. 通道解析 ========================================================
Say("notify 为空 → 没有通道（退回托盘）"
    , Notify.Channels("").Length = 0 && Notify.Channels("   ").Length = 0)
Say("非法 JSON → 没有通道", Notify.Channels("不是 json").Length = 0)

c1 := Notify.Channels('{"run":{"on":1,"exe":"cmd.exe","args":"/c echo hi"}}')
Say("单通道：解析出 1 条", c1.Length = 1 && c1[1].kind = "run")
Say("单通道：参数带过来了", c1.Length && c1[1].cfg["exe"] = "cmd.exe")

c2 := Notify.Channels('{"webhook":{"on":0,"url":"http://x"}}')
Say("on=0 不算通道", c2.Length = 0)

c3 := Notify.Channels('{"smtp":{"on":1,"to":"a@b.c"},"run":{"on":1,"exe":"x.exe"},"webhook":{"on":1,"url":"http://y"}}')
Say("三通道都开 → 3 条", c3.Length = 3, "共 " c3.Length " 条")
Say("顺序按 run → webhook → smtp 固定"
    , c3.Length = 3 && c3[1].kind = "run" && c3[2].kind = "webhook" && c3[3].kind = "smtp"
    , c3.Length = 3 ? c3[1].kind "/" c3[2].kind "/" c3[3].kind : "长度不对")
Say("未知通道名不认", Notify.Channels('{"telegram":{"on":1,"x":"1"}}').Length = 0)

; ===== 3. 变量替换与注入防护 ==============================================
f := Fire()
Say("Reminder.Text 可用", Reminder.Text(1762736400) != "", Reminder.Text(1762736400))
Say("{title} 被替换", Notify._Vars("/c echo {title}", f) = "/c echo 提交季度报表")
/* 变量替换只关心 title/note_title/... 这几个键，单独造一个最小对象，
   别把 _Vars 里那 7 对参数抄两遍（抄漏一对就是"参数个数不对"）。 */
VarsFire(t) {
    ; 必须是对象字面量而不是 Map：_Vars 读的是 fire.title 这种属性，
    ; 生产链路上的 fire 也是对象（Reminder._FireInfo 造出来的）。
    return {title: t, note_title: "", status_text: "", start_at: 0
        , due_at: 0, rule_text: "", message: ""}
}

Say("换行被压成空格（防一条命令变两条）"
    , !InStr(Notify._Vars("{title}", VarsFire("甲`n乙")), "`n"))
Say("超长值截断到 200 字"
    , StrLen(Notify._Vars("{title}", VarsFire(StrRepeat("啊", 500)))) = 200)
Say("未知变量原样保留", Notify._Vars("{nope}", f) = "{nope}")

Say("报错里的密码被抹掉"
    , InStr(Notify._scrub("login failed password=hunter2 user=a"), "hunter2") = 0
    , Notify._scrub("login failed password=hunter2 user=a"))
Say("报错里的换行被压平"
    , !InStr(Notify._scrub("a`nb"), "`n"))

StrRepeat(s, n) {
    out := ""
    loop n
        out .= s
    return out
}

; ===== 4. 作业序列化往返 =================================================
chans := Notify.Channels('{"run":{"on":1,"exe":"cmd.exe","args":"/c echo {title}","wait":1},'
    . '"webhook":{"on":1,"url":"http://127.0.0.1:18765/","headers":"Authorization: Bearer t"}}')
f := Fire()
f.fire_id := 7
job := Notify._JobJson(f, 7, chans)
Say("作业里有 fireId", JsonNum(job, "fireId", 0) = 7)
Say("作业里中文没被转义坏", InStr(job, "提交季度报表") > 0)
Say("作业里通道清单是字符串（不用嵌套数组）"
    , JsonStr(job, "channels", "") = "run,webhook")

fireBack := Notify._ReadFire(JsonObj(job, "fire"))
Say("fire 标题往返一致", fireBack.title = f.title, fireBack.title)
Say("fire 时间戳往返一致", fireBack.start_at = f.start_at && fireBack.due_at = f.due_at)
Say("fire 消息体往返一致", fireBack.message = f.message)

chBack := Notify._ReadChannels(job)
Say("通道种类往返一致", chBack.Length = 2
    , chBack.Length " 条：" (chBack.Length ? chBack[1].kind "/" chBack[2].kind : ""))
Say("wait 读回来是数字", chBack.Length && chBack[1].cfg["wait"] = 1)
Say("headers 带着换行也能往返"
    , chBack.Length >= 2 && chBack[2].cfg["headers"] = "Authorization: Bearer t")
Say("空作业不崩", Notify._ReadChannels("").Length = 0 && Notify._ReadFire("").title = "")

; ===== 5. run 通道 ========================================================
outFile := ROOT "\x.txt"
if FileExist(outFile)
    FileDelete outFile
r := Notify._DoRun(Map("exe", "cmd.exe", "args", '/c echo qn-run-ok>"' outFile '"', "wait", 1), f)
Say("run：外部程序执行成功", r.ok = 1, r.detail)
t0 := A_TickCount
while (A_TickCount - t0 < 2000 && !FileExist(outFile))
    Sleep 40
Say("run：目标文件真的写出来了", FileExist(outFile))
Say("run：文件内容对得上"
    , FileExist(outFile) && InStr(FileRead(outFile, "UTF-8"), "qn-run-ok") > 0
    , FileExist(outFile) ? Trim(FileRead(outFile, "UTF-8")) : "文件不存在")

r := Notify._DoRun(Map("exe", "D:\nonexistent\zzz-不存在.exe", "args", "", "wait", 0), f)
Say("run：程序不存在时明确失败而不是崩溃", r.ok = 0, r.detail)

r := Notify._DoRun(Map("exe", "", "args", "", "wait", 0), f)
Say("run：没配程序时拒绝执行", r.ok = 0, r.detail)

; ===== 6. webhook =========================================================
/* 本机起一个 node 的 HTTP 服务收一条 POST，把 body 落到 hook.txt。
   不连公网：测试不该依赖别人的可用性，也不该往外部服务器发假数据。
   用 node 而不是 TcpListener 手搓：后者要自己解 HTTP 头，还容易起不来
   （探针里表现为 15 秒后 WinHTTP 超时，排查成本很高）。 */
jsFile := ROOT "\echo.js"
hookOut := ROOT "\hook.txt"
if FileExist(hookOut)
    FileDelete hookOut
js := "
(
const http=require('http'),fs=require('fs');
const srv=http.createServer((q,r)=>{
  let b='';
  q.setEncoding('utf8');
  q.on('data',c=>b+=c);
  q.on('end',()=>{
    fs.writeFileSync(process.argv[2],b,'utf8');
    r.writeHead(200,{'Content-Type':'application/json'});
    r.end('{\"ok\":true}');
    srv.close();
  });
});
srv.listen(18765,'127.0.0.1');
)"
fw := FileOpen(jsFile, "w", "UTF-8-RAW")
fw.Write(js)
fw.Close()

Run 'node "' jsFile '" "' hookOut '"', , "Hide"
Sleep 1200          ; node 启动 + listen 通常在 300ms 内，留足余量

r := Notify._DoWebhook(Map("url", "http://127.0.0.1:18765/hook", "headers", ""), f)
Say("webhook：HTTP 200 算成功", r.ok = 1, r.detail)
t0 := A_TickCount
while (A_TickCount - t0 < 3000 && !FileExist(hookOut))
    Sleep 50
Say("webhook：服务端收到了请求体", FileExist(hookOut))
body := FileExist(hookOut) ? FileRead(hookOut, "UTF-8") : ""
Say("webhook：body 是 JSON 且带 title", InStr(body, "`"title`"") > 0, SubStr(body, 1, 120))
Say("webhook：中文按 UTF-8 发出去没乱码", InStr(body, "提交季度报表") > 0)
Say("webhook：事件名对得上", InStr(body, '"event":"todo.reminder"') > 0)
Say("webhook：firedAt 是秒级时间戳", JsonNum(body, "firedAt", 0) = f.fire_at)

r := Notify._DoWebhook(Map("url", "http://127.0.0.1:1/nope", "headers", ""), f)
Say("webhook：连不上时明确失败", r.ok = 0, r.detail)
r := Notify._DoWebhook(Map("url", "", "headers", ""), f)
Say("webhook：没配 URL 时拒绝", r.ok = 0, r.detail)
r := Notify._DoWebhook(Map("url", "ftp://x/y", "headers", ""), f)
Say("webhook：非 http 协议被挡", r.ok = 0, r.detail)

; ===== 7. smtp 配置校验 ===================================================
/* 真发信需要真账号，放在手工验收里做。这里只保证：缺什么就明确说缺什么，
   而且立刻返回 —— 配置不全时最怕的是"卡 20 秒然后一条超时"。
   注意探针不能覆盖用户自己的 data\config.ini：我们用的是 data\_nt 独立目录。 */
cfgPath := ROOT "\config.ini"
if FileExist(cfgPath)
    FileDelete cfgPath
Say("smtp：完全没配置时返回 0（不是异常）", Notify.SmtpCfg() = 0)
r := Notify._DoSmtp(Map("to", ""), f)
Say("smtp：没配置时明确失败", r.ok = 0, r.detail)
t0 := A_TickCount
IniWrite "smtp.qq.com", cfgPath, "smtp", "host"
IniWrite "465", cfgPath, "smtp", "port"
IniWrite "me@qq.com", cfgPath, "smtp", "user"
r := Notify._DoSmtp(Map("to", "you@qq.com"), f)
Say("smtp：有 host 没密码 → 说清是密码的问题", r.ok = 0 && InStr(r.detail, "密码") > 0, r.detail)
Say("smtp：缺密码时立刻返回（不等超时）", A_TickCount - t0 < 3000
    , (A_TickCount - t0) "ms")
IniWrite "AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA", cfgPath, "smtp", "pass_enc"
/* 必须给 to：检查顺序是「先收件人再密码」，只填 expect to 才能走到密码那一步 */
r := Notify._DoSmtp(Map("to", "you@qq.com"), f)
Say("smtp：密码解不开时明确失败", r.ok = 0 && InStr(r.detail, "密码") > 0, r.detail)
IniWrite Dpapi.Protect("dummy-pass"), cfgPath, "smtp", "pass_enc"
IniWrite "", cfgPath, "smtp", "to"
r := Notify._DoSmtp(Map("to", ""), f)
Say("smtp：没有收件人时明确失败", r.ok = 0 && InStr(r.detail, "收件人") > 0, r.detail)
Say("smtp：配置段解析正确"
    , (c := Notify.SmtpCfg()) && c.host = "smtp.qq.com" && c.port = 465 && c.user = "me@qq.com")

; ===== 8. 回执回收 ========================================================
/* 手工造一条 sending，写一份 res.json，Collect 应该把它改成 ok 并删掉文件。 */
now := Store.Now()
fireAt := 1762734600
Reminder.db().Run("INSERT INTO todo_fires(todo_id, reminder_id, fire_at, state,"
    . " detail, started_at) VALUES(?,?,?,'sending','',?)", tid, rid, fireAt, now)
fid := Reminder.FireID(tid, rid, fireAt)
Say("造出一条 sending 记录", fid > 0, "fire id=" fid)

jobP := Notify.Dir() "\" fid ".job.json"
resP := Notify.Dir() "\" fid ".res.json"
Notify._Write(jobP, '{"fireId":' fid '}')
Notify._Write(resP, '{"fireId":' fid ',"ok":1,"detail":"run:ok · smtp:ok","ms":321}')
Say("Collect 处理了 1 份回执", Notify.Collect() >= 1)
row := Reminder.db().Query("SELECT state, detail FROM todo_fires WHERE id=?", fid)
Say("sending → ok", row.Length && row[1]["state"] = "ok", row.Length ? row[1]["state"] : "查不到")
Say("detail 记下了各通道结果", row.Length && InStr(row[1]["detail"], "run:ok") > 0
    , row.Length ? row[1]["detail"] : "")
Say("detail 带上了耗时", row.Length && InStr(row[1]["detail"], "321ms") > 0
    , row.Length ? row[1]["detail"] : "")
Say("回执文件用完就删", !FileExist(resP))
Say("作业文件也跟着删", !FileExist(jobP))

; 失败回执
Reminder.db().Run("INSERT INTO todo_fires(todo_id, reminder_id, fire_at, state,"
    . " detail, started_at) VALUES(?,?,?,'sending','',?)", tid, rid, fireAt + 86400, now)
fid2 := Reminder.FireID(tid, rid, fireAt + 86400)
Notify._Write(Notify.Dir() "\" fid2 ".res.json", '{"fireId":' fid2 ',"ok":0,"detail":"smtp:exit 1 auth","ms":900}')
Notify.Collect()
row := Reminder.db().Query("SELECT state, detail FROM todo_fires WHERE id=?", fid2)
Say("失败回执 → failed", row.Length && row[1]["state"] = "failed"
    , row.Length ? row[1]["state"] : "查不到")
Say("失败原因留在库里", row.Length && InStr(row[1]["detail"], "auth") > 0
    , row.Length ? row[1]["detail"] : "")

/* 已经判超时（failed）的行不能被迟到的回执改回 ok —— 用户看到的会是
   "超时失败" 之后又变成"成功"，比一直失败更让人困惑。 */
Reminder.db().Run("INSERT INTO todo_fires(todo_id, reminder_id, fire_at, state,"
    . " detail, started_at) VALUES(?,?,?,'failed','超时未回执',?)", tid, rid, fireAt + 172800, now)
fid3 := Reminder.FireID(tid, rid, fireAt + 172800)
Notify._Write(Notify.Dir() "\" fid3 ".res.json", '{"fireId":' fid3 ',"ok":1,"detail":"late","ms":10}')
Notify.Collect()
row := Reminder.db().Query("SELECT state FROM todo_fires WHERE id=?", fid3)
Say("迟到的回执不覆盖已判超时的行", row.Length && row[1]["state"] = "failed"
    , row.Length ? row[1]["state"] : "查不到")

; ===== 9. Dispatch =======================================================
/* 真派发会把本脚本当子进程拉起来（A_ScriptFullPath 就是它），所以这里
   只验"该不该派发"和"作业文件写没写对"，不真的跑子进程。 */
Say("没配通道的规则不派发（退回托盘）", Notify.Dispatch(Fire(), 1) = 0)

f3 := Fire()
f3.notify := '{"run":{"on":1,"exe":"cmd.exe","args":"/c exit"}}'
f3.fire_id := 999
d := Notify.Dispatch(f3, 999)
Say("配了通道 → 派发成功", IsObject(d) && d.ok = 1, IsObject(d) ? d.detail : "返回 0")
Say("派发后状态是 pending（不抢着记 ok）", IsObject(d) && d.HasProp("pending") && d.pending = 1)
jp := Notify.Dir() "\999.job.json"
Say("作业文件落盘", FileExist(jp))
Say("作业里的通道是对的", FileExist(jp) && InStr(FileRead(jp, "UTF-8"), '"ch_run"') > 0)
try FileDelete jp


W("")
W("汇总 PASS " PASS "  FAIL " FAIL)
ExitApp FAIL ? 1 : 0
