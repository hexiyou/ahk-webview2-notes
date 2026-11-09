#Requires AutoHotkey v2.0
/* ============================================================================
   notify.ahk —— 提醒投递（run / webhook / smtp）

   为什么必须是子进程（§6.1）：AHK 是单 OS 线程的协作式调度，定时器和消息
   回调都是伪线程。一次 SMTP 超时 20 秒，整个程序、所有便签窗口就冻 20 秒。
   这不是理论风险，是 AHK 的固有行为。所以主进程只做三件事：挑作业、记账、
   Run 一下，然后立刻返回。真正的投递全在这个一次性子进程里。

   为什么子进程不碰数据库（§6.3）：两个进程同时写同一个 SQLite 会撞
   SQLITE_BUSY，而 lib/sqlite.ahk 没设 busy timeout，一撞就是报错。所以：
       主进程 → notify\<id>.job.json  → 子进程读
       子进程 → notify\<id>.res.json  → 主进程下次 tick 回写 todo_fires
   跨进程只传事实，不共享状态 —— 和项目现有的 IPC 哲学一致。

   也因此这个文件里没有一句 SQL。

   通道可以同时开多条，**任一成功即算成功**，全失败才 failed（§6.2）。
   最坏情况 10+15+20 = 45 秒，远小于 reminder 的 SENDING_TIMEOUT(300s)。
   ============================================================================ */

#Include dpapi.ahk

class Notify {
    static TimeoutRun := 10          ; 外部程序：只有"等待"模式才计超时
    static TimeoutWebhook := 15
    static TimeoutSmtp := 20
    static ORDER := ["run", "webhook", "smtp"]

    static Dir() => App.DataDir "\notify"

    static EnsureDir() {
        dir := Notify.Dir()
        if !DirExist(dir)
            DirCreate dir
        return dir
    }

    /* ---- 主进程侧 -------------------------------------------------------- */

    /* 派发一条提醒。没有配置任何通道时返回 0 —— 调用方据此退回托盘提示，
       这样 P2 的老规则（notify 为空）行为一点不变。 */
    static Dispatch(fire, fireID) {
        chans := Notify.Channels(fire.notify)
        if !chans.Length
            return 0
        dir := Notify.EnsureDir()
        jobPath := dir "\" fireID ".job.json"
        resPath := dir "\" fireID ".res.json"
        try {
            Notify._Write(jobPath, Notify._JobJson(fire, fireID, chans))
        } catch as e {
            return {ok: 0, detail: "写作业失败：" CleanComError(e.Message)}
        }
        ; 上一次的残留结果会让主进程把旧结果当成这次的回执
        try FileDelete resPath

        /* 子进程命令行。编译版直接用自己；脚本版要同时给解释器和脚本路径。
           ★ 这个版本的 AHK v2 里 Run() 的返回值是空串，PID 必须用输出参数
           取 —— 用返回值会拿到空，ProcessExist("") 恒 0，日志里也看不出到底是
           起没起来。 */
        /* ★ 起之前先确认两个路径都能落地。AutoHotkey 自己的
           "Script file not found" 是**启动器**弹的框，脚本里的 #Warn 管不到它，
           Run 的 Hide 也藏不住 —— 一旦参数拼错，用户屏幕上就会蹦一个红叉，
           而程序其它部分还在跑，看起来像"好端端报错"。宁可这里直接失败。 */
        if (A_ScriptFullPath = "" || !FileExist(A_ScriptFullPath)) {
            try FileDelete jobPath
            return {ok: 0, detail: "拿不到脚本路径，起不了投递子进程"}
        }
        if A_IsCompiled
            cmd := '"' A_ScriptFullPath '"'
        else if (A_AhkPath = "" || !FileExist(A_AhkPath))
            ; 关联启动时 A_AhkPath 可能是空或是注册表里的简写，退回直接把
            ; 脚本交给 ShellExecute —— 参数传递不如直接给解释器可靠，但总比
            ; 弹一个"Script file not found"强
            cmd := '"' A_ScriptFullPath '"'
        else
            cmd := '"' A_AhkPath '" "' A_ScriptFullPath '"'
        cmd .= ' --notify "' jobPath '" --result "' resPath '"'
            . ' --data-dir "' App.DataDir '"'
        pid := 0
        try Run(cmd, , "Hide", &pid)
        catch as e {
            try FileDelete jobPath
            return {ok: 0, detail: "起子进程失败：" CleanComError(e.Message)}
        }
        App.Log("派发作业 " fireID "：pid=" pid " compiled=" A_IsCompiled
            " script=[" A_ScriptFullPath "] ahk=[" A_AhkPath "]")
        names := []
        for ch in chans
            names.Push(ch.kind)
        return {ok: 1, pending: 1, detail: "已派发：" Notify._Join(names, "+")}
    }

