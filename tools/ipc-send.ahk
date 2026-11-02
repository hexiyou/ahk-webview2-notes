#Requires AutoHotkey v2.0
#SingleInstance Off
#ErrorStdOut UTF-8
; ============================================================================
;  ipc-send.ahk —— 「另一个 AHK 程序怎么给 QuickNote 塞东西」独立示例
;
;  ★ 这个文件**不引用 QuickNote 的任何源码**，整个拷到别的项目里照样能跑。
;    它只做三件事：找窗口 → 发消息 → （可选）等回执。
;
;  用法（有 AutoHotkey v2 的话，命令行或双击都能跑）：
;    ipc-send.ahk --text "买牛奶"               带内容新建（纯文本）
;    ipc-send.ahk --text-file msg.txt           内容从文件读，省得处理换行
;    ipc-send.ahk --json "{""text"":""hi""}"    带内容新建（扁平 JSON）
;    ipc-send.ahk --json-file payload.json
;    ipc-send.ahk --new                         只要一张空便签
;    ipc-send.ahk --list                        打开便签列表
;    ipc-send.ahk --text "hi" --ack             等回执，打印新便签的 id
;
;  可选参数：
;    --hwnd N      指定目标窗口（多实例、自动化测试时用；默认按标题找）
;    --log P       结果追加到文件（无人值守的调用方看这个，比 stdout 可靠）
;
;  结果行格式： mode=copy reply=1 ack=42
;    reply = 目标窗口的返回值（1 受理 / 0 拒绝）
;    ack   = 回执里的便签 id（没要回执或没等到就是 0）
; ============================================================================

ANCHOR_TITLE := "QuickNoteAnchor"
WM_NEW := 0x8010
WM_LIST := 0x8011
WM_ACK := 0x8014
WM_COPY := 0x004A
MAGIC := 0x514E
CD_MAGIC := 0x514E3031

global AckId := 0

mode := ""
text := ""
json := ""
textFile := ""
logPath := ""
wantAck := 0
badMagic := 0
badCd := 0
huge := 0
hwnd := 0

i := 1
while (i <= A_Args.Length) {
    a := A_Args[i]
    if (a = "--hwnd" && i < A_Args.Length)
        hwnd := Integer(A_Args[++i])
    else if (a = "--text" && i < A_Args.Length)
        text := A_Args[++i]
    else if (a = "--text-file" && i < A_Args.Length)
        textFile := A_Args[++i]
    else if (a = "--json" && i < A_Args.Length)
        json := A_Args[++i]
    else if (a = "--json-file" && i < A_Args.Length)
        json := FileRead(A_Args[++i], "UTF-8")
    else if (a = "--log" && i < A_Args.Length)
        logPath := A_Args[++i]
    else if (a = "--new")
        mode := "new"
    else if (a = "--list")
        mode := "list"
    else if (a = "--ack")
        wantAck := 1
    else if (a = "--bad-magic")
        badMagic := 1
    else if (a = "--bad-cd")
        badCd := 1
    else if (a = "--huge")
        huge := 1
    else
        Say("warn=unknown-arg " a)
    i++
}

if (textFile != "")
    text := FileRead(textFile, "UTF-8")

if (mode = "" && (text != "" || json != "" || huge))
    mode := "copy"
if (mode = "")
    mode := "new"

if !hwnd
    hwnd := DllCall("FindWindowW", "ptr", 0, "wstr", ANCHOR_TITLE, "ptr")
if !hwnd {
    Say("mode=" mode " reply=0 ack=0 error=no-anchor")
    ExitApp 1
}

; 回执要靠"调用方自己的窗口"接 —— 我们临时建一个藏起来的窗口当信箱。
; 真实项目里用你自己的主窗口句柄就行（Gui.Hwnd / 主窗体的 Handle）。
if wantAck {
    g := Gui("-Caption +ToolWindow", "QuickNote IPC 回执")
    g.Show("x-32000 y-32000 w1 h1")
    OnMessage(WM_ACK, OnAck)
}

reply := 0
if (mode = "list")
    reply := SendMessage(WM_LIST, MAGIC, 0, , "ahk_id " hwnd)
else if (mode = "new")
    reply := SendMessage(WM_NEW, badMagic ? 0x1234 : MAGIC, 0, , "ahk_id " hwnd)
else if (mode = "copy") {
    payload := huge ? Repeat("x", 70000) : (json != "" ? json : text)
    if (wantAck) {
        if (json != "") {
            ; 往调用方给的 JSON 里补一个 replyTo（只处理以 { 开头的扁平对象）
            payload := "{" '"replyTo":' g.Hwnd "," SubStr(payload, 2)
        } else {
            payload := '{"text":' JsonQuote(payload) ',"replyTo":' g.Hwnd "}"
        }
    }
    reply := SendCopy(hwnd, payload, badCd ? 0x12345678 : CD_MAGIC)
}

if wantAck {
    end := A_TickCount + 3000
    while (!AckId && A_TickCount < end)
        Sleep 40
}

Say("mode=" mode " reply=" reply " ack=" AckId)
ExitApp 0

; ---------------------------------------------------------------------------

OnAck(wParam, lParam, msg, hwnd) {
    global AckId
    AckId := wParam
    return 1
}

SendCopy(hwnd, payload, magic := CD_MAGIC) {
    n := StrPut(payload, "UTF-8")
    buf := Buffer(n, 0)
    StrPut(payload, buf, "UTF-8")
    cds := Buffer((A_PtrSize = 8) ? 24 : 12, 0)
    NumPut("ptr", magic, cds, 0)
    NumPut("uint", n - 1, cds, A_PtrSize)
    NumPut("ptr", buf.Ptr, cds, (A_PtrSize = 8) ? 16 : 8)
    return SendMessage(WM_COPY, 0, cds.Ptr, , "ahk_id " hwnd)
}

JsonQuote(s) {
    s := StrReplace(s, '\', '\\')
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", '\n')
    s := StrReplace(s, "`r", '\r')
    s := StrReplace(s, "`t", '\t')
    return '"' s '"'
}

Repeat(s, n) {
    out := ""
    loop n
        out .= s
    return out
}

Say(line) {
    global logPath
    if (logPath != "") {
        try FileAppend line "`n", logPath, "UTF-8-RAW"
        return
    }
    try FileAppend line "`n", "*", "UTF-8"
}
