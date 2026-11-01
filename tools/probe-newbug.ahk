#Requires AutoHotkey v2.0
#SingleInstance Off
; ============================================================================
;  probe-newbug.ahk —— 复现"点列表窗口的「新建」之后，所有窗口都拖不动"
;
;  流程（全部用真鼠标，沙箱里键盘注入会卡死，所以不碰键盘）：
;     1) 找列表窗口，记下当前便签窗口数与位置
;     2) 点右上角「新建」
;     3) 看便签窗口数有没有 +1（有没有真的建出来）
;     4) 拖列表窗口顶栏 —— 修之前这一步就失败
;     5) 拖最新那张便签的顶栏
;     6) 顺手记一下当前线程是不是被卡住（用一个定时器数心跳）
; ============================================================================

OUT := A_ScriptDir "\_newbug.log"
try FileDelete OUT

PASS := 0
FAIL := 0
HB := 0

W(s) {
    global OUT
    FileAppend s "`n", OUT, "UTF-8-RAW"
}

Note(s) => W("      " s)

Chk(name, got, want) {
    global PASS, FAIL
    if (got = want) {
        PASS++
        W("PASS  " name "  = " got)
    } else {
        FAIL++
        W("FAIL  " name "  got=" got " want=" want)
    }
}

CoordMode("Mouse", "Screen")

; 心跳：主线程还活着的话这个数字会一直涨
SetTimer(HeartTick, 200)
HeartTick() {
    global HB
    HB++
}

; 数一下便签窗口有几个（标题形如 "便签 3"）
CountNotes() {
    n := 0
    for h in WinGetList("便签 ") {
        t := WinGetTitle("ahk_id " h)
        if RegExMatch(t, "^便签 \d+$")
            n++
    }
    return n
}

; 本进程所有顶层窗口标题，用来看有没有冒出来的野窗口
DumpWindows(tag) {
    pid := ProcessExist()
    W("--- " tag " 本进程顶层窗口 ---")
    for h in WinGetList("ahk_pid " pid) {
        t := WinGetTitle("ahk_id " h)
        c := WinGetClass("ahk_id " h)
        if (t = "" && c = "")
            continue
        Note("hwnd=" h " class=" c " title=[" t "]")
    }
}

; 拖一下：从 (x,y) 按下，往右下挪 80x50，看窗口有没有跟着动
TryDrag(hwnd, x, y) {
    WinGetPos(&bx, &by, , , "ahk_id " hwnd)
    WinActivate("ahk_id " hwnd)
    Sleep 350
    MouseMove(x, y, 0)
    Sleep 250
    Click("Down")
    Sleep 220
    loop 8 {
        MouseMove(x + 11 * A_Index, y + 7 * A_Index, 0)
        Sleep 45
    }
    Sleep 180
    Click("Up")
    Sleep 500
    WinGetPos(&ax, &ay, , , "ahk_id " hwnd)
    W("      拖动前 " bx "," by " → 拖动后 " ax "," ay
        . "（位移 " (ax - bx) "," (ay - by) "）")
    return (ax - bx > 50 && ay - by > 25) ? 1 : 0
}

; ---- 等窗口 ---------------------------------------------------------------
listHwnd := 0
loop 120 {
    listHwnd := WinExist("便签列表")
    if listHwnd
        break
    Sleep 150
}
if !listHwnd {
    W("!! 没有列表窗口，先用 --list 启动程序再跑这个探针")
    ExitApp 1
}

WinGetPos(&lx, &ly, &lw, &lh, "ahk_id " listHwnd)
W("列表窗口 @ " lx "," ly "  " lw "x" lh)
before := CountNotes()
W("点新建前的便签窗口数 = " before)
W("")
DumpWindows("点新建前")

; ---- 1) 先确认这一轮之前拖动是好的 ---------------------------------------
W("")
W("=== 1) 点「新建」之前，列表窗口能拖吗 ===")
ok0 := TryDrag(listHwnd, lx + 34, ly + 23)
Chk("点新建前 列表能拖", ok0, 1)
WinMove(lx, ly, lw, lh, "ahk_id " listHwnd)
Sleep 300

