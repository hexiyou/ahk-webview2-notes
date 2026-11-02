# 外部调用接口（IPC）—— 让别的程序往便签里塞东西

> 一句话：**不用开端口、不用装插件，发一条 Windows 消息，便签就出来了。**
>
> 相关文件：`lib/ipc.ahk`（宿主侧实现）、`tools/ipc-send.ahk`（AHK 独立示例）、
> `tools/ipc-send.py`（Python 示例）、`note.ahk --selftest-ipc`（自检）。

---

## 1. 它能干什么

| 能力 | 消息 | 典型场景 |
|---|---|---|
| 新建一张空便签 | `0x8010` | 快捷方式/热键替代品、脚本里"开张纸记一下" |
| 打开便签列表 | `0x8011` | 从别的工具一键跳到便签总览 |
| 带内容新建（纯文本或 JSON） | `WM_COPYDATA` | 下载完成通知、计划任务结果、CI 失败摘要、番茄钟、剪贴板暂存 |
| 建好后回执（告诉你新便签 id） | `0x8014`（宿主发出） | 需要后续操作那张便签（改内容/打开/统计） |

这条通道是本程序"可被编排"的基础：**便签本体只负责记录与展示，产生内容的一方
（你的脚本、你的定时任务、你的其他小工具）不必和它耦合**，不需要改它的源码、
不需要它提供插件系统。

---

## 2. 为什么是窗口消息，不是 HTTP

| | 窗口消息（本方案） | HTTP 服务 |
|---|---|---|
| 寻址 | 系统给的窗口句柄，天然唯一 | 端口 + 路由，要和别的服务抢 |
| 鉴权 | 不需要：同会话同权限才发得进来 | 必须自己做，否则本机任何程序都能写 |
| 防火墙 | 不涉及 | 首次监听会弹窗，企业环境常被策略挡 |
| 失败语义 | 目标没跑 → `FindWindow` 返回 0，一清二楚 | 连接超时/半开连接，要区分一堆错 |
| 返回值 | `SendMessage` 同步拿（受理/拒绝） | 要写完一套响应格式 |
| 代价 | 只能在**同一登录会话、同一权限级别**内用 | 可跨机 |

便签是常驻桌面的小工具，调用方几乎都是本机脚本 —— 窗口消息的代价正好落在
不需要的地方，收益（零配置、零鉴权、零端口）全落在需要的地方。

---

## 3. 它是怎么工作的

```
外部进程                          QuickNote 进程
   │                                    │
   │ FindWindow("QuickNoteAnchor")      │  锚点窗口：1×1，藏在屏幕外
   │───────────────────────────────────>│  （标题 QuickNoteAnchor
   │                                    │    属性 QuickNote.IPC=1）
   │ SendMessage(0x8010 / 0x8011 /      │
   │             WM_COPYDATA)           │
   │───────────────────────────────────>│ OnMessage 回调（新线程）
   │                                    │   只做：校验 → 入队 → 返回 1
   │<────────────── 返回 1（已受理）────│
   │                                    │ SetTimer(-1) 回主线程派发
   │                                    │   写库 → 建 WebView2 窗口
   │<────────── PostMessage(0x8014,id)──│ 有 replyTo 才回执
```

三处设计都是被坑出来的，改代码前务必看 `lib/ipc.ahk` 顶部注释：

1. **消息回调里绝对不能建窗口。** 回调跑在 AHK 的新线程，可以随时打断主线程；
   而创建 WebView2 controller 需要 `await`，COM 回调里 `await` 永不返回。
   真在那里建窗，表现是发送方的 `SendMessage` 一直卡住、整个程序像死了。
   所以回调只入队，真正的活儿交给 `SetTimer(IpcDrain, -1)`。
2. **`WM_COPYDATA` 是同步的**，对方会等到你返回。返回 1 只代表"已受理"，
   不代表便签已经建好 —— 排队建窗还在后面。要 id 就传 `replyTo` 等回执。
3. **不改数据库、不弹菜单。** 一个回调里做重活，等于给所有便签制造卡顿。

---

## 4. 快速上手

### AHK（最省事）

