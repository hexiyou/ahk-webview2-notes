#Requires AutoHotkey v2.0
; ============================================================================
;  settings-window.ahk —— 全局设置面板（单例）
;
;  和列表窗口是同一套路子：普通不透明窗口 + WebView2，页面只管表单，
;  校验和生效都回主程序（Hooks）。这样"哪些值是合法的"只有一处定义。
;
;  坑（都踩过，别重复踩）：
;    · COM 回调里不能 await / 不能弹菜单，所以动作一律 SetTimer(..., -10)
;    · Settings 窗口也要开 IsZoomControlEnabled=0，否则 Ctrl+滚轮 会整页缩放
;    · 热键校验会临时注册/注销热键，失败时必须把原配置重新绑回去，
;      否则用户"改了个非法快捷键"，原来的热键也没了
; ============================================================================

class SettingsWindow {
    static Ctx := 0
    static Hooks := 0
    static Win := 0

    static IsOpen() => SettingsWindow.Win ? 1 : 0

    static Open() {
        if SettingsWindow.Win {
            try {
                SettingsWindow.Win.gui.Show()
                SettingsWindow.PushInit()
                WinActivate("ahk_id " SettingsWindow.Win.gui.Hwnd)
                return
            } catch {
                SettingsWindow.Win := 0
            }
        }

        ctx := SettingsWindow.Ctx
        /* 列表窗口置顶时，从它打开的设置面板也得盖在它上面 —— 否则点完
           「设置…」什么都没看见，像是没反应。 */
        top := (ListWindow.IsOpen() && ListWindow.Topmost) ? 1 : 0
        g := Gui("-Caption +Resize" (top ? " +AlwaysOnTop" : ""), "设置")
        g.MarginX := 0
        g.MarginY := 0
        g.BackColor := "0xFFFDF8EE"
        g.OnEvent("Close", (*) => SettingsWindow.Close())
        g.OnEvent("Escape", (*) => SettingsWindow.Close())
        ; 同列表窗口：不接 Size，拖大窗口后页面还停在原尺寸（右边一片空白）
        g.OnEvent("Size", SettingsOnSize)

        geo := SettingsWindow.LoadGeo()
        g.Show("w" geo.w " h" geo.h " x" geo.x " y" geo.y)
        Win.RoundCorners(g.Hwnd, true)
        ; 尺寸下限：表单挤到 200 宽就没法看了
        OnMessage(0x0024, SettingsMinSize)

        try {
            wvc := WebView2.CreateControllerAsync(g.Hwnd, 0, ctx.dataDir, "", ctx.dllPath).await()
        } catch as e {
            MsgBox("设置窗口初始化失败：`n" CleanComError(e.Message), "便签", "Icon!")
            try g.Destroy()
            return
        }
        wv := wvc.CoreWebView2
        try {
            wvc.DefaultBackgroundColor := 0xFFFDF8EE
            wv.Settings.IsNonClientRegionSupportEnabled := 1
            wv.Settings.AreDefaultContextMenusEnabled := 0
            wv.Settings.IsStatusBarEnabled := 0
            wv.Settings.IsZoomControlEnabled := 0
            wv.Settings.AreDevToolsEnabled := ctx.devtools ? 1 : 0
            wv.Settings.AreBrowserAcceleratorKeysEnabled := ctx.devtools ? 1 : 0
        }
        wvc.Fill()
        wvc.IsVisible := 1

        SettingsWindow.Win := { gui: g, wv: wv, wvc: wvc }
        wv.add_WebMessageReceived(SettingsOnMessage)
        wv.Navigate(NoteWindow.FileUrl(ctx.uiDir "\settings.html"))

        SetTimer(SettingsRefill, -200)
        SetTimer(SettingsRefill, -600)
    }

    static Close() {
        if !SettingsWindow.Win
            return
        SettingsWindow.SaveGeo()
        try SettingsWindow.Win.wvc.Close()
        try SettingsWindow.Win.gui.Destroy()
        SettingsWindow.Win := 0
    }

    static Refill() {
        if !SettingsWindow.Win
            return
        try {
            SettingsWindow.Win.wvc.Fill()
            SettingsWindow.Win.wvc.IsVisible := 1
        }
    }

    static OnSize(minMax) {
        if (minMax = -1)
            return
        SettingsWindow.Refill()
        SetTimer(SettingsSaveGeoSoon, -400)
    }

