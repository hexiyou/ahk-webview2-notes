#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#SingleInstance Off
; ============================================================================
;  probe-live.ahk —— 对"真正跑起来的 QuickNote"做交互验收
;
;  验三件事：
;    1) 便签窗口（透明分层窗）能不能被鼠标命中 —— 修之前的病是 alpha=0 全穿透
;    2) 便签顶栏按住能不能拖 —— 现在走 drag-start + WM_NCLBUTTONDOWN
;    3) 列表窗口顶栏能不能拖
;
;  用真鼠标事件（SendInput），不是发消息骗自己。
; ============================================================================

OUT := A_ScriptDir "\_live.log"
try FileDelete OUT

PASS := 0
FAIL := 0

W(s) {
    global OUT
    FileAppend s "`n", OUT, "UTF-8-RAW"
}

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

At(x, y) => DllCall("WindowFromPoint", "int64", (y << 32) | (x & 0xFFFFFFFF), "ptr")

CoordMode("Mouse", "Screen")

; ---- 等窗口起来 -----------------------------------------------------------
noteHwnd := 0
listHwnd := 0
loop 120 {
    if !listHwnd
        listHwnd := WinExist("便签列表")
    if !noteHwnd
        noteHwnd := WinExist("便签 ")
    if (noteHwnd && listHwnd)
        break
    Sleep 150
}
W("待测窗口：便签=" noteHwnd "  列表=" listHwnd)
if !noteHwnd {
    W("!! 没找到便签窗口，后面没法测")
    ExitApp 1
}

; ---- 1) 便签窗口的命中测试 ------------------------------------------------
WinGetPos(&nx, &ny, &nw, &nh, "ahk_id " noteHwnd)
W("")
W("=== 便签窗口 @ " nx "," ny " " nw "x" nh " ===")
ex := WinGetExStyle("ahk_id " noteHwnd)
W("扩展样式 = " Format("{:#x}", ex)
    "  LAYERED=" ((ex & 0x80000) ? "是" : "否")
    "  NOREDIRECTIONBITMAP=" ((ex & 0x200000) ? "是" : "否"))
Chk("便签 窗口中心被自己接住", At(nx + Round(nw / 2), ny + Round(nh / 2)) = noteHwnd, 1)
Chk("便签 顶栏被自己接住", At(nx + Round(nw / 2), ny + 8) = noteHwnd, 1)

; ---- 2) 便签顶栏拖动 ------------------------------------------------------
WinActivate("ahk_id " noteHwnd)
Sleep 300
bx := nx, by := ny
MouseMove(nx + Round(nw / 2), ny + 16, 0)
Sleep 200
Click("Down")
Sleep 200
loop 8 {
    MouseMove(nx + Round(nw / 2) + 12 * A_Index, ny + 16 + 7 * A_Index, 0)
    Sleep 40
}
Sleep 150
Click("Up")
Sleep 500
WinGetPos(&mx, &my, &mw, &mh, "ahk_id " noteHwnd)
W("便签拖动后位置 " mx "," my "（原 " bx "," by "）")
Chk("便签 顶栏能拖动", (mx - bx > 60 && my - by > 30) ? 1 : 0, 1)
WinMove(bx, by, nw, nh, "ahk_id " noteHwnd)

; ---- 3) 列表窗口顶栏拖动 --------------------------------------------------
if listHwnd {
    Sleep 300
    WinActivate("ahk_id " listHwnd)
    Sleep 400
    WinGetPos(&lx, &ly, &lw, &lh, "ahk_id " listHwnd)
    W("")
    W("=== 列表窗口 @ " lx "," ly " " lw "x" lh " ===")
    Chk("列表 窗口被自己接住", At(lx + Round(lw / 2), ly + Round(lh / 2)) = listHwnd, 1)

    MouseMove(lx + 40, ly + 23, 0)
    Sleep 200
    Click("Down")
    Sleep 200
    loop 8 {
        MouseMove(lx + 40 + 10 * A_Index, ly + 23 + 6 * A_Index, 0)
        Sleep 40
    }
    Sleep 150
    Click("Up")
    Sleep 500
    WinGetPos(&qx, &qy, &qw, &qh, "ahk_id " listHwnd)
    W("列表拖动后位置 " qx "," qy "（原 " lx "," ly "）")
    Chk("列表 顶栏能拖动", (qx - lx > 50 && qy - ly > 25) ? 1 : 0, 1)
    WinMove(lx, ly, lw, lh, "ahk_id " listHwnd)
} else {
    W("!! 没找到列表窗口，跳过")
}

W("")
W("=== 汇总 PASS " PASS "  FAIL " FAIL " ===")
ExitApp FAIL ? 1 : 0
