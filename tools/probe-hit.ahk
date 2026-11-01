#Requires AutoHotkey v2.0
#SingleInstance Off
; ============================================================================
;  probe-hit.ahk —— 分层窗口的鼠标命中测试
;
;  目的：验证「窗口看得见但点不到」的根因。
;  分层窗口（WS_EX_LAYERED）的命中测试按像素 alpha 判定：
;    alpha = 0  -> 鼠标消息直接穿透给下面的窗口
;    alpha = 255-> 正常接收
;  如果从来没调过 SetLayeredWindowAttributes，窗口的 alpha 就是 0，
;  于是「可见（DComp 合成）但不可点」。下面逐条测。
; ============================================================================

#Include ..\lib\win.ahk

OUT := A_ScriptDir "\_probe-hit.log"
try FileDelete OUT
Log(s) {
    global OUT
    FileAppend s "`n", OUT, "UTF-8-RAW"
}

PASS := 0
FAIL := 0
Check(name, got, want) {
    global PASS, FAIL
    if (got = want) {
        PASS++
        Log("PASS  " name "  = " got)
    } else {
        FAIL++
        Log("FAIL  " name "  got=" got " want=" want)
    }
}

KEEP := []

; 建一个窗口并显示，返回 Gui；exStyle 传扩展样式（0 表示不加）
MakeWin(exStyle, x, y, w, h) {
    global KEEP
    flags := "-Caption +ToolWindow"
    if (exStyle)
        flags .= " +E" Format("{:#x}", exStyle)
    g := Gui(flags, "probe")
    g.MarginX := 0
    g.MarginY := 0
    g.BackColor := "0x336699"
    g.Show("x" x " y" y " w" w " h" h " NoActivate")
    KEEP.Push(g)                     ; 留住引用，避免对象被回收后窗口消失
    return g
}

; 屏幕坐标处的窗口句柄（0 = 没人接收，即穿透）
At(x, y) => DllCall("WindowFromPoint", "int64", (y << 32) | (x & 0xFFFFFFFF), "ptr")

; 读分层窗口属性：返回 "key,alpha,flags"，从来没设过就返回 ""
LayeredAttrs(hwnd) {
    buf := Buffer(4, 0)
    alpha := Buffer(4, 0)
    flags := Buffer(4, 0)
    ok := DllCall("GetLayeredWindowAttributes", "ptr", hwnd
        , "ptr", buf, "ptr", alpha, "ptr", flags, "int")
    if !ok
        return ""
    return "alpha=" NumGet(alpha, 0, "uint") " flags=" NumGet(flags, 0, "uint")
}

SetAlpha(hwnd, a) {
    return DllCall("SetLayeredWindowAttributes", "ptr", hwnd
        , "uint", 0, "uchar", a, "uint", 2, "int")     ; LWA_ALPHA = 2
}

Log("=== 屏幕环境 ===")
mon := MonitorGet(1, &l, &t, &r, &b)
Log("主屏序号 " mon " 区域 " l "," t "," r "," b)
MonitorGetWorkArea(1, &wl, &wt, &wr, &wb)
Log("工作区 " wl "," wt "," wr "," wb)
Log("虚拟屏 " A_ScreenWidth "x" A_ScreenHeight)

Log("")
Log("=== A 普通窗口（对照组）===")
gA := MakeWin(0, 100, 100, 300, 200)
Sleep 250
Check("A 普通窗口 命中"       , At(250, 200) = gA.Hwnd, 1)
Check("A 普通窗口 分层属性"   , LayeredAttrs(gA.Hwnd), "")

Log("")
Log("=== B 分层 + 不做重定向位图（当前便签的写法，未设 alpha）===")
gB := MakeWin(0x00280000, 450, 100, 300, 200)      ; LAYERED | NOREDIRECTIONBITMAP
Sleep 400
Check("B 扩展样式含 LAYERED", (WinGetExStyle("ahk_id " gB.Hwnd) & 0x80000) ? 1 : 0, 1)
Check("B 未设 alpha -> 穿透", At(600, 200) = gB.Hwnd, 0)
Check("B 分层属性为空"       , LayeredAttrs(gB.Hwnd), "")

Log("")
Log("=== C 同上，补设 SetLayeredWindowAttributes(alpha=255) ===")
r := SetAlpha(gB.Hwnd, 255)
Sleep 250
Check("C 设置调用成功", r ? 1 : 0, 1)
Check("C alpha 已为 255", LayeredAttrs(gB.Hwnd), "alpha=255 flags=2")
Check("C 窗口能命中   ", At(600, 200) = gB.Hwnd, 1)

Log("")
Log("=== D 分层（不带 NOREDIRECTIONBITMAP）+ alpha 255，对照组 ===")
gD := MakeWin(0x00080000, 100, 400, 300, 200)
Sleep 250
Check("D 未设 alpha 时穿透", At(250, 500) = gD.Hwnd, 0)
SetAlpha(gD.Hwnd, 255)
Sleep 200
Check("D 设 alpha 后可命中", At(250, 500) = gD.Hwnd, 1)

Log("")
Log("=== E 客户区命中测试 ===")
; 点落在客户区应当返回 HTCLIENT(1)
p := (500 << 16) | (200 & 0xFFFF)                  ; x=200 y=500 -> 用窗口 D 内一点
p := (700 << 16) | (600 & 0xFFFF)
ht := SendMessage(0x0084, 0, p, , "ahk_id " gA.Hwnd)   ; WM_NCHITTEST
Check("E 普通窗口客户区 = HTCLIENT", ht, 1)

Log("")
Log("=== 汇总 PASS " PASS "  FAIL " FAIL " ===")

for g in [gA, gB, gD]
    try g.Destroy()
Sleep 100
ExitApp FAIL ? 1 : 0
