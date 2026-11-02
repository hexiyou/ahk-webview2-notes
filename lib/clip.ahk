#Requires AutoHotkey v2.0
; ============================================================================
;  clip.ahk —— 把一张图片文件放进剪贴板
;
;  为什么不能交给页面里的 navigator.clipboard：
;  右键菜单用的是**原生菜单**（宿主 Menu.Show），点下去的那一刻页面已经没有
;  用户手势（user activation）了，Chromium 会直接拒掉 Clipboard API —— 这也是
;  编辑菜单里"复制"要绕回宿主写剪贴板的原因。图片同理，只能由宿主塞字节。
;
;  写两种格式，缺一不可：
;    CF_DIB (8)   24 位、白底、设备无关位图。画图 / Word / Excel / 微信 / QQ
;                 都认它，是 Windows 上"粘贴图片"的公共分母。
;    "PNG"        RegisterClipboardFormat 注册格式。Chromium / Firefox 粘贴时
;                 优先读它，透明通道能保住。CF_DIB 只有 24 位，透明部分会被
;                 合到白底上 —— 截图素材粘进网页就变成白底方块了。
;  只写 CF_DIB：透明会丢。
;  只写 PNG：老程序（部分 Office 版本、老版画图）收不到，粘贴出来是空的。
;
;  ★ 两种格式必须在**同一次** OpenClipboard / EmptyClipboard 里写完：
;    EmptyClipboard 会把先前放进去的格式全清掉，分两次写等于白写第一种。
;
;  ★ GDI+ 只认 BMP / JPEG / GIF / PNG / TIFF，**不认 WebP**（项目允许插 webp）。
;    这条路失败时 SetImageFile 返回 false，上层提示用户改用「另存为」——
;    另存为是纯文件复制，什么格式都行。
; ============================================================================

class Clip {
    /* 把本地图片写进剪贴板。成功 true，失败 false（调用方负责提示）。 */
    static SetImageFile(path) {
        if (path = "" || !FileExist(path))
            return false
        if !Clip.GdipStart()
            return false

        bmp := 0, hbm := 0, hDib := 0, hPng := 0
        try {
            if (DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", path, "ptr*", &bmp) != 0)
                return false
            /* 第三个参数是这个位图的背景色（ARGB）。透明 PNG 落在白底上，
               粘到白纸文档里不会出现黑块。 */
            if (DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", bmp
                , "ptr*", &hbm, "uint", 0xFFFFFFFF) != 0)
                return false

            hDib := Clip.DibFromHBITMAP(hbm)
            if !hDib
                return false
            hPng := Clip.FileBlock(path)          ; 顺带写一份 PNG，拿不到就算了

            if !Clip.OpenClip()
                return false
            okDib := 0
            try {
                DllCall("EmptyClipboard")
                okDib := DllCall("SetClipboardData", "uint", 8, "ptr", hDib, "ptr")
                if okDib
                    hDib := 0                     ; 所有权已交给系统，不能再 GlobalFree
                fmt := Clip.PngFormat()
                if (hPng && fmt) {
                    if DllCall("SetClipboardData", "uint", fmt, "ptr", hPng, "ptr")
                        hPng := 0
                }
            } finally {
                DllCall("CloseClipboard")
            }
            return okDib ? true : false
        } finally {
            if hDib
                DllCall("GlobalFree", "ptr", hDib)
            if hPng
                DllCall("GlobalFree", "ptr", hPng)
            if hbm
                DllCall("DeleteObject", "ptr", hbm)
            if bmp
                DllCall("gdiplus\GdipDisposeImage", "ptr", bmp)
        }
    }

    ; ---- 下面是零件，外部不用管 ------------------------------------------