```autohotkey
; 找到那个锚点窗口，发一条 COPYDATA 就完事
hwnd := DllCall("FindWindowW", "ptr", 0, "wstr", "QuickNoteAnchor", "ptr")

payload := '{"text":"买牛奶\n记得看保质期","color":"blue"}'
n := StrPut(payload, "UTF-8")
buf := Buffer(n, 0), StrPut(payload, buf, "UTF-8")
cds := Buffer(24, 0)                       ; 64 位 COPYDATASTRUCT 是 24 字节
NumPut("ptr", 0x514E3031, cds, 0)          ; "QN01"
NumPut("uint", n - 1, cds, 8)
NumPut("ptr", buf.Ptr, cds, 16)
SendMessage(0x004A, 0, cds.Ptr, , "ahk_id " hwnd)
```

完整可跑版本（含参数解析、回执、错误分支）：`tools\ipc-send.ahk`。
**它不引用本项目的任何源码**，直接拷到你的项目里就能用。

### Python

```bash
python tools\ipc-send.py --text "买牛奶"
python tools\ipc-send.py --json '{"text":"hi","color":"blue","pin":1}'
python tools\ipc-send.py --new
python tools\ipc-send.py --list
python tools\ipc-send.py --text "要 id 的那种" --ack     # 打印新便签 id
```

`tools\ipc-send.py` 只用标准库（`ctypes`），里面把 `COPYDATASTRUCT`、回执窗口、
消息循环都写全了，抄 `send_copy()` 和 `AckReceiver` 两段即可。

### C# / 其他语言

关键只有三个 API：

```csharp
[DllImport("user32", CharSet = CharSet.Unicode)]
static extern IntPtr FindWindow(string cls, string title);

[DllImport("user32")]
static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, ref COPYDATASTRUCT lParam);

[StructLayout(LayoutKind.Sequential)]
struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }
```

`SendMessage` 的 `wParam` 是 `IntPtr`，整型消息号自己转；`COPYDATASTRUCT` 一定要用
结构体声明，别手算偏移（64 位下 `lpData` 在偏移 16，不是 12）。

### 命令行（不写代码也能试）

```bat
:: 程序没在跑：启动并带上内容
runtime\AutoHotkey64.exe note.ahk --new "买牛奶"

:: 程序已经在跑：新起的那次会自动把文字转成 WM_COPYDATA 发过去
runtime\AutoHotkey64.exe note.ahk --new "买牛奶"
```

`--new` 后面不带文字就是新建空便签；`--list` 是打开列表。
第二次启动时程序发现自己不是唯一实例，会把参数转给正在跑的那个进程。

---

## 5. 协议细节

### 5.1 消息号

| 消息 | 值 | wParam | lParam | 返回值 |
|---|---|---|---|---|
| `WM_QN_WAKE` 全部显示 | `0x8001` | 任意 | 任意 | 1 |
| `WM_QN_NEW` 新建空便签 | `0x8010` | **必须 `0x514E`** | bit0=1 表示不抢焦点 | 1 受理 / 0 拒绝 |
| `WM_QN_LIST` 打开列表 | `0x8011` | **必须 `0x514E`** | 忽略 | 1 / 0 |
| `WM_QN_ACK` 回执（宿主→调用方） | `0x8014` | 新便签 id（0=失败） | 0 | — |
| `WM_COPYDATA` 带内容新建 | `0x004A` | 0 | `COPYDATASTRUCT*` | 1 / 0 |

`0x8000~0xBFFF` 是 `WM_APP` 区间，系统不解释这些值，跨进程发送不会和别人撞车。
**不要**换成 `WM_USER`（`0x0400~0x7FFF`）——那是"按窗口类"语义的，容易和控件内部消息混。

`wParam = 0x514E`（'NQ'）是魔数：只有它匹配才受理。这样别的程序乱广播的同号消息
不会在你这儿凭空建便签。

### 5.2 `WM_COPYDATA` 的载荷

`COPYDATASTRUCT`：

```
64 位：dwData(8) + cbData(4) + [4 字节对齐] + lpData(8) = 24 字节
32 位：dwData(4) + cbData(4) + lpData(4)              = 12 字节
```

* `dwData` 必须是 `0x514E3031`（'QN01'），否则拒收。
* `cbData` 是**字节数**（不含结尾 NUL），范围 1 ~ 65536。
* `lpData` 指向 UTF-8 字节。**别加 BOM**，加了会变成正文第一个字符。

内容有两种写法，宿主自己判断：

**（a）纯文本** —— 整段就是正文，最省事，适合计划任务、`echo` 出来的东西。
首尾的换行会被掐掉，中间的缩进和换行原样保留。

