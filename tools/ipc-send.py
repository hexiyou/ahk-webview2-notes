#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipc-send.py —— 用 Python 调用 QuickNote 的完整示例（含回执）

这是「外部程序怎么把内容塞进 QuickNote」的参考实现，只依赖标准库（ctypes），
不需要 pip 装任何东西。把它当模板抄到自己的程序里就行。

用法：
    python ipc-send.py --text "买牛奶"
    python ipc-send.py --text-file msg.txt
    python ipc-send.py --json '{"text":"hi","color":"blue"}'
    python ipc-send.py --json-file payload.json
    python ipc-send.py --new                 只要一张空便签
    python ipc-send.py --list                打开便签列表
    python ipc-send.py --text "hi" --ack     等回执，把新便签 id 打出来

    --hwnd N     指定目标窗口（多实例时用，默认按标题找）

原理（三句话）：
    1. FindWindow("QuickNoteAnchor") 拿到程序那个藏起来的锚点窗口；
    2. SendMessage 发 0x8010 / 0x8011 / WM_COPYDATA；
    3. 想拿新便签的 id，就在载荷里带 replyTo=自己的窗口句柄，
       建好后它会 PostMessage(WM_ACK=0x8014) 回来，wParam 就是 id。

⚠️ 注意：SendMessage 返回 1 只代表「已受理」，便签是随后在主线程建出来的。
   所以别在 SendMessage 返回后立刻去猜 id —— 要么等回执，要么按标题去查。