; ---- 2) 点「新建」 -------------------------------------------------------
; 先把列表窗口挪到一块没被便签窗口占住的地方，否则算出来的按钮坐标可能落在
; 置顶的便签上（第一次就是这么误判的）
WinMove(200, 200, 534, 574, "ahk_id " listHwnd)
Sleep 500
WinGetPos(&lx, &ly, &lw, &lh, "ahk_id " listHwnd)
W("")
W("=== 2) 点「新建」（列表窗口挪到 " lx "," ly "）===")

; 头部 46 高、右边距 16；从右往左：关闭(28) 更多(28) 新建(约 54)，间距 6
newX := lx + lw - 16 - 28 - 6 - 28 - 6 - 27
newY := ly + 23
; WindowFromPoint 命中的是 WebView2 的子窗口（Chrome Legacy Window），
; 要往上取顶层祖先才能和 Gui 的 hwnd 比
hAt := DllCall("WindowFromPoint", "int64", (newY << 32) | (newX & 0xFFFFFFFF), "ptr")
hTop := hAt ? DllCall("GetAncestor", "ptr", hAt, "uint", 2, "ptr") : 0   ; GA_ROOT
W("      点击点 " newX "," newY " 命中 " hAt "（" (hAt ? WinGetClass("ahk_id " hAt) : "无") "）"
    . "，顶层 " hTop)
Chk("点击点确实在列表窗口上", hTop = listHwnd ? 1 : 0, 1)

MouseMove(newX, newY, 0)
Sleep 300
Click("Down")
Sleep 90
Click("Up")

; 等新窗口出现（建窗要 200~500ms，最多等 6 秒）
t0 := A_TickCount
got := 0
loop 60 {
    if (CountNotes() > before) {
        got := 1
        break
    }
    Sleep 100
}
W("      等 " (A_TickCount - t0) " ms 后便签窗口数 = " CountNotes())
Chk("点「新建」真的建出了便签", got, 1)
Sleep 1200

; ---- 3) 拖列表窗口 -------------------------------------------------------
Sleep 300
WinGetPos(&lx, &ly, &lw, &lh, "ahk_id " listHwnd)
W("")
W("=== 3) 点新建之后，列表窗口还能拖吗 ===")
ok1 := TryDrag(listHwnd, lx + 34, ly + 23)
Chk("点新建后 列表仍能拖", ok1, 1)

; ---- 4) 拖便签窗口 -------------------------------------------------------
noteHwnd := 0
for h in WinGetList("便签 ") {
    if RegExMatch(WinGetTitle("ahk_id " h), "^便签 \d+$")
        noteHwnd := h
}
if noteHwnd {
    WinGetPos(&nx, &ny, &nw, &nh, "ahk_id " noteHwnd)
    W("")
    W("=== 4) 点新建之后，便签窗口还能拖吗（" WinGetTitle("ahk_id " noteHwnd) "）===")
    ok2 := TryDrag(noteHwnd, nx + Round(nw / 2), ny + 16)
    Chk("点新建后 便签仍能拖", ok2, 1)
} else {
    W("!! 没找到便签窗口")
    FAIL++
}

; ---- 5) 再来一次，确认不是"只能好一次" -------------------------------------
WinGetPos(&lx2, &ly2, &lw2, &lh2, "ahk_id " listHwnd)
before2 := CountNotes()
MouseMove(lx2 + lw2 - 16 - 28 - 6 - 28 - 6 - 27, ly2 + 23, 0)
Sleep 300
Click("Down")
Sleep 90
Click("Up")
t1 := A_TickCount
got2 := 0
loop 60 {
    if (CountNotes() > before2) {
        got2 := 1
        break
    }
    Sleep 100
}
W("")
W("=== 5) 再点一次「新建」 ===")
W("      等 " (A_TickCount - t1) " ms 后便签窗口数 = " CountNotes())
Chk("第二次新建也建出来了", got2, 1)
Sleep 1000
WinGetPos(&lx2, &ly2, &lw2, &lh2, "ahk_id " listHwnd)
Chk("第二次新建后 列表仍能拖", TryDrag(listHwnd, lx2 + 34, ly2 + 23), 1)

; ---- 5) 主线程还活着吗 ---------------------------------------------------
b0 := HB
Sleep 1000
Chk("主线程定时器仍在跑", HB > b0 ? 1 : 0, 1)
W("心跳 " b0 " → " HB)

W("")
W("=== 汇总 PASS " PASS "  FAIL " FAIL " ===")
ExitApp FAIL ? 1 : 0