**（b）扁平 JSON** —— 第一个非空白字符是 `{` 就按 JSON 解析。
只支持**一层**对象（值都是字符串/数字/布尔），不做嵌套、不做数组。

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `text` | 字符串 | `""` | 正文。`\n` 会还原成换行 |
| `title` | 字符串 | `""` | 指定标题。**给了就上锁**，正文首行变化不再改它 |
| `color` | 字符串 | 配置里的默认色 | `yellow` / `pink` / `blue` / `green` / `purple` / `gray`，非法值回落默认 |
| `pin` | 0/1 | 0 | 1 = 这张便签置顶（窗口永远在最前） |
| `activate` | 0/1 | `[ipc] activate` | 1 = 弹到最前并聚焦；0 = 安静地建在角落 |
| `replyTo` | 整数 | 0 | 你的窗口句柄，建好后回执发到这儿 |
| `x` `y` `w` `h` | 整数 | 自动 | 同时给 `x` 和 `y` 才生效；超界会被拉回工作区 |
| `format` | 字符串 | `"text"` | v1 只认 `text`（原样落库）。其它值会记日志并按纯文本处理 |

> **不要**指望在 JSON 里传 `{"text":"..."}` 之外还带 HTML —— 正文一律按纯文本
> 转义后落库（`<b>` 就是四个字符 `< b >`，不会变成粗体）。

### 5.3 回执

在载荷里带上 `"replyTo": <你的窗口句柄>`，便签建好后宿主会：

```
PostMessageW(replyTo, 0x8014 /* WM_QN_ACK */, 新便签 id, 0)
```

* 建成功 → `wParam` = id（≥ 1）
* 建失败（比如 WebView2 起不来）→ `wParam` = 0
* 回执是**异步**的：`SendMessage` 早就返回了，别在返回后立刻去猜 id。
* 目标窗口已经销毁（`IsWindow` 假）就不发，不会报错。

`tools\ipc-send.py --ack` 演示了完整做法：建一个 message-only 窗口、抽消息循环、
收到 0x8014 就把 id 打出来。

> **AHK 用户注意**：宿主发回执用的是 `DllCall("PostMessageW", ...)`，不是 AHK 的
> `PostMessage`。原因是 AHK 的 `PostMessage` 靠 WinTitle 找窗口，而 WinTitle
> 搜索只覆盖**顶层窗口** —— 用 `HWND_MESSAGE` 建的"消息窗口"它根本找不到，
> 会静默失败。你自己发回执时同理，直接 `DllCall`。

### 5.4 受理之后的处理顺序

宿主是**串行**处理的：

```
入队 → [主线程] 取一条 → 写库 → 建 WebView2 窗口（200~500ms）→ 回执 → 取下一条
```

* 队列上限 **32 条**。满了直接返回 0（不会静默丢弃，调用方可以重试）。
* 载荷上限 **64 KB**。超了返回 0，`app.log` 里会有一行原因。
* 一次塞 20 条完全可以，但每条要 200~500ms 建窗，全部可见大约要 10 秒 —— 队列是
  按顺序排队出现的，不会一起弹出来。

---

## 6. 注意事项（重要，都是会让调用方误判的）

### 6.1 `SendMessage` 会阻塞，`PostMessage` 不会

* `SendMessage` 会一直等到**回调返回**（不是等便签建好），通常 1~5ms；如果宿主正
  忙于建另一张便签，最多等几百毫秒。不要在自己的 UI 线程里无脑循环发送。
* `PostMessage` 立即返回，但拿不到返回值（永远拿不到"受理/拒绝"），适合"发了就不管"。
  注意 `WM_COPYDATA` **不能**用 `PostMessage`：系统要求它的内存由发送方在同步调用
  期间保持有效，异步投递会永远发不到。

### 6.2 权限与会话边界（代码管不了，只能告诉你）

* **UIPI**：低完整性进程的消息进不了高完整性窗口。如果 QuickNote 用管理员身份运行，
  普通权限的脚本 `SendMessage` 会"调用成功但毫无反应"（返回 0，且日志里什么都没有）。
  两边保持同一权限级别即可。
* **会话隔离**：RDP 另一个会话、快速用户切换后的另一个登录用户，都收不到。
* **单实例**：同一时间只有一个进程在处理消息（第二个实例会转发参数后退出）。

### 6.3 目标不在跑

`FindWindow` 返回 0，就是"没在运行"。要不要替它启动由你决定：