    /* 回收回执。主进程每个 tick 调一次 —— 只扫目录、读小文件，
       没有子进程在跑时开销是零（DirExist 一次）。 */
    static Collect(now := 0) {
        dir := Notify.Dir()
        if !DirExist(dir)
            return 0
        n := 0
        loop files, dir "\*.res.json", "F" {
            path := A_LoopFilePath
            try {
                txt := FileRead(path, "UTF-8")
                if !Notify._Apply(txt, now)
                    n += 0
            } catch {
                ; 文件正好被写到一半（子进程还在写）：下个 tick 再来
                continue
            }
            try FileDelete path
            Notify._DropJob(path)
            n += 1
        }
        return n
    }

    /* 把一份回执写进 todo_fires。只有还停在 sending 的那一行会被改 ——
       已经判超时（_MarkStaleSending）或已被别处改过的，不能覆盖。 */
    static _Apply(txt, now) {
        id := JsonNum(txt, "fireId", 0)
        if !id
            return 0
        ok := JsonBool(txt, "ok", 0)
        detail := Notify._scrub(JsonStr(txt, "detail", ""))
        ms := JsonNum(txt, "ms", 0)
        if (ms > 0)
            detail := Trim(detail (detail = "" ? "" : " · ") ms "ms")
        if !now
            now := Store.Now()
        return Reminder.db().Run("UPDATE todo_fires SET state=?, detail=?"
            . " , finished_at=? WHERE id=? AND state='sending'"
            , ok ? "ok" : "failed", detail, now, id).changes
    }

    ; 回执处理完就把对应的作业文件删掉，别让目录越积越多
    static _DropJob(resPath) {
        jp := RegExReplace(resPath, "\.res\.json$", ".job.json")
        if (jp != resPath)
            try FileDelete jp
    }

    /* ---- 子进程入口 ------------------------------------------------------ */

    /* 跑一个作业文件，把结果写成回执。返回是否至少一个通道成功。
       单个通道抛异常不影响其它通道 —— 一个配错的 webhook 不该让 SMTP 也不发。 */
    static RunJob(jobPath, resPath) {
        txt := ""
        try txt := FileRead(jobPath, "UTF-8")
        catch as e {
            Notify._Write(resPath, '{"fireId":0,"ok":0,"detail":'
                JsonQuote("作业读不出来：" CleanComError(e.Message)) ',"ms":0}')
            return 0
        }
        fireID := JsonNum(txt, "fireId", 0)
        fire := Notify._ReadFire(JsonObj(txt, "fire"))
        chans := Notify._ReadChannels(txt)

        t0 := A_TickCount
        parts := []
        anyOK := 0
        for ch in chans {
            r := 0
            try {
                if (ch.kind = "run")
                    r := Notify._DoRun(ch.cfg, fire)
                else if (ch.kind = "webhook")
                    r := Notify._DoWebhook(ch.cfg, fire)
                else if (ch.kind = "smtp")
                    r := Notify._DoSmtp(ch.cfg, fire)
                else
                    r := {ok: 0, detail: "未知通道"}
            } catch as e {
                r := {ok: 0, detail: "异常：" CleanComError(e.Message)}
            }
            if (r && r.ok)
                anyOK := 1
            parts.Push(ch.kind ":" (r && r.ok ? "ok" : "fail")
                ((r && r.detail != "") ? "(" r.detail ")" : ""))
        }
        detail := parts.Length ? Notify._scrub(Notify._Join(parts, " · ")) : "没有可用通道"
        Notify._Write(resPath, '{"fireId":' fireID ',"ok":' anyOK
            . ',"detail":' JsonQuote(detail) ',"ms":' (A_TickCount - t0) '}')
        return anyOK
    }

