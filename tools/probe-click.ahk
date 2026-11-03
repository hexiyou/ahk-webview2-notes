#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#SingleInstance Off
; ============================================================================
;  probe-click.ahk —— 验收"便签窗口能不能真的点进去"
;
;  思路：不靠"窗口有没有命中"这种间接判据，而是点一个**会改数据库**的按钮
;  （顶栏的置顶按钮），然后直接读库看 pinned 有没有翻转。翻转了就说明：
;      鼠标事件落到了窗口 → 落到了 WebView2 → 落到了页面按钮 → 消息桥通了
;  再点一次恢复原状，不留痕迹。
;
;  注意：别用 SendInput 敲键盘来测——本机沙箱里 SendInput 发键会卡住。
; ============================================================================

#Include ..\lib\sqlite.ahk

OUT := A_ScriptDir "\_click.log"
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

DB := A_AppData "\QuickNote\notes.db"
if !FileExist(DB) {
    W("!! 没有数据库：" DB)
    ExitApp 1
}
W("数据库 " DB)

CoordMode("Mouse", "Screen")

; 找一张便签窗口
hwnd := 0
loop 40 {
    hwnd := WinExist("便签 ")
    if hwnd
        break
    Sleep 150
}
Chk("找到便签窗口", hwnd ? 1 : 0, 1)
if !hwnd
    ExitApp 1

title := WinGetTitle("ahk_id " hwnd)
id := Trim(StrReplace(title, "便签"))
W("窗口 " title "  id=" id)

db := Sqlite(DB)
pin0 := db.Scalar("SELECT pinned FROM notes WHERE id = " id)
W("初始 pinned=" pin0)

WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
W("窗口位置 " wx "," wy " " ww "x" wh)

; 顶栏按钮：24x24、间距 1px、右侧内边距 4px，从右往左依次是
;   关闭(w-16) 菜单(w-41) 置顶(w-66) 源码(w-91)；纵向居中在 y+16
pinX := wx + ww - 66
pinY := wy + 16

; 先把窗口提到前面，免得被列表窗口盖住
WinActivate("ahk_id " hwnd)
Sleep 500

; ---- 点置顶按钮 -----------------------------------------------------------
MouseMove(pinX, pinY, 0)
Sleep 250
Click("Down")
Sleep 90
Click("Up")
Sleep 800

pin1 := db.Scalar("SELECT pinned FROM notes WHERE id = " id)
W("点一次后 pinned=" pin1)
Chk("点置顶按钮，库里 pinned 翻转", pin1 != pin0 ? 1 : 0, 1)

; ---- 再点一次恢复 ---------------------------------------------------------
MouseMove(pinX, pinY, 0)
Sleep 250
Click("Down")
Sleep 90
Click("Up")
Sleep 800

pin2 := db.Scalar("SELECT pinned FROM notes WHERE id = " id)
W("再点一次 pinned=" pin2)
Chk("再点一次恢复原值", pin2 = pin0 ? 1 : 0, 1)

; ---- 点正文，窗口应当获得焦点且仍然可见 -----------------------------------
MouseMove(wx + Round(ww / 2), wy + Round(wh / 2), 0)
Sleep 200
Click("Down")
Sleep 90
Click("Up")
Sleep 600

Chk("点正文后窗口仍然可见", DllCall("IsWindowVisible", "ptr", hwnd) ? 1 : 0, 1)
Chk("点正文后窗口成为前台", WinActive("ahk_id " hwnd) ? 1 : 0, 1)

db.Close()
W("")
W("=== 汇总 PASS " PASS "  FAIL " FAIL " ===")
ExitApp FAIL ? 1 : 0