```autohotkey
if !hwnd {
    Run '"' A_ScriptDir '\QuickNote.exe"'
    ; 等它起来再发（锚点约在 1 秒内出现）
    Loop 40 {
        Sleep 100
        if hwnd := DllCall("FindWindowW", "ptr", 0, "wstr", "QuickNoteAnchor", "ptr")
            break
    }
}
```

### 6.4 编码

一律 UTF-8。传 GBK 的话中文会变问号（`StrGet(..., "UTF-8")` 解不出来）。
Python 里用 `payload.encode("utf-8")`；AHK 里用 `StrPut(s, "UTF-8")`；
别用 `A_Clipboard`/文件默认编码中转。

### 6.5 内容不会被当成 Markdown 渲染

v1 的口径是"原样落进便签"：`**粗体**` 进去还是 `**粗体**`，`# 标题` 还是 `# 标题`。
这是有意的 —— 外部程序塞进来的多是日志、命令行输出，误渲染反而糟。
将来要支持渲染，宿主侧只需在 `App.NewNote` 里按 `format` 分支（把 `body_md` 交给页面
的 `MD.render`、`body_html` 留空，那条路页面侧已经通了），协议不用改。

### 6.6 不想让外部调用

`config.ini`：

```ini
[ipc]
enabled=0        ; 只保留"第二个实例唤醒"，其它一律拒绝（返回 0）
activate=1       ; 外部建的便签要不要抢焦点
```

改完重启生效。关掉之后 `--new` 也一并失效（它走的是同一条通道）。

---

## 7. 排障

| 现象 | 原因 / 怎么办 |
|---|---|
| `FindWindow` 返回 0 | 程序没启动；或跑在别的用户会话；或它被以更高权限启动 |
| 返回 0，日志里什么都没有 | 魔数不对（`wParam` 不是 0x514E / `dwData` 不是 'QN01'）；或 `[ipc] enabled=0` |
| 返回 0，日志写"载荷 N 字节" | 超过 64 KB。拆成几条发，或者写文件后在便签里引用路径 |
| 返回 0，日志写"队列满" | 短时间塞太多，等 1~2 秒重试 |
| 返回 1 但没看到便签 | 看 `app.log` 有没有 `IPC 执行失败`（WebView2 起不来会写这个）；也可能是 `activate=0` 建在了别的便签后面 |
| 一直等不到回执 | `replyTo` 不是有效窗口；或用 AHK 的 `PostMessage` 找不到 message-only 窗口（见 5.3） |
| 中文变问号 | 没按 UTF-8 编码 |
| 内容多了个乱码字符 | UTF-8 BOM 被当成了正文首字符，去掉 BOM |
| 便签标题没跟上正文 | 传了 `title` 会上锁，这是设计如此；不传就跟着首行变 |

排查入口：数据目录 `app.log`，所有受理/拒绝/失败都会留一行；`--selftest-ipc` 会把
整条链路跑一遍（见第 9 节）。

---

## 8. 加一个新消息号（扩展指南）

以"按 id 打开某张便签（`0x8012`）"为例，一共四步：

1. `lib/ipc.ahk` 加常量：`static WM_OPEN := 0x8012`
2. 写回调（照 `HandleList` 抄）：校验 `hwnd` / `wParam=MAGIC` / `Enabled` → `Ipc.Accept(...)`
3. `Install()` 里 `OnMessage(Ipc.WM_OPEN, IpcOnOpen)`，并在底部加顶层包装函数
   （**不要**把类静态方法直接传给 `OnMessage`，见 README 实现笔记 5）
4. `Run(job)` 的 `switch` 加一个 `case "open": App.OpenNote(job["id"])`

要带参数就放 `lParam`（整数）或走 `WM_COPYDATA` 的 JSON 字段；要回执就复用
`replyTo` + `Ipc.Reply`。最后补一条 `--selftest-ipc` 断言和本文档的表格。

---

## 9. 自检

```bat
:: 独立数据目录跑一遍，不碰你真正的便签库
runtime\AutoHotkey64.exe note.ahk --data-dir data\_ipctest --selftest-ipc
```

33 条断言，覆盖：空便签、纯文本（多行/中文/尖括号转义）、JSON（标题上锁/颜色/置顶/
不抢焦点）、三种拒绝（魔数错/dwData 错/超长）、回执 id 一致性、打开列表、`enabled=0`
关闸、以及收尾把测试便签删干净。

跑之前确认没有别的实例在跑（否则会走"转发参数并退出"那条路，自检根本不会执行）。