    /* ---- run 通道：外部程序 ---------------------------------------------- */

    static _DoRun(cfg, fire) {
        exe := Notify._Vars(Notify._get(cfg, "exe", ""), fire)
        if (Trim(exe) = "")
            return {ok: 0, detail: "没配程序"}
        args := Notify._Vars(Notify._get(cfg, "args", ""), fire)
        cmd := '"' exe '"' (args != "" ? " " args : "")
        /* Run 抛的是 OSError（程序不存在 / 路径错）。这里自己接住：
           外层虽然也兜了 try，但"某个通道配错"应该是这条通道失败，
           而不是把异常甩给调用方去猜是哪一条。 */
        if !Notify._get(cfg, "wait", 0) {
            try Run cmd, , "Hide"
            catch as e
                return {ok: 0, detail: "启动失败：" CleanComError(e.Message)}
            return {ok: 1, detail: "已启动"}
        }
        /* 等待模式自己轮询，不用 RunWait：RunWait 没有超时，用户配错一条
           会挂住的命令，子进程就永远不退，主进程只能等 5 分钟判超时。 */
        /* ★ Run() 的返回值在 AHK v2 里是空串，不是 PID。写成
           `pid := Run(cmd)` 的话 pid 恒为空，ProcessExist("") 立刻为假，
           于是"程序根本没跑完"也会被当成"已退出"报成功 —— 自检里表现为
           回执说 run:ok，但被调程序写出来的文件还不存在。
           PID 只能用输出参数拿：Run(cmd, , "Hide", &pid)。 */
        pid := 0
        try Run(cmd, , "Hide", &pid)
        catch as e
            return {ok: 0, detail: "启动失败：" CleanComError(e.Message)}
        if !pid
            return {ok: 1, detail: "已启动（拿不到 PID，不等待）"}
        t0 := A_TickCount
        while (A_TickCount - t0 < Notify.TimeoutRun * 1000 && ProcessExist(pid))
            Sleep 80
        if ProcessExist(pid) {
            try ProcessClose pid
            return {ok: 0, detail: "超时 " Notify.TimeoutRun "s，已结束"}
        }
        return {ok: 1, detail: "已退出"}
    }

    /* ---- webhook 通道 ---------------------------------------------------- */

