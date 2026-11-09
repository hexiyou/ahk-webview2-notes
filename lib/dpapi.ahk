/* ============================================================================
   DPAPI —— 用当前 Windows 用户的凭据加密一段文本

   用途：SMTP 授权码要存进 config.ini，而 config.ini 是纯文本、用户随时会
   打开看、也可能被同步盘带走。写明文等于把邮箱密码摊在桌面上。

   CryptProtectData 用当前用户的登录凭据派生的密钥加密，密文只有**同一个
   用户在同一台机器**上解得开 —— 拷到别的机器、别的账号下就是一堆乱码。
   这正是我们要的：配置能随程序走，密码不能。

   不传 entropy。传了也只是把密钥材料写在源码里，反而是"看起来更安全"的
   自我安慰，还多一个"以后改了熵就解不开历史密文"的坑。

   解密失败一律返回空串，由调用方判"没配密码"，不要抛异常 —— 这个类会被
   投递子进程调用，子进程崩了主进程只会看到 5 分钟后的"超时未回执"，
   排查成本远高于当场返回空。
   ============================================================================ */

class Dpapi {
    ; 明文 → base64 密文。失败返回空串。
    static Protect(text) {
        try {
            src := Dpapi._Utf8(text)
            inp := Dpapi._Blob(src)
            out := Buffer(16, 0)
            if !DllCall("crypt32\CryptProtectData", "ptr", inp, "ptr", 0
                , "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", out, "int")
                return ""
            return Dpapi._B64(Dpapi._Take(out))
        } catch {
            return ""
        }
    }

    ; base64 密文 → 明文。失败（含换机器/换用户/密文损坏）返回空串。
    static Unprotect(b64) {
        if (b64 = "")
            return ""
        try {
            raw := Dpapi._UnB64(b64)
            if !raw || raw.Size = 0
                return ""
            inp := Dpapi._Blob(raw)
            out := Buffer(16, 0)
            if !DllCall("crypt32\CryptUnprotectData", "ptr", inp, "ptr", 0
                , "ptr", 0, "ptr", 0, "ptr", 0, "uint", 0, "ptr", out, "int")
                return ""
            bytes := Dpapi._Take(out)
            return bytes.Size ? StrGet(bytes, "UTF-8") : ""
        } catch {
            return ""
        }
    }

    /* 自检用：不解密也能判断"这串是不是我们的密文"。
       明文 base64 也有可能长得像，但 DPAPI 密文以 01 00 00 00（版本号）开头。 */
    static LooksEncrypted(s) {
        if (StrLen(s) < 20)
            return false
        raw := Dpapi._UnB64(s)
        return raw && raw.Size > 8 && NumGet(raw, 0, "uint") = 1
    }

    ; ---- 内部 -------------------------------------------------------------

    static _Utf8(s) {
        buf := Buffer(StrPut(s, "UTF-8") - 1, 0)
        StrPut(s, buf, "UTF-8")
        return buf
    }

    /* DATA_BLOB { DWORD cbData; BYTE *pbData; }
       x64 下指针要 8 字节对齐，所以 pbData 在偏移 8 而不是 4。 */
    static _Blob(buf) {
        b := Buffer(A_PtrSize = 8 ? 16 : 8, 0)
        NumPut("uint", buf.Size, b, 0)
        NumPut("ptr", buf.Ptr, b, A_PtrSize = 8 ? 8 : 4)
        return b
    }

    ; 取出输出 blob 并释放它（CryptProtectData 分配的内存要 LocalFree）
    static _Take(out) {
        n := NumGet(out, 0, "uint")
        p := NumGet(out, A_PtrSize = 8 ? 8 : 4, "ptr")
        if !p
            return Buffer(0)
        bytes := Buffer(n, 0)
        DllCall("RtlMoveMemory", "ptr", bytes, "ptr", p, "ptr", n)
        DllCall("kernel32\LocalFree", "ptr", p)
        return bytes
    }

    static _B64(buf) {
        n := 0
        DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", buf.Size
            , "uint", 1, "ptr", 0, "uint*", &n)          ; CRYPT_STRING_BASE64
        if !n
            return ""
        str := Buffer(n * 2, 0)
        DllCall("crypt32\CryptBinaryToStringW", "ptr", buf, "uint", buf.Size
            , "uint", 1, "ptr", str, "uint*", &n)
        /* CryptBinaryToStringW 会按 64 列插换行。INI 的值不能含换行，
           所以整个抹掉空白 —— base64 去掉换行不影响解码。 */
        return RegExReplace(StrGet(str, "UTF-16"), "\s")
    }

    static _UnB64(s) {
        n := 0
        DllCall("crypt32\CryptStringToBinaryW", "wstr", s, "uint", 0
            , "uint", 1, "ptr", 0, "uint*", &n, "ptr", 0, "ptr", 0)
        if !n
            return 0
        buf := Buffer(n, 0)
        DllCall("crypt32\CryptStringToBinaryW", "wstr", s, "uint", 0
            , "uint", 1, "ptr", buf, "uint*", &n, "ptr", 0, "ptr", 0)
        return buf
    }
}
