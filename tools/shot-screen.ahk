#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#SingleInstance Off
; ============================================================================
;  shot-screen.ahk —— 抓一张整个桌面的 BMP
;
;  为什么不用 PowerShell：这台机器的安全策略拦 Add-Type / Assembly.Load，
;  System.Drawing 拿不到，所以直接用 GDI BitBlt 自己在 AHK 里写 BMP。
;  用途：人工核对透明窗口合成后的真实观感（页面截图看不出桌面透不透）。
; ============================================================================

try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)
Sleep 150

out := (A_Args.Length >= 1 ? A_Args[1] : A_ScriptDir "\..\assets\_screen.bmp")

; 可选区域：shot-screen.ahk <out> <x> <y> <w> <h>
; 整屏 BMP 有 6MB，看图工具会嫌大，核对某个窗口时只抓那一块
x0 := 0, y0 := 0
W := A_ScreenWidth
H := A_ScreenHeight
if (A_Args.Length >= 5) {
    x0 := Integer(A_Args[2])
    y0 := Integer(A_Args[3])
    W := Integer(A_Args[4])
    H := Integer(A_Args[5])
}

hdc := DllCall("GetDC", "ptr", 0, "ptr")
hMem := DllCall("gdi32\CreateCompatibleDC", "ptr", hdc, "ptr")
hBmp := DllCall("gdi32\CreateCompatibleBitmap", "ptr", hdc, "int", W, "int", H, "ptr")
DllCall("gdi32\SelectObject", "ptr", hMem, "ptr", hBmp)
DllCall("gdi32\BitBlt", "ptr", hMem
    , "int", 0, "int", 0, "int", W, "int", H
    , "ptr", hdc, "int", x0, "int", y0, "uint", 0x00CC0020)   ; SRCCOPY

; 用 32bpp：和屏幕 DC 位深一致，GetDIBits 不做任何色彩转换
; （之前用 24bpp，转换后整张图偏暖，颜色全错）
bi := Buffer(40, 0)
NumPut("uint", 40, bi, 0)
NumPut("int", W, bi, 4)
NumPut("int", -H, bi, 8)
NumPut("ushort", 1, bi, 12)
NumPut("ushort", 32, bi, 14)

stride := W * 4
size := stride * H
pix := Buffer(size, 0)
DllCall("gdi32\GetDIBits", "ptr", hMem, "ptr", hBmp, "uint", 0, "uint", H
    , "ptr", pix, "ptr", bi, "uint", 0)

fh := Buffer(14, 0)
NumPut("ushort", 0x4D42, fh, 0)          ; "BM"
NumPut("uint", 54 + size, fh, 2)
NumPut("uint", 0, fh, 6)
NumPut("uint", 54, fh, 10)

if FileExist(out)
    FileDelete out
f := FileOpen(out, "w")
f.RawWrite(fh, 14)
f.RawWrite(bi, 40)
f.RawWrite(pix, size)
f.Close()

DllCall("gdi32\DeleteObject", "ptr", hBmp)
DllCall("gdi32\DeleteDC", "ptr", hMem)
DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
ExitApp 0
