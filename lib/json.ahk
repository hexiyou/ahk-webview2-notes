#Requires AutoHotkey v2.0
; ============================================================================
;  json.ahk —— 极简 JSON 工具（只处理扁平字段，够本程序用）
;
;  为什么不用现成的 JSON 库：消息都是扁平的 {type, id, ...}，几个正则足够，
;  而且这里对"生成必须是合法 JSON"的要求很高 —— PostWebMessageAsJson 遇到
;  非法 JSON 会**静默丢弃整条消息**，页面那边表现为"点了没反应"。
;  所以 JsonQuote 对控制字符做了完整转义。
; ============================================================================

JsonQuote(s) {
    s := StrReplace(s, '\', '\\')
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", '\n')
    s := StrReplace(s, "`r", '\r')
    s := StrReplace(s, "`t", '\t')
    if RegExMatch(s, '[\x00-\x1f]') {
        out := ''
        Loop Parse, s
            out .= (Ord(A_LoopField) < 0x20) ? Format('\u{:04x}', Ord(A_LoopField)) : A_LoopField
        s := out
    }
    return '"' s '"'
}

JsonStr(text, key, def := '') {
    if RegExMatch(text, '"' key '"\s*:\s*"((?:\\u[0-9a-fA-F]{4}|\\.|[^"\\])*)"', &m)
        return JsonUnescape(m[1])
    return def
}

; 数字/布尔字段：前端 postMessage 的是真正的 JSON 字面量，不是字符串
JsonNum(text, key, def := 0) {
    if RegExMatch(text, '"' key '"\s*:\s*(-?\d+(?:\.\d+)?)', &m)
        return Number(m[1])
    if RegExMatch(text, '"' key '"\s*:\s*"(-?\d+(?:\.\d+)?)"', &m)   ; 兼容写成字符串
        return Number(m[1])
    return def
}

JsonBool(text, key, def := 0) {
    if RegExMatch(text, '"' key '"\s*:\s*(true|false)', &m)
        return (m[1] = 'true') ? 1 : 0
    if RegExMatch(text, '"' key '"\s*:\s*"?(true|false|1|0)"?', &m)
        return (m[1] = 'true' || m[1] = '1') ? 1 : 0
    return def
}

; 只认"由字符串元素组成"的数组；老写法 \[(.*?)\] 遇到元素里带 ] 会提前截断
JsonStrArray(text, key) {
    out := []
    if !RegExMatch(text
        , '"' key '"\s*:\s*\[((?:\s*"(?:\\u[0-9a-fA-F]{4}|\\.|[^"\\])*"\s*,?)*)\s*\]', &arr)
        return out
    pos := 1
    while RegExMatch(arr[1], '"((?:\\u[0-9a-fA-F]{4}|\\.|[^"\\])*)"', &s, pos) {
        out.Push(JsonUnescape(s[1]))
        pos := s.Pos + s.Len
    }
    return out
}

JsonUnescape(s) {
    if !InStr(s, '\')
        return s
    out := '', i := 1, n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c != '\') {
            out .= c
            i++
            continue
        }
        i++
        d := SubStr(s, i, 1)
        if (d = 'n')
            out .= "`n"
        else if (d = 'r')
            out .= "`r"
        else if (d = 't')
            out .= "`t"
        else if (d = 'b')
            out .= Chr(8)
        else if (d = 'f')
            out .= Chr(12)
        else if (d = 'u' && RegExMatch(SubStr(s, i + 1, 4), '^[0-9a-fA-F]{4}$')) {
            out .= Chr(Integer('0x' SubStr(s, i + 1, 4)))
            i += 4
        } else
            out .= d
        i++
    }
    return out
}

/* COM 异常的 Message 后面会挂 "Source: ... Description: ..."，只留前半句人话 */
CleanComError(msg) {
    p := InStr(msg, 'Source:')
    if p
        msg := SubStr(msg, 1, p - 1)
    return Trim(StrReplace(StrReplace(msg, "`r", ' '), "`n", ' '))
}
