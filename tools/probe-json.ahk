#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
; ============================================================================
;  probe-json.ahk —— json.ahk 的回归测试
;
;  起因（真事故）：Ctrl+V 粘图片一直是"没反应，正文里留一个虚线空图框"。
;  日志里只有一行 `未处理异常 [RegExMatch] PCRE execution error. @27` --
;  就是 JsonStr 原来那条正则。图片 base64 有几百 KB 到几 MB，带嵌套量词的
;  模式在这个量级上会撞 PCRE 的 match limit，直接抛异常；异常从定时器里冒
;  出来没人接，页面就永远等不到 image-ok。
;
;  所以这个探针重点盯两件事：
;    1) 大字段（800KB / 4MB）取值不能崩、要够快；
;    2) 手写扫描器的边界：转义引号、值里出现同名文本、缩进、缺省值。
; ============================================================================

#Include ..\lib\json.ahk

global PassN := 0, FailN := 0
LogPath := A_ScriptDir "\..\data\_json.log"
if FileExist(LogPath)
    FileDelete LogPath
Log(m) => FileAppend(m "`n", LogPath, "UTF-8")

Check(name, cond, detail := "") {
    global PassN, FailN
    if cond {
        PassN++
        Log("PASS  " name (detail != "" ? "  [" detail "]" : ""))
    } else {
        FailN++
        Log("FAIL  " name (detail != "" ? "  [" detail "]" : ""))
    }
}

Log("=== probe-json 开始 (AHK " A_AhkVersion ")")

; ---------------------------------------------------------------------------
; 1. 大字段：曾经必崩的那条路
; ---------------------------------------------------------------------------

big := ""
Loop 200000
    big .= "AAAABBBB"                     ; 1.6MB
raw := '{"type":"image","req":7,"name":"a b.png","data":"data:image/png;base64,' big '"}'
t := A_TickCount
got := ""
try
    got := JsonStr(raw, "data")
catch as e {
    Log("  抛异常：" e.Message " @" e.Line)
}
ms := A_TickCount - t
Check("1.6MB 字段能取出来（老代码在这里抛 PCRE 异常）"
    , StrLen(got) = StrLen(big) + StrLen("data:image/png;base64,")
    , "len=" StrLen(got))
Check("1.6MB 字段耗时 < 200ms", ms < 200, ms "ms")
Check("大字段不影响其它字段", JsonNum(raw, "req") = 7 && JsonStr(raw, "type") = "image"
    , "req=" JsonNum(raw, "req") " type=" JsonStr(raw, "type"))

huge := ""
Loop 1000000
    huge .= "CCCC"                        ; 4MB
t := A_TickCount
gotH := JsonStr('{"data":"' huge '"}', "data")
msH := A_TickCount - t
Check("4MB 字段能取出来", StrLen(gotH) = StrLen(huge), "len=" StrLen(gotH))
Check("4MB 字段耗时 < 400ms", msH < 400, msH "ms")

; ---------------------------------------------------------------------------
; 2. 边界：转义引号 / 同名文本 / 缩进 / 缺省
; ---------------------------------------------------------------------------

bs := Chr(92)
r2 := '{"a":"x' bs '"y' bs '"z","b":"尾"}'
Check("转义引号不提前收尾", JsonStr(r2, "a") = 'x"y"z', JsonStr(r2, "a"))
Check("转义引号后面的字段照常取", JsonStr(r2, "b") = "尾", JsonStr(r2, "b"))

r3 := '{"text":"他说 ' bs '"req' bs '": 1 次","req":42}'
Check("值里出现同名文本不抢真键", JsonStr(r3, "text") = '他说 "req": 1 次', JsonStr(r3, "text"))
Check("同名文本之后的真键仍然正确", JsonNum(r3, "req") = 42, JsonNum(r3, "req"))