    /* 默认摆中间。工作区可能是 0（远程/无显示器），Min 之后会变负数，
       Gui.Show 直接抛错，所以上下限都要有。 */
    static DefaultGeo() {
        wa := Win.WorkArea()
        w := Max(420, Min(520, wa.w - 60))
        h := Max(520, Min(700, wa.h - 80))
        x := Max(0, wa.l + (wa.w - w) // 2)
        y := Max(0, wa.t + (wa.h - h) // 2 - 20)
        return { x: x, y: y, w: w, h: h }
    }

    ; 跟列表窗口同一套：一行 "x,y,w,h"，读出来过 Win.Clamp 防"上次在另一块屏"
    static LoadGeo() {
        d := SettingsWindow.DefaultGeo()
        s := App.Cfg("window", "settingsGeo", "")
        if (s = "")
            return d
        p := StrSplit(s, ",")
        if (p.Length != 4)
            return d
        if !(IsNumber(p[1]) && IsNumber(p[2]) && IsNumber(p[3]) && IsNumber(p[4]))
            return d
        return Win.Clamp(p[1] + 0, p[2] + 0, Max(p[3] + 0, 460), Max(p[4] + 0, 420))
    }

    static SaveGeo() {
        if !SettingsWindow.Win
            return
        r := Win.Rect(SettingsWindow.Win.gui.Hwnd)
        c := Win.ClientSize(SettingsWindow.Win.gui.Hwnd)
        if (c.w < 200 || c.h < 150)
            return
        try App.SetCfg("window", "settingsGeo", r.x "," r.y "," c.w "," c.h)
    }

    static StartMove() {
        if !SettingsWindow.Win
            return
        try {
            hwnd := SettingsWindow.Win.gui.Hwnd
            DllCall("ReleaseCapture")
            PostMessage(0x00A1, 2, 0, , "ahk_id " hwnd)
        }
    }

    static Send(json) {
        if !SettingsWindow.Win
            return
        try SettingsWindow.Win.wv.PostWebMessageAsJson(json)
    }

    /* 把所有配置项打包发给页面。数值型原样发（JSON 里不能加引号），
       字符串走 JsonQuote。颜色表也是这里发 —— 六个颜色名/中文名/色值只在
       NoteWindow.Colors() 里定义一次，页面照着画色块，不再抄一份表。 */
    static PushInit() {
        j := '{"type":"init","cfg":{'
        j .= '"transparent":' (App.Cfg("appearance", "transparent", 1) ? 1 : 0) ','
        j .= '"fontSize":' App.Cfg("appearance", "fontSize", 15) ','
        j .= '"showAllOnStart":' (App.Cfg("app", "showAllOnStart", 0) ? 1 : 0) ','
        j .= '"openListOnStart":' (App.Cfg("app", "openListOnStart", 0) ? 1 : 0) ','
        j .= '"defColor":' JsonQuote(App.Cfg("window", "color", "yellow")) ','
        j .= '"hkNew":' JsonQuote(App.Cfg("hotkey", "new", "^!n")) ','
        j .= '"hkList":' JsonQuote(App.Cfg("hotkey", "list", "^!l")) ','
        j .= '"hkToggle":' JsonQuote(App.Cfg("hotkey", "toggle", "^!h")) ','
        j .= '"colors":['
        all := NoteWindow.Colors()
        first := true
        ; 按 ColorKeys() 排：色块顺序固定，用户下次打开还是同一个位置
        for key in NoteWindow.ColorKeys() {
            if !all.Has(key)
                continue
            if !first
                j .= ","
            first := false
            label := NoteWindow.ColorLabel(key)
            j .= '{"k":' JsonQuote(key) ',"n":' JsonQuote(label) ',"h":' JsonQuote(all[key]) '}'
        }
        j .= ']},"info":{'
        j .= '"dataDir":' JsonQuote(App.DataDir) ','
        j .= '"about":' JsonQuote("QuickNote · AHK " A_AhkVersion " · SQLite "
            . Sqlite.Version() " · 当前 " App.Store.Count() " 张便签")
        j .= '}}'
        SettingsWindow.Send(j)
    }

    static OnMessage(sender, args) {
        raw := ""
        try raw := args.WebMessageAsJson
        if (raw = "")
            return
        type := JsonStr(raw, "type")
        if (type = "drag-start") {
            try SettingsWindow.StartMove()
            return
        }
        ; 其余动作（保存要校验热键、可能重建窗口）都挪到独立线程
        SetTimer(SettingsTick(raw), -10)
    }

    static Handle(raw) {
        switch JsonStr(raw, "type") {
            case "ready":
                SettingsWindow.PushInit()

            case "save":
                err := ""
                if SettingsWindow.Hooks && SettingsWindow.Hooks.Has("onSave")
                    try err := SettingsWindow.Hooks["onSave"](raw)
                SettingsWindow.Send('{"type":"saved","ok":' (err = "" ? 1 : 0)
                    . ',"msg":' JsonQuote(err) '}')

            case "close":
                SettingsWindow.Close()

            case "dataDir":
                if SettingsWindow.Hooks && SettingsWindow.Hooks.Has("onDataDir")
                    try SettingsWindow.Hooks["onDataDir"]()

            case "log":
                if SettingsWindow.Hooks && SettingsWindow.Hooks.Has("onLog")
                    try SettingsWindow.Hooks["onLog"]()
        }
    }
}

; 顶层包装：类静态方法直接喂给 COM 事件/SetTimer 会拿到不可调用的对象
SettingsOnMessage(sender, args) {
    SettingsWindow.OnMessage(sender, args)
}

SettingsRefill() {
    SettingsWindow.Refill()
}

SettingsOnSize(g, minMax, w, h) {
    SettingsWindow.OnSize(minMax)
}

SettingsSaveGeoSoon() => SettingsWindow.SaveGeo()

/* WM_GETMINMAXINFO：设置面板的下限。表单挤窄了标签和输入框会叠在一起。 */
SettingsMinSize(wParam, lParam, msg, hwnd) {
    if !SettingsWindow.Win || hwnd != SettingsWindow.Win.gui.Hwnd
        return
    NumPut("int", 460, lParam, 24)
    NumPut("int", 420, lParam, 28)
}

; 闭包捕获这一条原始消息，跑在 SetTimer 起的独立线程里
SettingsTick(raw) {
    return () => SettingsWindow.Handle(raw)
}
