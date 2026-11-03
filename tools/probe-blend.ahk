#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#SingleInstance Off
; ============================================================================
;  probe-blend.ahk —— 便签卡片到底透不透？量像素说话
;
;  做法：同一张便签分别压在「纯黑底板」和「浅色桌面」上，各取卡片中心色。
;    半透明 → 两个值不同，且压黑时明显变暗
;    不透明 → 两个值完全相同，且等于便签色本身
;  同时取窗口左上角 3px 处：卡片有 12px 圆角，那里本该透出底色。
;  比看截图靠谱：截图有夜间模式色偏，肉眼分不清。
; ============================================================================

OUT := A_ScriptDir "\_blend.log"
try FileDelete OUT

W(s) {
    global OUT
    FileAppend s "`n", OUT, "UTF-8-RAW"
}

CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")

hwnd := 0
loop 40 {
    hwnd := WinExist("便签 ")
    if hwnd
        break
    Sleep 150
}
if !hwnd {
    W("!! 没找到便签窗口")
    ExitApp 1
}

WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
W("便签窗口 " wx "," wy " " ww "x" wh)

; ---- 黑底板 ---------------------------------------------------------------
bk := Gui("-Caption +ToolWindow", "backdrop")
bk.BackColor := "0x000000"
bk.Show("x100 y560 w460 h360 NoActivate")
Sleep 400

WinMove(150, 600, ww, wh, "ahk_id " hwnd)
WinActivate("ahk_id " hwnd)
Sleep 800
cOnBlack := PixelGetColor(150 + Round(ww / 2), 600 + Round(wh / 2), "RGB")
cornerBlack := PixelGetColor(150 + 2, 600 + 2, "RGB")
W("压在纯黑底板上：卡片中心 = " cOnBlack "  左上角 2px = " cornerBlack)

; ---- 浅色桌面 -------------------------------------------------------------
WinMove(150, 120, ww, wh, "ahk_id " hwnd)
Sleep 900
cOnDesk := PixelGetColor(150 + Round(ww / 2), 120 + Round(wh / 2), "RGB")
cornerDesk := PixelGetColor(150 + 2, 120 + 2, "RGB")
cDesk := PixelGetColor(60, 300, "RGB")
W("挪到浅色桌面：  卡片中心 = " cOnDesk "  左上角 2px = " cornerDesk)
W("桌面底色 = " cDesk)

bk.Destroy()

; ---- 结论 ------------------------------------------------------------------
W("")
if (cOnBlack != cOnDesk) {
    W("结论：卡片颜色随背景变化 → 半透明生效")
} else {
    W("结论：卡片颜色不变（" cOnBlack "）→ 仍然是不透明")
}
if (cornerDesk != cornerBlack)
    W("圆角处：两处底色不同 → 圆角外是透的")
else
    W("圆角处：两处相同（" cornerDesk "）→ 圆角没露出来，页面仍是实心矩形")

WinMove(wx, wy, ww, wh, "ahk_id " hwnd)
ExitApp 0