r4 := "{`n  `"n`": 3,`n  `"s`": `"你好`",`n  `"t`": true`n}"
Check("带缩进的字符串", JsonStr(r4, "s") = "你好", JsonStr(r4, "s"))
Check("带缩进的数字", JsonNum(r4, "n") = 3, JsonNum(r4, "n"))
Check("带缩进的布尔", JsonBool(r4, "t") = 1, JsonBool(r4, "t"))
Check("缺键回落到默认值", JsonStr(r4, "zz", "-") = "-", JsonStr(r4, "zz", "-"))
Check("数字值的键不会被当成字符串", JsonStr(r4, "n", "X") = "X", JsonStr(r4, "n", "X"))

r5 := '{"p":"C:' bs bs 'Users' bs bs 'x.png","q":"1"}'
Check("Windows 路径的反斜杠正确还原", JsonStr(r5, "p") = "C:" bs "Users" bs "x.png", JsonStr(r5, "p"))
Check("路径后面的字段不受影响", JsonStr(r5, "q") = "1", JsonStr(r5, "q"))

Check("空文本不崩", JsonStr("", "a", "D") = "D")
Check("没有引号的垃圾文本不崩", JsonStr("不是 JSON", "a", "D") = "D")
Check("键存在但值为 null", JsonStr('{"a":null,"b":"2"}', "a", "D") = "D")
Check("键存在但值为空串", JsonStr('{"a":"","b":"2"}', "a", "D") = "")

; ---------------------------------------------------------------------------
; 3. 写方向：JsonQuote 的转义必须能被自己的 JsonStr 读回来
; ---------------------------------------------------------------------------

say := "第一行`n第二行`t制表" . Chr(1) . " 控制符 " . Chr(34) . " 和 ' " . bs
q := JsonQuote(say)
Check("JsonQuote 转义了换行", InStr(q, bs . "n") > 0, q)
Check("JsonQuote 往返一致", JsonStr('{"v":' . q . '}', "v") = say, JsonStr('{"v":' . q . '}', "v"))

; ---------------------------------------------------------------------------
; 4. 数组字段（列表窗口的消息在用）
; ---------------------------------------------------------------------------

apos := Chr(39)
arrJson := '{"tags":["a","b","d' . apos . 'e"]}'
arr := JsonStrArray(arrJson, "tags")
Check("数组字段个数", arr.Length = 3, arr.Length)
Check("数组字段内容（含单引号）"
    , arr.Length = 3 && arr[1] = "a" && arr[2] = "b" && arr[3] = "d" . apos . "e"
    , arr.Length = 3 ? arr[1] . "," . arr[2] . "," . arr[3] : "")
Check("数组里的中文", JsonStrArray('{"t":["中文","x"]}', "t")[1] = "中文")
Check("缺数组字段返回空数组", JsonStrArray('{"x":1}', "tags").Length = 0)

; ---------------------------------------------------------------------------
; 5. JsonHas：只判断"这个键在不在"（IPC 的可选参数用）
; ---------------------------------------------------------------------------

Check("字符串键存在", JsonHas('{"a":"1"}', "a") = 1)
Check("数字 0 也算存在（不能用默认值兜）", JsonHas('{"x":0}', "x") = 1)
Check("布尔 false 也算存在", JsonHas('{"activate":false}', "activate") = 1)
Check("null 值也算存在", JsonHas('{"a":null}', "a") = 1)
Check("缺键返回 0", JsonHas('{"a":1}', "b") = 0)
Check("带换行缩进也能认出来", JsonHas("{`n  `"w`": 300`n}", "w") = 1)
Check("键名出现在值里不算", JsonHas('{"a":"他说  ' bs '"x' bs '": 1"}', "x") = 0)
Check("空文本返回 0", JsonHas("", "x") = 0)
Check("前缀相同的键不会误判", JsonHas('{"xy":1}', "x") = 0)

Log("=== 结束：PASS " PassN " / FAIL " FailN)
Sleep 150
ExitApp FailN ? 1 : 0
