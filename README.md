# QuickNote · 桌面便签

用 **AutoHotkey v2 + WebView2 + SQLite** 写的桌面便签。每张便签是一个独立的无边框小窗口，
可以半透明、可换色、可置顶、能贴在任何程序上面；正文支持富文本和 Markdown，实时落库。

```
双击 note.ahk  →  Ctrl+Alt+N 新建  →  Ctrl+Alt+L 看全部
```

| 一张便签 | 便签列表 |
|---|---|
| ![便签](assets/shot-note.png) | ![列表](assets/shot-list.png) |

> 上面两张是程序真实渲染出来的截图（`tools/probe-shot.ahk` 用 WebView2 的 CapturePreview 导出），
> 不是设计稿。便签窗口在透明模式下还能透出背后的桌面，截图里看不出来。

---

## 快速开始

### 直接运行（需要 AutoHotkey v2）

1. 装 [AutoHotkey v2](https://www.autohotkey.com/)（或者直接用项目自带的 `runtime\AutoHotkey64.exe`）
2. 双击 `note.ahk`
3. 托盘出现一个黄色便签图标，屏幕上会弹出第一张便签

用自带运行时启动：

```bat
runtime\AutoHotkey64.exe note.ahk
```

### 编译版

`dist\QuickNote.exe` 是编译好的单文件程序（仍需机器上有 WebView2 Runtime，Win10 1803+ 基本都自带）。
双击即用，不用装 AutoHotkey。

---

## 能做什么

| 能力 | 说明 |
|---|---|
| 多张便签 | 每张是独立顶层窗口，可单独拖动、缩放、置顶、收起、删除 |
| 无边框 + 圆角 | 拖动用系统移动循环（`-webkit-app-region`），缩放用右下角手柄 |
| 半透明 | 卡片能透出桌面（窗口用 `WS_EX_LAYERED`+`WS_EX_NOREDIRECTIONBITMAP`，页面用 rgba 自绘） |
| 六种颜色 | 黄 / 粉 / 蓝 / 绿 / 紫 / 灰，随时切换，颜色存在库里 |
| 富文本 | 加粗、斜体、删除线、标题、列表、待办勾选、行内代码、引用 |
| Markdown | `Ctrl+M` 在所见即所得和源码之间切换，两边双向转换 |
| 自动保存 | 停止输入 400ms 自动落库，关窗/收起/失焦时补一次 |
| 位置记忆 | 关掉重开，位置、尺寸、颜色、置顶状态都还原 |
| 列表与搜索 | `Ctrl+Alt+L` 打开总览，按关键字全文搜索（含已收起的便签） |
| 托盘常驻 | 全局热键随时新建/呼出，关掉便签窗口不退出进程 |

### 快捷键

便签窗口内：

| 按键 | 作用 |
|---|---|
| `Ctrl+B` / `Ctrl+I` / `Ctrl+U` | 加粗 / 斜体 / 下划线 |
| `Ctrl+S` | 立即保存 |
| `Ctrl+M` | 切换 Markdown 源码 |
| `Esc` | 失焦、保存 |

全局：

| 按键 | 作用 |
|---|---|
| `Ctrl+Alt+N` | 新建便签 |
| `Ctrl+Alt+L` | 打开便签列表 |
| `Ctrl+Alt+H` | 全部收起 / 再按全部显示 |

### 便签上的按钮

右上角四个小图标（鼠标移上去才显示）：

- `M↓` 切换 Markdown 源码
- 📌 置顶（置顶后窗口始终在最前）
- `⋯` 右键菜单：新建、置顶、换色、复制全文、列表、收起、删除
- `×` 删除这张便签（不可撤销）

右下角有缩放手柄，拖它调整大小。

列表窗口右上角是「新建」和一个关闭按钮（也可以按 Esc）。

---

## 配置

首次运行会在数据目录生成 `config.ini`（带中文注释）。改完重启生效。

```ini
[appearance]
transparent=1        ; 1=半透明卡片  0=不透明实色
fontSize=15          ; 正文字号（像素）
drag=native          ; native=系统拖动（默认）  manual=AHK 自己跟鼠标

[window]
width=300            ; 新建便签的默认宽
height=280
color=yellow         ; yellow/pink/blue/green/purple/gray

[hotkey]
new=^!n              ; 留空表示不注册
list=^!l
toggle=^!h

[debug]
devtools=0           ; 1=允许 F12 打开开发者工具
```

托盘菜单里也有「透明外观」开关，会直接改 `transparent` 并重建所有窗口。

---

## 数据存在哪

默认：`%APPDATA%\QuickNote\`

```
%APPDATA%\QuickNote\
  notes.db        便签内容（SQLite，WAL 模式）
  config.ini      配置
  app.log         运行日志（出问题先看这个）
  webview2\       所有 WebView2 共用的 user data folder
```

**便携模式**：在程序目录放一个 `portable.txt`，数据就改存到 `程序目录\data\`，可以整个拷走。

备份就是拷 `notes.db`（记得先退出程序，或者连 `notes.db-wal` 一起拷）。

---

## 透明外观：如果显示不正常

半透明是这套技术栈里唯一有不确定性的地方。如果便签窗口出现**黑底、全黑、或者内容看不见**：

1. 托盘菜单 → 取消「透明外观」（或者把 `config.ini` 里 `transparent` 改成 `0`）
2. 程序会重建成不透明实色窗口，其他功能不受影响

原因写在下面「实现笔记」里：WebView2 的背景透明依赖 `DefaultBackgroundColor` 的 alpha=0
加上分层窗口，个别显卡驱动/远程桌面会话下合成会有差异。默认按透明启动，是因为它在绝大多数
本机环境下效果更好。

---

## 已知限制

- **每张便签约占 45~50MB 内存**（一个 WebView2 渲染进程），10 张 ≈ 0.8GB。浏览器进程组
  （约 300MB）是所有便签共享的，只付一次。
- **收起的便签仍然占内存**：收起只是隐藏窗口，渲染进程还在。想彻底释放就删除它。
- **透明窗口没有系统阴影**：阴影只能画在窗口内部（往外画会被窗口边界裁掉），所以用的是内阴影 + 描边。
- **Win10 上四角可能露出方形底色**：DWM 圆角是 Win11 才有的，Win10 走 CSS 圆角。
- **不支持粘贴图片**：可以放图片链接 / Markdown 图片语法，但没有把剪贴板位图落盘的能力。
- **搜索是 `LIKE` 匹配**：几千张便签以内都很快；再大就需要 FTS5 索引。
- **单显示器缩放切换**：开了 PerMonitorV2，但跨不同缩放的屏幕拖动时可能有轻微模糊，松开鼠标后恢复。

---

## 目录结构

```
wv2-notes/
├─ note.ahk              主程序：单实例、托盘、热键、启动装载
├─ lib/
│  ├─ sqlite.ahk         SQLite 封装（优先用系统 winsqlite3.dll）
│  ├─ store.ahk          数据访问层（表结构、CRUD、搜索）
│  ├─ note-window.ahk    一张便签 = 一个 Gui + 一个 WebView2
│  ├─ list-window.ahk    列表面板（单例）
│  ├─ win.ahk            窗口外观（透明/圆角/工作区/级联落点）
│  ├─ json.ahk           极简 JSON（只处理扁平字段）
│  ├─ WebView2/          WebView2 AHK 绑定（第三方，v2.0.5）
│  └─ WebView2Loader.dll
├─ ui/
│  ├─ note.html/css/js   便签页面
│  ├─ list.html/css/js   列表页面
│  └─ md.js              Markdown ⇄ HTML（纯函数，可单测）
├─ assets/note.ico       图标
├─ runtime/              自带的 AutoHotkey 运行时
├─ tools/                冒烟测试、端到端测试、图标生成
├─ tests/md.test.js      Markdown 单测
└─ docs/
```

---

## 开发与测试

```bash
# Markdown 渲染 / 纯文本提取 / 标题提取
node tests/md.test.js

# 单窗口冒烟（真 WebView2，会写 data\_win.log）
runtime\AutoHotkey64.exe tools\probe-window.ahk

# 端到端：输入→防抖→落库→切模式→改色→几何→重开（26 项断言）
runtime\AutoHotkey64.exe tools\e2e.ahk

# 列表面板：渲染/搜索/回调（11 项断言）
runtime\AutoHotkey64.exe tools\probe-list.ahk

# 数据层
runtime\AutoHotkey64.exe tools\probe-store.ahk
```

测试脚本都用 `data\_*.db`，不会碰你的真实便签。

重新生成图标：

```powershell
pwsh -File tools/make-icon.ps1
```

脚本会输出 `assets/note-16…256.png`；重新打包成 ICO 需要把这几个尺寸按 PNG-in-ICO 结构
重新拼一次（图标只在改视觉时才需要重做，平时不用管）。

---

## 实现笔记（维护前值得知道的坑）

这些都是实际调试出来的，改代码时容易再踩：

1. **窗口必须先显示，再建 WebView2 controller。** 在隐藏窗口上创建，页面能加载、
   `CapturePreview` 也有内容，但视觉树不会挂到窗口上 —— 屏幕上就是一个纯白空窗。

2. **`DefaultBackgroundColor` 的 alpha 只接受 0 或 255。** 想要"70% 白"这种中间值直接
   `E_INVALIDARG`。所以半透明只能是 alpha=0 + 页面自己用 rgba 画底色。

3. **`DllCall("sqlite3.dll\xxx")` 在 DLL 没按路径加载时会直接访问违例**，进程静默退出，
   连日志都来不及写。必须先 `LoadLibraryW` 绝对路径。同理，系统自带的 `winsqlite3.dll`
   只要显式加载就完全可用（3.43.2，零分发）。

4. **AHK 变量名不区分大小写。** `app := ctx.appearance` 会把全局类名 `App` 遮蔽掉，
   之后 `App.Log(...)` 报的是 "This value of type Object has no method named Log"。

5. **不要把「类静态方法引用」直接传给 `SetTimer` / `OnError` / COM 事件绑定。**
   会拿到不可调用的东西，轻则 "Invalid callback function"，重则沉默退出。
   统一用顶层包装函数（`NoteBootTick()` 之类）。

6. **对象属性当函数调用会多传一个 `this`。** `hooks.onOpen(id)` 实际是 `onOpen(hooks, id)`，
   所以回调表用 `Map` + `h["onOpen"](id)`。

7. **`Gui.Show` 的宽高不能是负数。** 无显示器/远程会话下 `MonitorGetWorkArea` 可能全 0，
   `Min(520, wa.w - 60)` 就变成负数，`Show` 直接抛异常。尺寸一定要 `Max(下限, Min(上限, x))`。

8. **AHK 的续段字符串（`"(` ... `)"`）对缩进极挑剔**，SQL 一律逐行拼接，别用续段。

9. **隐藏窗口会被 Chromium 节流**：后台便签的 `setTimeout` 会变慢。所以自动保存的
   定时器在页面里，但"收起前/关窗前"由 AHK 侧主动补一枪（`blur` + `Hide()` 里的 `SaveGeometryNow`）。

10. **关窗口 ≠ 释放。** `Gui.Destroy()` 不会回收 WebView2，必须先 `wvc.Close()`，
    否则每开一次就多攒一个 `msedgewebview2.exe`。

11. **单 UI 线程是共享的。** 任何一个窗口的消息回调抛未捕获异常，AHK 会弹模态框，
    所有便签一起冻住。所以消息分发整个包在 `try` 里，异常只写日志（`OnError` 返回 1 不弹框）。