    static _DoWebhook(cfg, fire) {
        url := Notify._Vars(Notify._get(cfg, "url", ""), fire)
        if (url = "")
            return {ok: 0, detail: "没配 URL"}
        if !RegExMatch(url, "i)^https?://")
            return {ok: 0, detail: "URL 只支持 http/https"}

        /* 整段包 try：连不上 / 超时 / DNS 失败都是 COM 异常（0x80072EE2 之类），
           不接住就会冒到调用方，一条配错的 webhook 能把整个作业弄成"异常退出"。
           这里接住 = 这条通道失败，其它通道照发。 */
        try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", url, false)
        whr.SetTimeouts(5000, 5000, 5000, Notify.TimeoutWebhook * 1000)
        whr.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        whr.SetRequestHeader("User-Agent", "QuickNote/notify")
        /* 自定义头写成每行 "Name: Value"。放在字符串里而不是嵌套对象，
           是为了让 config 的 JSON 能被现有这套扁平解析器读 —— 少一个解析器
           就少一类 bug。 */
        hdr := Notify._get(cfg, "headers", "")
        if (hdr != "") {
            for line in StrSplit(hdr, "`n") {
                line := Trim(line, " `r`t")
                if (line = "" || !InStr(line, ":"))
                    continue
                p := InStr(line, ":")
                name := Trim(SubStr(line, 1, p - 1))
                val := Trim(SubStr(line, p + 1))
                if (name != "" && val != "")
                    try whr.SetRequestHeader(name, val)
            }
        }
        ; 中文正文必须按字节发：Send(字符串) 走的是 ANSI，UTF-8 的 body 会变乱码
        Notify._SendBytes(whr, Notify._WebhookBody(fire))
        code := 0
        try code := whr.Status
        resp := ""
        try resp := SubStr(whr.ResponseText, 1, 200)
        resp := RegExReplace(resp, "\s+", " ")
        ok := (code >= 200 && code < 300) ? 1 : 0
        return {ok: ok, detail: "HTTP " code (resp != "" ? " " resp : "")}
        } catch as e {
            return {ok: 0, detail: "请求失败：" CleanComError(e.Message)}
        }
    }

    /* §6.5 定死的字段名。对方按这个写规则，所以顺序和名字都别随手改。 */
    static _WebhookBody(fire) {
        s := '{"source":"QuickNote","event":"todo.reminder"'
        s .= ',"todoId":' fire.todo_id
        s .= ',"noteId":' fire.note_id
        s .= ',"title":' JsonQuote(fire.title)
        s .= ',"status":' JsonQuote(fire.status)
        s .= ',"startAt":' fire.start_at
        s .= ',"dueAt":' fire.due_at
        s .= ',"message":' JsonQuote(fire.message)
        s .= ',"firedAt":' fire.fire_at '}'
        return s
    }

    /* ---- smtp 通道 ------------------------------------------------------- */

    static _DoSmtp(cfg, fire) {
        sm := Notify.SmtpCfg()
        if !sm
            return {ok: 0, detail: "SMTP 没配置"}
        to := Notify._get(cfg, "to", "")
        if (Trim(to) = "")
            to := sm.to
        if (Trim(to) = "")
            return {ok: 0, detail: "没配收件人"}
        pass := Dpapi.Unprotect(sm.pass_enc)
        if (pass = "")
            return {ok: 0, detail: "密码没配或解不开（换过机器/账号要重填）"}
        script := Notify._SmtpScript(sm, to, fire)
        return Notify._PowerShell(script, pass)
    }

    /* config.ini 的 [smtp] 段。每次现读：用户改完配置不用重启程序
       （提醒子进程本来就是一次性的，读一次 INI 的成本可以忽略）。 */
    static SmtpCfg() {
        d := App.DataDir
        if (d = "")
            d := App.ResolveDataDir()
        path := d "\config.ini"
        host := Trim(IniRead(path, "smtp", "host", ""))
        if (host = "")
            return 0
        return {
            host: host,
            port: Integer(IniRead(path, "smtp", "port", "465")),
            mode: IniRead(path, "smtp", "mode", "ssl"),
            user: Trim(IniRead(path, "smtp", "user", "")),
            from: Trim(IniRead(path, "smtp", "from", "")),
            to: Trim(IniRead(path, "smtp", "to", "")),
            pass_enc: Trim(IniRead(path, "smtp", "pass_enc", "")),
            timeout: Integer(IniRead(path, "smtp", "timeout", String(Notify.TimeoutSmtp)))
        }
    }

    /* 465 走 CDO（.NET 的 SmtpClient 不支持隐式 SSL，`EnableSsl` 是 STARTTLS，
       连 465 会卡在握手）；其余走 System.Net.Mail。这是设计 §6.2 定下的分流，
       也是 465/587 各自实测出来的唯一可行解。

       正文与主题都以 base64 传进脚本，再由脚本还原：
         · 中文 + 换行 + 引号，直接拼进 PowerShell 字符串是引号地狱
         · 密码走 stdin，不进命令行（进程列表和事件日志里都看得见命令行） */
    static _SmtpScript(sm, to, fire) {
        q := (s) => "'" StrReplace(String(s), "'", "''") "'"
        subject := "[待办] " fire.title " · " fire.status_text
        b64Sub := Dpapi._B64(Notify._Utf8Buf(subject))
        b64Body := Dpapi._B64(Notify._Utf8Buf(fire.message))
        from := (sm.from != "") ? sm.from : sm.user
        head := "$ErrorActionPreference='Stop'`n"
            . "$pass=[Console]::In.ReadLine()`n"
            . "$subject=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(" q(b64Sub) "))`n"
            . "$body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(" q(b64Body) "))`n"
        if (sm.port = 465) {
            return head
                . "$m=New-Object -ComObject CDO.Message`n"
                . "$c=$m.Configuration.Fields`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/sendusing')=2`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/smtpserver')=" q(sm.host) "`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/smtpserverport')=" sm.port "`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/smtpusessl')=$true`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/smtpauthenticate')=1`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/sendusername')=" q(sm.user) "`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/sendpassword')=$pass`n"
                . "$c.Item('http://schemas.microsoft.com/cdo/configuration/smtpconnectiontimeout')=" sm.timeout "`n"
                . "$c.Update()`n"
                . "$m.From=" q(from) "`n"
                . "$m.To=" q(to) "`n"
                . "$m.Subject=$subject`n"
                . "$m.TextBody=$body`n"
                . "$m.BodyPart.Charset='utf-8'`n"
                . "$m.TextBodyPart.Charset='utf-8'`n"
                . "$m.Send()`n"
                . "Write-Output 'OK'`n"
                . "exit 0`n"
        }
        return head
            . "$s=New-Object Net.Mail.SmtpClient(" q(sm.host) "," sm.port ")`n"
            . "$s.EnableSsl=$true`n"
            . "$s.Timeout=" sm.timeout "000`n"
            . "$s.Credentials=New-Object Net.NetworkCredential(" q(sm.user) ",$pass)`n"
            . "$m=New-Object Net.Mail.MailMessage`n"
            . "$m.From=New-Object Net.Mail.MailAddress(" q(from) ")`n"
            . "[void]$m.To.Add(" q(to) ")`n"
            . "$m.Subject=$subject`n"
            . "$m.SubjectEncoding=[Text.Encoding]::UTF8`n"
            . "$m.Body=$body`n"
            . "$m.BodyEncoding=[Text.Encoding]::UTF8`n"
            . "$s.Send($m)`n"
            . "Write-Output 'OK'`n"
            . "exit 0`n"
    }

    /* 起 powershell 并把密码从 stdin 灌进去。
       用 WScript.Shell.Exec 而不是 Run：只有 Exec 能给子进程喂 stdin，
       而密码必须走 stdin —— 放命令行等于写进进程列表和事件日志。 */
    static _PowerShell(script, secret) {
        enc := Dpapi._B64(Notify._Utf16Buf(script))
        cmd := 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden'
            . ' -ExecutionPolicy Bypass -EncodedCommand ' enc
        sh := ComObject("WScript.Shell")
        ex := sh.Exec(cmd)
        try {
            ex.StdIn.Write(secret)
            ex.StdIn.Close()
        }
        limit := Notify.TimeoutSmtp * 1000 + 5000
        t0 := A_TickCount
        while (ex.Status = 0 && A_TickCount - t0 < limit)
            Sleep 100
        if (ex.Status = 0) {
            try ex.Terminate()
            return {ok: 0, detail: "SMTP 超时 " Notify.TimeoutSmtp "s"}
        }
        /* Status 刚变 1 的那一瞬间 ExitCode 还可能读到旧值（实测拿到过
           明明输出了 OK 却返回 1 的情况）。等一下再读。 */
        Sleep 80
        out := ""
        try out := Trim(ex.StdOut.ReadAll())
        code := ex.ExitCode
        err := ""
        try err := Trim(ex.StdErr.ReadAll())
        msg := (out != "" ? out : err)
        msg := RegExReplace(msg, "\s+", " ")
        if (code = 0)
            return {ok: 1, detail: SubStr(msg, 1, 200)}
        return {ok: 0, detail: "exit " code " " SubStr(msg, 1, 240)}
    }

    /* ---- 通道配置 -------------------------------------------------------- */

    /* rule.notify（JSON 文本）→ [{kind, cfg}]。空串 / 全 off 都返回空数组，
       调用方据此退回托盘提示 —— P2 建的老规则 notify 是 ''，行为不能变。 */
    /* ★ 参数不能叫 notify：AHK 标识符大小写不敏感，方法体里的 Notify.ORDER
       会被解析成这个参数（字符串），报 "String has no property named ORDER"。
       撞出来的错误信息完全指不到真正的原因，只能靠踩过一次记住。 */
    static Channels(notifyTxt) {
        out := []
        if (Trim(notifyTxt) = "")
            return out
        for kind in Notify.ORDER {
            sub := JsonObj(notifyTxt, kind)
            if (sub = "" || !JsonBool(sub, "on", 0))
                continue
            cfg := Map()
            for k in Notify._KeysOf(kind) {
                if JsonHas(sub, k)
                    cfg[k] := (k = "wait") ? JsonNum(sub, k, 0) : JsonStr(sub, k, "")
            }
            out.Push({kind: kind, cfg: cfg})
        }
        return out
    }

    static _KeysOf(kind) {
        if (kind = "run")
            return ["exe", "args", "wait"]
        if (kind = "webhook")
            return ["url", "headers"]
        if (kind = "smtp")
            return ["to"]
        return []
    }

    /* ---- 变量替换（§6.2 参数注入防护） ----------------------------------- */

    /* 用户可以把 {title} 之类放进命令或 URL。替进去之前必须清洗：
       换行会让一条命令变成两条；控制字符在命令行里行为未定义；过长会撞
       命令行长度上限。宁可截断，也不要让一个标题把自己变成另一条命令。 */
    static _Vars(s, fire) {
        if (s = "" || !InStr(s, "{"))
            return s
        /* ★ 不能叫 map：与内置类 Map 重名（AHK 标识符大小写不敏感），
           报的错是 "This local variable has not been assigned a value. | map"，
           指不到真正原因。同理不能用 array / object / func / error / buffer。 */
        vars := Map(
            "title", fire.title,
            "note", fire.note_title,
            "status", fire.status_text,
            "startAt", fire.start_at ? Reminder.Text(fire.start_at) : "",
            "dueAt", fire.due_at ? Reminder.Text(fire.due_at) : "",
            "rule", fire.rule_text,
            "message", fire.message)
        for k, v in vars {
            v := Notify._Safe(v)
            s := StrReplace(s, "{" k "}", v)
        }
        return s
    }

    static _Safe(v) {
        v := RegExReplace(v, "[\r\n\t]+", " ")
        v := RegExReplace(v, "[\x00-\x1f]", "")
        return SubStr(Trim(v), 1, 200)
    }

    /* ---- 小工具 ---------------------------------------------------------- */

    static _get(obj, key, def) => obj.Has(key) ? obj[key] : def

    static _Join(arr, sep) {
        out := ""
        for i, v in arr
            out .= (i > 1 ? sep : "") v
        return out
    }

    /* 报错进库前抹一遍凭据：SMTP 异常里经常带 "password=xxx" 这种东西。 */
    static _scrub(s) {
        s := StrReplace(String(s), "`r", " ")
        s := StrReplace(s, "`n", " ")
        s := RegExReplace(s, "i)(pass(word)?|token|secret|authorization|bearer)\s*[=:]\s*\S+", "$1=***")
        return SubStr(Trim(s), 1, 500)
    }

    static _Utf8Buf(s) {
        buf := Buffer(StrPut(s, "UTF-8") - 1, 0)
        StrPut(s, buf, "UTF-8")
        return buf
    }

    static _Utf16Buf(s) {
        n := StrPut(s, "UTF-16")
        buf := Buffer(n * 2 - 2, 0)
        StrPut(s, buf, "UTF-16")
        return buf
    }

    /* WinHttpRequest.Send 传字符串会按 ANSI 编码发出去，中文立刻变乱码。
       必须自己转成 UTF-8 字节再塞进 VT_UI1 的 SAFEARRAY。 */
    static _SendBytes(whr, s) {
        buf := Notify._Utf8Buf(s)
        n := buf.Size
        arr := ComObjArray(0x11, n)          ; VT_UI1
        loop n
            arr[A_Index - 1] := NumGet(buf, A_Index - 1, "UChar")
        whr.Send(arr)
    }

    static _Write(path, text) {
        f := FileOpen(path, "w", "UTF-8")
        if !f
            throw Error("无法写入 " path)
        f.Write(text)
        f.Close()
    }

    /* ---- 作业序列化 ------------------------------------------------------ */

    static _JobJson(fire, fireID, chans) {
        s := '{"fireId":' fireID ',"fire":{'
        s .= '"todo_id":' fire.todo_id
        s .= ',"note_id":' fire.note_id
        s .= ',"fire_at":' fire.fire_at
        s .= ',"title":' JsonQuote(fire.title)
        s .= ',"note_title":' JsonQuote(fire.note_title)
        s .= ',"status":' JsonQuote(fire.status)
        s .= ',"status_text":' JsonQuote(fire.status_text)
        s .= ',"start_at":' fire.start_at
        s .= ',"due_at":' fire.due_at
        s .= ',"rule_text":' JsonQuote(fire.rule_text)
        s .= ',"message":' JsonQuote(fire.message)
        /* 通道不用数组：现有这套 JSON 工具只认扁平键，数组要再写一个解析器，
           而"多一个解析器就多一类 bug"。改成 channels:"run,webhook" 列出种类，
           每个种类一个 ch_<kind> 对象 —— JsonObj 直接就能取。 */
        kinds := []
        for ch in chans
            kinds.Push(ch.kind)
        s .= '},"channels":' JsonQuote(Notify._Join(kinds, ","))
        for ch in chans {
            s .= ',"ch_' ch.kind '":{'
            first := true
            for k, v in ch.cfg {
                s .= (first ? "" : ",") JsonQuote(k) ":"
                    . (v is Integer ? v : JsonQuote(String(v)))
                first := false
            }
            s .= "}"
        }
        s .= "}"
        return s
    }

    static _ReadChannels(txt) {
        out := []
        kinds := JsonStr(txt, "channels", "")
        if (kinds = "")
            return out
        for kind in StrSplit(kinds, ",") {
            kind := Trim(kind)
            sub := JsonObj(txt, "ch_" kind)
            if (sub = "")
                continue
            cfg := Map()
            for k in Notify._KeysOf(kind) {
                if JsonHas(sub, k)
                    cfg[k] := (k = "wait") ? JsonNum(sub, k, 0) : JsonStr(sub, k, "")
            }
            out.Push({kind: kind, cfg: cfg})
        }
        return out
    }

    static _ReadFire(txt) {
        if (txt = "")
            return {todo_id: 0, note_id: 0, fire_at: 0, title: "", note_title: ""
                , status: "todo", status_text: "未开始", start_at: 0, due_at: 0
                , rule_text: "", message: ""}
        return {
            todo_id: JsonNum(txt, "todo_id", 0),
            note_id: JsonNum(txt, "note_id", 0),
            fire_at: JsonNum(txt, "fire_at", 0),
            title: JsonStr(txt, "title", ""),
            note_title: JsonStr(txt, "note_title", ""),
            status: JsonStr(txt, "status", "todo"),
            status_text: JsonStr(txt, "status_text", "未开始"),
            start_at: JsonNum(txt, "start_at", 0),
            due_at: JsonNum(txt, "due_at", 0),
            rule_text: JsonStr(txt, "rule_text", ""),
            message: JsonStr(txt, "message", "")
        }
    }
}