"""

import argparse
import ctypes
import json
import sys
import time
from ctypes import wintypes

# ---------------------------------------------------------------- Win32 常量

ANCHOR_TITLE = "QuickNoteAnchor"

WM_COPYDATA = 0x004A
WM_NEW = 0x8010
WM_LIST = 0x8011
WM_ACK = 0x8014

MAGIC = 0x514E            # wParam 必须是这个数，随便一个 0x8010 不算
CD_MAGIC = 0x514E3031     # "QN01"，放在 COPYDATASTRUCT.dwData 里
MAX_BYTES = 65536         # 服务端的载荷上限
PM_REMOVE = 0x0001

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

LRESULT = ctypes.c_ssize_t
WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wintypes.HWND, wintypes.UINT,
                             wintypes.WPARAM, wintypes.LPARAM)


class WNDCLASSW(ctypes.Structure):
    _fields_ = [
        ("style", wintypes.UINT),
        ("lpfnWndProc", WNDPROC),
        ("cbClsExtra", ctypes.c_int),
        ("cbWndExtra", ctypes.c_int),
        ("hInstance", wintypes.HINSTANCE),
        ("hIcon", wintypes.HICON),
        ("hCursor", wintypes.HANDLE),
        ("hbrBackground", wintypes.HBRUSH),
        ("lpszMenuName", wintypes.LPCWSTR),
        ("lpszClassName", wintypes.LPCWSTR),
    ]


class COPYDATASTRUCT(ctypes.Structure):
    """注意 64 位下的对齐：dwData 占 8 字节，所以 lpData 在偏移 16 而不是 12。"""
    _fields_ = [
        ("dwData", ctypes.c_size_t),
        ("cbData", wintypes.DWORD),
        ("lpData", ctypes.c_void_p),
    ]


user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
user32.FindWindowW.restype = wintypes.HWND
user32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, ctypes.c_void_p]
user32.SendMessageW.restype = LRESULT
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.PostMessageW.restype = wintypes.BOOL
user32.RegisterClassW.argtypes = [ctypes.POINTER(WNDCLASSW)]
user32.RegisterClassW.restype = wintypes.ATOM
user32.CreateWindowExW.argtypes = [
    wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, wintypes.LPVOID,
]
user32.CreateWindowExW.restype = wintypes.HWND
user32.PeekMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND,
                                wintypes.UINT, wintypes.UINT, wintypes.UINT]
user32.PeekMessageW.restype = wintypes.BOOL
user32.TranslateMessage.argtypes = [ctypes.POINTER(wintypes.MSG)]
user32.DispatchMessageW.argtypes = [ctypes.POINTER(wintypes.MSG)]
user32.DispatchMessageW.restype = LRESULT
user32.DefWindowProcW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.DefWindowProcW.restype = LRESULT

HWND_MESSAGE = wintypes.HWND(0xFFFFFFFFFFFFFFFD if ctypes.sizeof(ctypes.c_void_p) == 8 else 0xFFFFFFFD)


def find_anchor():
    """找不到就说明 QuickNote 没在跑（或者跑在别的登录会话里）。"""
    return user32.FindWindowW(None, ANCHOR_TITLE)


def send_copy(hwnd, payload: bytes, magic: int = CD_MAGIC) -> int:
    buf = ctypes.create_string_buffer(payload, len(payload))
    cds = COPYDATASTRUCT(magic, len(payload), ctypes.addressof(buf))
    return int(user32.SendMessageW(hwnd, WM_COPYDATA, 0, ctypes.byref(cds)))


def send_simple(hwnd, msg: int, wparam: int = MAGIC) -> int:
    return int(user32.SendMessageW(hwnd, msg, wparam, None))


class AckReceiver:
    """一个只有消息循环的隐藏窗口，专门用来接 WM_ACK。

    如果你自己的程序已经有窗口（Tk、Qt、WinForms、pywin32 都行），
    直接把那个窗口的句柄填进 replyTo，在它的消息处理里截 0x8014 即可，
    不必再建这个窗口。
    """

    CLASS_NAME = "QuickNoteIpcDemoAck"

    def __init__(self):
        self.ack_ids = []
        # ★ 必须自己留一份引用：回调对象被 GC 掉之后，系统再回调就是野指针
        self._proc = WNDPROC(self._wndproc)
        hinst = kernel32.GetModuleHandleW(None)
        wc = WNDCLASSW()
        wc.lpfnWndProc = self._proc
        wc.hInstance = hinst
        wc.lpszClassName = self.CLASS_NAME
        self._atom = user32.RegisterClassW(ctypes.byref(wc))
        self.hwnd = user32.CreateWindowExW(
            0, self.CLASS_NAME, "", 0, 0, 0, 0, 0,
            HWND_MESSAGE, None, hinst, None)
        if not self.hwnd:
            raise ctypes.WinError(ctypes.get_last_error())

    def _wndproc(self, hwnd, msg, wparam, lparam):
        if msg == WM_ACK:
            self.ack_ids.append(int(wparam))
            return 0
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam)

    def wait(self, seconds=3.0):
        """抽消息直到收到回执或超时，返回便签 id（0 = 没等到）。"""
        end = time.time() + seconds
        msg = wintypes.MSG()
        while time.time() < end and not self.ack_ids:
            if user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, PM_REMOVE):
                user32.TranslateMessage(ctypes.byref(msg))
                user32.DispatchMessageW(ctypes.byref(msg))
            else:
                time.sleep(0.02)
        return self.ack_ids[0] if self.ack_ids else 0


def main():
    ap = argparse.ArgumentParser(description="往 QuickNote 里塞一张便签")
    ap.add_argument("--text", help="正文（纯文本，换行用真实换行）")
    ap.add_argument("--text-file", help="从文件读正文（UTF-8）")
    ap.add_argument("--json", help='扁平 JSON，例如 {"text":"hi","color":"blue"}')
    ap.add_argument("--json-file", help="从文件读 JSON 载荷")
    ap.add_argument("--new", action="store_true", help="只新建一张空便签")
    ap.add_argument("--list", action="store_true", help="打开便签列表")
    ap.add_argument("--ack", action="store_true", help="等回执并打印新便签 id")
    ap.add_argument("--hwnd", type=int, default=0, help="指定目标窗口句柄")
    ap.add_argument("--timeout", type=float, default=3.0, help="等回执的秒数")
    args = ap.parse_args()

    hwnd = args.hwnd or find_anchor()
    if not hwnd:
        print("找不到 QuickNote 的锚点窗口 —— 程序没在运行？", file=sys.stderr)
        print("（也可能是它跑在别的用户会话/更高权限下，窗口消息跨不过去）", file=sys.stderr)
        return 2

    receiver = None
    if args.ack:
        receiver = AckReceiver()

    if args.list:
        reply = send_simple(hwnd, WM_LIST)
        print(f"mode=list reply={reply} ack=0")
        return 0 if reply else 1

    if args.new:
        reply = send_simple(hwnd, WM_NEW)
        print(f"mode=new reply={reply} ack=0")
        return 0 if reply else 1

    # ---- 带内容：纯文本或扁平 JSON ----------------------------------------
    if args.json_file:
        payload = open(args.json_file, "r", encoding="utf-8").read()
        mode = "json"
    elif args.json:
        payload = args.json
        mode = "json"
    elif args.text_file:
        payload = open(args.text_file, "r", encoding="utf-8").read()
        mode = "text"
    elif args.text is not None:
        payload = args.text
        mode = "text"
    else:
        ap.error("要么给 --text/--text-file/--json，要么用 --new/--list")

    if mode == "json" and receiver:
        # 往调用方给的 JSON 里补 replyTo（只处理以 { 开头的扁平对象）
        target = json.loads(payload)
        target["replyTo"] = receiver.hwnd
        payload = json.dumps(target, ensure_ascii=False)
    elif receiver:
        payload = json.dumps({"text": payload, "replyTo": receiver.hwnd},
                             ensure_ascii=False)

    data = payload.encode("utf-8")
    if len(data) > MAX_BYTES:
        print(f"载荷 {len(data)} 字节，超过上限 {MAX_BYTES}，不发", file=sys.stderr)
        return 2

    reply = send_copy(hwnd, data)
    note_id = receiver.wait(args.timeout) if receiver else 0
    print(f"mode=copy reply={reply} ack={note_id} bytes={len(data)}")
    if args.ack and not note_id:
        print("没等到回执（受理了但没建出来？看看 app.log）", file=sys.stderr)
    return 0 if reply else 1


if __name__ == "__main__":
    sys.exit(main())
