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

/* ★ 取字符串字段不能用正则，必须逐字符扫。
   原因：图片 base64 有几 MB，而 `"data"\s*:\s*"((?:\\u...|\\.|[^"\\])*)"` 这种
   带嵌套量词的模式在这么长的输入上会撞 PCRE 的 match limit，直接抛
       "PCRE execution error."
   这个异常从 COM 回调的定时器里冒出来，页面永远等不到 image-ok，用户看到的是
   "Ctrl+V 粘图没反应，正文里留一个虚线空图框"。实测 800KB 的 base64 就必崩，
   而一张普通截图 base64 之后很容易超过这个量级。

   现在改成：InStr 找键 → 线性找结束引号（跳过 \" 这种转义）→ JsonUnescape。
   全程 O(n) 且不做回溯。 */
JsonStr(text, key, def := '') {
    needle := '"' key '"'
    klen := StrLen(key) + 2
    n := StrLen(text)
    p := 0
    while (p := InStr(text, needle, 1, p + 1)) {
        i := p + klen
        ; 键的后面必须是（空白* 冒号 空白* 引号），否则这只是某个值里出现的同名文本
        while (i <= n && InStr(" `t`r`n", SubStr(text, i, 1)))
            i++
        if (SubStr(text, i, 1) != ":")
            continue
        i++
        while (i <= n && InStr(" `t`r`n", SubStr(text, i, 1)))
            i++
        if (SubStr(text, i, 1) != '"')
            continue                     ; 值是数字/布尔/null，交给 JsonNum 之类
        i++                              ; 跳过开引号
        q := i
        while (q := InStr(text, '"', 1, q)) {
            ; 前面连着奇数个反斜杠 → 这个引号是被转义的，继续往后找
            bs := 0, k := q - 1
            while (k >= i && SubStr(text, k, 1) = '\')
                bs++, k--
            if (Mod(bs, 2) = 0)
                break
            q++
        }
        if !q
            return def
        return JsonUnescape(SubStr(text, i, q - i))
    }
    return def
}

/* 键是否存在（只看 `"key"` 后面是不是冒号），不关心值的类型。
   给"可选参数"用：没传就按默认走，传了 0 也算传了 —— 光靠 JsonNum 的
   默认值区分不出"没写"和"写了 0"。
   判法和 JsonStr 一样：InStr 找键，再看后面是否紧跟冒号，避免命中值里的同名文本。 */
JsonHas(text, key) {
    needle := '"' key '"'
    klen := StrLen(needle)
    n := StrLen(text)
    p := 0
    while (p := InStr(text, needle, 1, p + 1)) {
        i := p + klen
        while (i <= n && InStr(" `t`r`n", SubStr(text, i, 1)))
            i++
        if (SubStr(text, i, 1) = ":")
            return 1
    }
    return 0
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

/* 纯数字数组，如 "ids":[3,7,12]。批量操作要用。
   只认整数：id 就是整数，浮点/字符串一律跳过（宁可少删一个，也别删错一个）。 */
JsonNumArray(text, key) {
    out := []
    if !RegExMatch(text, '"' key '"\s*:\s*\[([^\]]*)\]', &arr)
        return out
    pos := 1
    while RegExMatch(arr[1], "-?\d+", &m, pos) {
        out.Push(m[0] + 0)
        pos := m.Pos + m.Len
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

/* 取一个嵌套对象的原始文本，如 "webhook":{"on":1,"url":"…"} → '{…}'。
   用括号配平而不是正则：值里可能出现 } 或者整个 URL 带花括号，
   正则一贪婪就切错。扫描时跳过字符串内的一切，只数字符串外的括号。
   取到之后可以继续用 JsonStr / JsonNum / JsonBool 读它的扁平字段。 */
JsonObj(text, key) {
    _ndl := '"' key '"'
    _kl := StrLen(_ndl)
    _n := StrLen(text)
    _at := 0
    while true {
        _at := InStr(text, _ndl, 1, _at + 1)
        if !_at
            break
        _i := _at + _kl
        while (_i <= _n && InStr(" `t`r`n", SubStr(text, _i, 1)))
            _i++
        if (SubStr(text, _i, 1) != ":")
            continue
        _i++
        while (_i <= _n && InStr(" `t`r`n", SubStr(text, _i, 1)))
            _i++
        if (SubStr(text, _i, 1) != "{")
            continue
        _depth := 0
        _q := false
        _e := _i
        while (_e <= _n) {
            _c := SubStr(text, _e, 1)
            if _q {
                if (_c = "\") {
                    _e += 2
                    continue
                }
                if (_c = '"')
                    _q := false
            } else if (_c = '"') {
                _q := true
            } else if (_c = "{") {
                _depth++
            } else if (_c = "}") {
                _depth--
                if (_depth = 0)
                    return SubStr(text, _i, _e - _i + 1)
            }
            _e++
        }
        return ""
    }
    return ""
}

/* ---- 结构固定的自有格式用：数组 / 键 ---------------------------------- */

/* 取 key 对应值的原文。open 是值的首字符：'{' 对象、'[' 数组、'"' 字符串。
   找不到或类型不符返回空串。
   为什么不写一个通用 JSON 解析器：.qntodo 是我们自己产出的格式，字段固定，
   取值式解析够用，而且不需要为一棵树分配一整个对象图（几 MB 的 base64
   会变成几百万个 Map，光是分配就能把内存吃掉）。 */
JsonRaw(text, key, open) {
    _ndl := '"' key '"'
    _kl := StrLen(_ndl)
    _n := StrLen(text)
    _at := 0
    while true {
        _at := InStr(text, _ndl, 1, _at + 1)
        if !_at
            break
        _i := _at + _kl
        while (_i <= _n && InStr(" `t`r`n", SubStr(text, _i, 1)))
            _i++
        if (SubStr(text, _i, 1) != ":")
            continue
        _i++
        while (_i <= _n && InStr(" `t`r`n", SubStr(text, _i, 1)))
            _i++
        if (SubStr(text, _i, 1) != open)
            continue
        if (open = '"') {
            _e := _i + 1
            while (_e <= _n) {
                _x := SubStr(text, _e, 1)
                if (_x = "\") {
                    _e += 2
                    continue
                }
                if (_x = '"')
                    return SubStr(text, _i, _e - _i + 1)
                _e++
            }
            return ""
        }
        _close := (open = "{") ? "}" : "]"
        _depth := 0
        _q := false
        _e := _i
        while (_e <= _n) {
            _x := SubStr(text, _e, 1)
            if _q {
                if (_x = "\") {
                    _e += 2
                    continue
                }
                if (_x = '"')
                    _q := false
            } else if (_x = '"') {
                _q := true
            } else if (_x = open) {
                _depth++
            } else if (_x = _close) {
                _depth--
                if (_depth = 0)
                    return SubStr(text, _i, _e - _i + 1)
            }
            _e++
        }
        return ""
    }
    return ""
}

/* [a,b,{…},"x,y"] → 每个元素的原文。只有顶层逗号算分隔符：字符串里的逗号、
   嵌套对象/数组里的逗号都不算。 */
JsonItems(arrText) {
    out := []
    _n := StrLen(arrText)
    _i := 1
    while (_i <= _n && SubStr(arrText, _i, 1) != "[")
        _i++
    if (_i > _n)
        return out
    _i++
    _start := 0
    _depth := 0
    _q := false
    while (_i <= _n) {
        _c := SubStr(arrText, _i, 1)
        if _q {
            if (_c = "\") {
                _i += 2
                continue
            }
            if (_c = '"')
                _q := false
        } else if (_c = '"') {
            _q := true
        } else if (_c = "{" || _c = "[") {
            _depth++
        } else if (_c = "}" || _c = "]") {
            if (_depth = 0) {          ; 只能是数组自己的收尾 ]
                if (_start)
                    out.Push(SubStr(arrText, _start, _i - _start))
                break
            }
            _depth--
        } else if (_c = "," && _depth = 0) {
            if (_start)
                out.Push(SubStr(arrText, _start, _i - _start))
            _start := 0
            _i++
            continue
        }
        if (_start = 0 && !InStr(" `t`r`n,", _c))
            _start := _i
        _i++
    }
    return out
}

/* 对象顶层的所有键，按出现顺序。用来遍历 images 这种"名字事先不知道"的映射。 */
JsonKeys(rawObj) {
    out := []
    _n := StrLen(rawObj)
    _i := 1
    while (_i <= _n && SubStr(rawObj, _i, 1) != "{")
        _i++
    if (_i > _n)
        return out
    _i++                              ; 跳过开头的 {，之后 depth=0 就是顶层
    _depth := 0
    _q := false
    _start := 0
    while (_i <= _n) {
        _c := SubStr(rawObj, _i, 1)
        if _q {
            if (_c = "\") {
                _i += 2
                continue
            }
            if (_c = '"') {
                _q := false
                if (_depth = 0 && _start) {
                    _j := _i + 1
                    while (_j <= _n && InStr(" `t`r`n", SubStr(rawObj, _j, 1)))
                        _j++
                    if (SubStr(rawObj, _j, 1) = ":")
                        out.Push(JsonUnescape(SubStr(rawObj, _start + 1, _i - _start - 1)))
                }
                _start := 0
            }
        } else if (_c = '"') {
            _q := true
            _start := _i
        } else if (_c = "{" || _c = "[") {
            _depth++
        } else if (_c = "}" || _c = "]") {
            _depth--
        }
        _i++
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
