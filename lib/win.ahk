#Requires AutoHotkey v2.0
; ============================================================================
;  win.ahk —— 窗口外观与摆放
;
;  这里只放"纯 Win32 的外观手术"，不涉及 WebView2，也不认识便签概念。
;  两条外观路线（由外观配置决定，见 note.ahk）：
;
;    透明路线：+WS_EX_LAYERED +WS_EX_NOREDIRECTIONBITMAP，WebView2 背景 alpha=0，
;              圆角/阴影/底色全部由页面 CSS 用 rgba 画。桌面能透出来。
;    普通路线：不加扩展样式，WebView2 背景 alpha=255，Win11 交给 DWM 做圆角。
;
;  坑：一旦调了 SetLayeredWindowAttributes(LWA_ALPHA)，整窗会被"整片淡化"，
;      透明像素会变黑；所以透明路线**绝不**碰 LWA。
; ============================================================================

class Win {
    ; ---- 系统能力探测 -------------------------------------------------------

    static IsWin11() {
        static cache := -1
        if (cache != -1)
            return cache
        ; RtlGetVersion 比 GetVersionEx 靠谱（后者会被兼容层骗）
        vi := Buffer(284, 0)
        NumPut("uint", 284, vi, 0)
        try DllCall("ntdll\RtlGetVersion", "ptr", vi)
        build := NumGet(vi, 12, "uint")
        cache := (build >= 22000)
        return cache
    }

    ; ---- 扩展样式 -----------------------------------------------------------

    static AddExStyle(hwnd, style) => WinSetExStyle("+" Format("{:#x}", style), "ahk_id " hwnd)
    static DelExStyle(hwnd, style) => WinSetExStyle("-" Format("{:#x}", style), "ahk_id " hwnd)

    ; 透明路线必须的两个样式：
    ;   WS_EX_LAYERED (0x80000)            分层窗口，才能有 per-pixel alpha
    ;   WS_EX_NOREDIRECTIONBITMAP (0x200000) 不分配重定向表面，避免黑底
    static MakeTransparent(hwnd) {
        try Win.AddExStyle(hwnd, 0x00080000 | 0x00200000)
    }

    ; Win11 的 DWM 圆角（DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2）
    static RoundCorners(hwnd, enable := true) {
        if !Win.IsWin11()
            return false
        pref := enable ? 2 : 1        ; 2=ROUND, 1=DONOTROUND
        v := Buffer(4, 0)
        NumPut("int", pref, v, 0)
        try {
            hr := DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 33
                , "ptr", v, "int", 4, "int")
            return hr = 0
        }
        return false
    }

    ; 深色边框/标题栏（Win11 22000+ 支持属性 20，只影响系统绘制的那一圈）
    static ImmersiveDarkMode(hwnd, enable := true) {
        v := Buffer(4, 0)
        NumPut("int", enable ? 1 : 0, v, 0)
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 20
            , "ptr", v, "int", 4, "int")
    }

    ; ---- 几何 ---------------------------------------------------------------

    ; 主屏工作区（已扣掉任务栏）
    static WorkArea() {
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        return { l: l, t: t, r: r, b: b, w: r - l, h: b - t }
    }

    ; 判断矩形是否有足够面积落在某块屏幕的工作区内
    static IsOnScreen(x, y, w, h) {
        count := MonitorGetCount()
        loop count {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            ox := Min(x + w, r) - Max(x, l)
            oy := Min(y + h, b) - Max(y, t)
            if (ox >= 40 && oy >= 30)
                return true
        }
        return false
    }

    ; 摆正：尺寸夹到合理范围，位置拉回工作区。用于恢复上次几何时的兜底
    ; （拔掉副屏后，上次的位置可能已经在不存在的屏幕上）
    static Clamp(x, y, w, h) {
        wa := Win.WorkArea()
        w := Round(Min(Max(w, 160), wa.w))
        h := Round(Min(Max(h, 120), wa.h))
        if !Win.IsOnScreen(x, y, w, h) {
            x := wa.l + Round((wa.w - w) / 2)
            y := wa.t + Round((wa.h - h) / 2)
        }
        ; 至少留 40px 在屏幕内，别让标题栏跑到任务栏后面
        x := Min(Max(x, wa.l - w + 80), wa.r - 80)
        y := Min(Max(y, wa.t), wa.b - 40)
        return { x: x, y: y, w: w, h: h }
    }

    ; 新建便签的落点：在主屏右上角按序号斜着排，避免全叠在一起
    static Cascade(index, w, h) {
        wa := Win.WorkArea()
        step := 28
        n := Mod(index, 12)
        x := wa.r - w - 24 - n * step
        y := wa.t + 24 + n * step
        ; 排到左边界或下边界就回折
        x := Max(x, wa.l + 24)
        y := Min(y, wa.b - h - 24)
        return { x: Round(x), y: Round(y), w: w, h: h }
    }

    ; 取窗口当前的位置尺寸（含边框，无边框窗口两者一致）
    static Rect(hwnd) {
        try {
            WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
            return { x: x, y: y, w: w, h: h }
        }
        return { x: 0, y: 0, w: 0, h: 0 }
    }
}