    /* GdiplusStartup 一个进程只做一次。GdiplusStartupInput 结构（x64 24 字节）：
       version(4) + 对齐(4) + DebugEventCallback(8) + SuppressBackgroundThread(4)
       + SuppressExternalCodecs(4)。只有 version 必须写 1，其余留 0。 */
    static GdipStart() {
        static token := 0
        if token
            return token
        si := Buffer(24, 0)
        NumPut("uint", 1, si, 0)
        t := 0
        if (DllCall("gdiplus\GdiplusStartup", "ptr*", &t, "ptr", si, "ptr", 0) != 0)
            return 0
        token := t
        return token
    }

    /* HBITMAP(DDB) -> CF_DIB 要的那块 HGLOBAL（BITMAPINFOHEADER + 像素）。
       用 24 位而不是 32 位：32 位 BI_RGB 的 alpha 字节在多数程序里被当成
       "未使用"，粘出来要么全黑要么全透，反而不如白底可靠。 */
    static DibFromHBITMAP(hbm) {
        bm := Buffer(32, 0)                       ; BITMAP（x64 共 32 字节）
        if !DllCall("GetObjectW", "ptr", hbm, "int", 32, "ptr", bm)
            return 0
        w := NumGet(bm, 4, "int")
        h := NumGet(bm, 8, "int")
        if (h < 0)
            h := -h
        if (w <= 0 || h <= 0)
            return 0

        stride := ((w * 24 + 31) // 32) * 4       ; 每行按 4 字节对齐
        total := 40 + stride * h
        buf := Buffer(total, 0)
        NumPut("uint", 40, buf, 0)                ; biSize
        NumPut("int", w, buf, 4)                  ; biWidth
        NumPut("int", h, buf, 8)                  ; 正数 = 自下而上
        NumPut("ushort", 1, buf, 12)              ; biPlanes
        NumPut("ushort", 24, buf, 14)             ; biBitCount
        NumPut("uint", 0, buf, 16)                ; BI_RGB
        NumPut("uint", stride * h, buf, 20)       ; biSizeImage

        hdc := DllCall("GetDC", "ptr", 0, "ptr")
        if !hdc
            return 0
        got := DllCall("GetDIBits", "ptr", hdc, "ptr", hbm, "uint", 0, "uint", h
            , "ptr", (buf.Ptr + 40), "ptr", buf, "uint", 0)
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
        if (got = 0)
            return 0
        return Clip.GlobalCopy(buf, total)
    }

    ; 把一段 Buffer 拷进 HGLOBAL（移动内存块，SetClipboardData 只认这种）
    static GlobalCopy(buf, size) {
        hMem := DllCall("GlobalAlloc", "uint", 0x0042, "uptr", size, "ptr")  ; MOVEABLE|ZEROINIT
        if !hMem
            return 0
        p := DllCall("GlobalLock", "ptr", hMem, "ptr")
        if !p {
            DllCall("GlobalFree", "ptr", hMem)
            return 0
        }
        DllCall("RtlMoveMemory", "ptr", p, "ptr", buf, "uptr", size)
        DllCall("GlobalUnlock", "ptr", hMem)
        return hMem
    }

    ; 整个文件读成一块 HGLOBAL（给 "PNG" 剪贴板格式用）
    static FileBlock(path) {
        try size := FileGetSize(path)
        catch
            return 0
        if (size <= 0 || size > 64 * 1024 * 1024)
            return 0
        buf := Buffer(size, 0)
        try {
            f := FileOpen(path, "r")
            f.RawRead(buf, size)
            f.Close()
        } catch {
            return 0
        }
        return Clip.GlobalCopy(buf, size)
    }

    /* 剪贴板是全局独占资源，输入法、剪贴板管理器、Explorer 都可能正开着它。
       一次失败就放弃会表现成"偶尔复制不了"，退避重试几次就稳了。 */
    static OpenClip(retries := 8) {
        loop retries {
            if DllCall("OpenClipboard", "ptr", A_ScriptHwnd)
                return true
            Sleep 20
        }
        return false
    }

    static PngFormat() {
        static fmt := 0
        if !fmt
            fmt := DllCall("RegisterClipboardFormatW", "wstr", "PNG", "uint")
        return fmt
    }
}
