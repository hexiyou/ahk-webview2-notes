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

### 开发调试：用 run.bat（推荐先走这条）

双击 `run.bat`。它用项目自带的运行时跑 `note.ahk` 脚本版，并且：

- 语法错误、运行时错误会**直接打在窗口里**（编译版看不到，一崩就没了）
- 改完 `.ahk` 或 `ui\` 下的文件，关掉窗口重开就生效，不用重新编译
- 注意：关掉那个命令行窗口 = 退出程序

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

**编译版出问题时的排查顺序**：先看 `dist\crash.log`（启动失败会写在这里，同时弹框提示），
再看数据目录里的 `app.log`（托盘菜单「打开日志」可以直接打开）。还是定位不了，就用
`run.bat` 跑同一份脚本——同样的错误在命令行里会带文件行号。

---

## 能做什么

| 能力 | 说明 |
|---|---|
| 多张便签 | 每张是独立顶层窗口，可单独拖动、缩放、置顶、收起、删除 |
| 最大化 | 双击标题栏（或右键菜单「最大化窗口」）铺满当前显示器的工作区，再双击还原 |
| 无边框 + 圆角 | 拖动用系统移动循环（`-webkit-app-region`），缩放用右下角手柄 |
| 半透明 | 卡片能透出桌面（窗口用 `WS_EX_LAYERED`+`WS_EX_NOREDIRECTIONBITMAP`，页面用 rgba 自绘） |
| 六种颜色 | 黄 / 粉 / 蓝 / 绿 / 紫 / 灰，随时切换，颜色存在库里 |
| 富文本 | 加粗、斜体、删除线、标题、列表、待办勾选、行内代码、引用、链接、代码块、分割线 |
| 代码着色 | 代码块自动上色（本地 highlight.js，离线可用）；右键「代码语言」可手动指定，导出 HTML 也带着颜色 |
| 两套右键菜单 | 正文里是**编辑菜单**（撤销/剪切/复制/粘贴/全选/清除格式），标题栏和其它地方是**便签菜单**（置顶/颜色/导出/删除…） |
| 插入图片 | 拖文件进来 / `Ctrl+V` 粘截图 / 右键「插入图片…」；图片存 `data\images`，正文只留链接 |
| 看图 | 正文里的图按 180px 高缩略显示，点一下铺满窗口看原图（再点或 `Esc` 关） |
| 导出 | 右键「导出」→ TXT / Markdown / HTML / RTF；HTML 会把图片内嵌成 data URI，单文件即可分享 |
| 设置面板 | 托盘「设置…」或列表空白右键：启动行为、外观、新建便签的默认颜色、三个全局热键都能改 |
| 自定义标题 | 列表和便签的右键菜单都有「重命名…」；不手动改就按正文第一行自动取 |
| 重命名不被盖 | 便签/列表置顶时，重命名输入框也跟着置顶（AHK 自带 InputBox 做不到，见笔记 48） |
| Markdown | `Ctrl+M` 在所见即所得和源码之间切换，两边双向转换 |
| 字号缩放 | 编辑区 `Ctrl+滚轮` 实时放大 / 缩小（10~32px），所有便签一起变并记住 |
| 自动保存 | 停止输入 400ms 自动落库，关窗/收起/失焦时补一次 |
| 位置记忆 | 关掉重开，位置、尺寸、颜色、置顶状态都还原 |
| 列表与搜索 | `Ctrl+Alt+L` 打开总览，按关键字全文搜索（含已收起的便签）；列表自己也能置顶（右上角图钉） |
| 右键菜单 | 便签和列表都支持，用的是系统原生菜单（能超出小窗口边界） |
| 托盘常驻 | 全局热键随时新建/呼出，关掉便签窗口不退出进程 |

### 快捷键

便签窗口内：

| 按键 | 作用 |
|---|---|
| `Ctrl+B` / `Ctrl+I` / `Ctrl+U` | 加粗 / 斜体 / 下划线 |
| `Ctrl+S` | 立即保存，状态栏回「✓ 已保存 时:分:秒」 |
| `Ctrl+M` | 切换 Markdown 源码 |
| `Ctrl+滚轮` | 放大 / 缩小正文字号（也可用右键菜单的「字号」） |
| `Ctrl+V` | 粘贴截图 / 图片（拖文件到便签里同样可以） |
| 双击标题栏 | 最大化 / 还原窗口（铺满当前显示器的工作区，不遮任务栏） |
| `Enter`（代码块里） | 正常换行，可以一行一行往下敲 |
| `Enter`（空行上）/ `Ctrl+Enter` / `↓`（块尾） | 跳出代码块 |
| `Tab` / `Shift+Tab`（代码块里） | 缩进 / 退掉两格 |
| `Esc` | 代码块里 = 跳出；看图时 = 关闭大图；其它情况 = 失焦并保存 |

全局：

| 按键 | 作用 |
|---|---|
| `Ctrl+Alt+N` | 新建便签 |
| `Ctrl+Alt+L` | 打开便签列表 |
| `Ctrl+Alt+H` | 全部收起 / 再按全部显示 |

列表窗口内：

| 按键 | 作用 |
|---|---|
| `Ctrl+N` | 新建便签（宿主级条件热键，页面里那套也保留了作兜底） |
| `Enter` | 打开第一条（搜索框里按） |
| `Esc` | 清空搜索词；再按一次关窗 |

### 便签上的按钮

右上角四个小图标（鼠标移上去才显示）：

- `M↓` 切换 Markdown 源码
- 📌 置顶（置顶后窗口始终在最前）
- `⋯` 更多菜单，和右键菜单是同一个
- `×` **收起**这张便签（不是删除；删除走右键菜单或列表窗口，避免误触）

右下角有缩放手柄，拖它调整大小。

### 右键菜单

**便签窗口的右键菜单分两套**，按你点在哪儿决定 —— 在正文里弹出"删除这张便签"
是最容易误点的组合，所以必须分开：

- 点**正文**（编辑区）→ 编辑菜单
- 点**标题栏 / 工具栏 / 状态栏 / 缩放手柄**，或点 `⋯` → 便签菜单

**编辑菜单**（正文里右键）：

```
撤销        Ctrl+Z
重做        Ctrl+Y
────────────
剪切        Ctrl+X
复制        Ctrl+C
粘贴        Ctrl+V
删除
────────────
全选        Ctrl+A
清除格式
────────────
插入代码块
代码语言 ›   自动识别 / 纯文本 / JS / TS / Python / HTML / CSS / JSON / Bash …
             （只有光标在代码块里时才出现，当前语言打勾）
插入图片…
────────────
保存        Ctrl+S
```

**便签菜单**（标题栏或 `⋯`）：

```
新建便签
便签列表…
────────────
最大化窗口 / 还原窗口大小   双击标题栏（菜单项会跟着状态变）
置顶 / 取消置顶
颜色  ›        黄 / 粉 / 蓝 / 绿 / 紫 / 灰（当前色打勾）
────────────
切换 Markdown 源码（源码模式下变成"切换到富文本编辑"）
复制全文
保存            Ctrl+S
插入图片…
字号  ›        放大 / 缩小 / 恢复默认
导出  ›        TXT / Markdown / HTML / RTF
────────────
收起这张
删除这张…      带二次确认
```

**列表窗口**（右上角是「新建 / 📌置顶 / ⋯ / 关闭」，Esc 也能关）：

- 右上角的 📌 切换**列表窗口自己的置顶**（亮起来 = 置顶中）。这是窗口偏好，
  存在 `config.ini` 的 `[window] listTopmost`，下次打开还是置顶的
- 在某一行的任意位置右键 → `打开 / 重命名… / 置顶·取消置顶 / 颜色› / 导出› / 收起这张 / 删除…`
- 在空白处或标题栏右键（也可以点右上角 `⋯`）→ `新建便签 / 刷新列表 / 全部显示 / 全部收起 / 窗口置顶 / 设置… / 打开数据目录`

注意两种"置顶"不是一回事：**条目的置顶**是那张便签的字段（存库里，便签窗口在最前），
**窗口置顶**是这个列表窗口自己的状态（存 config.ini）。

菜单是系统原生的（`Menu.Show`），不是页面自己画的：便签窗口最小能缩到 180×140，
页面内的菜单根本放不下九项，只有原生菜单能超出窗口边界。代价是菜单打开期间
主线程被占着（原生菜单的固有行为），关掉就恢复。

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
color=yellow         ; 新建便签的默认颜色：yellow/pink/blue/green/purple/gray
listTopmost=0        ; 1=列表窗口一直置顶（列表右上角的图钉也会改这里）

[hotkey]
new=^!n              ; 留空表示不注册
list=^!l
toggle=^!h

[app]
showAllOnStart=0     ; 1=启动时把所有便签都显示出来
openListOnStart=0    ; 1=启动时打开便签列表

[debug]
devtools=0           ; 1=允许 F12 打开开发者工具
```

### 设置面板

托盘菜单 →「设置…」，或者列表窗口空白处右键 →「设置…」。能改的东西：

| 分组 | 项 |
|---|---|
| 启动 | 启动时显示所有便签 / 启动时打开列表 |
| 外观 | 半透明开关、正文字号（10~32）、新建便签的颜色（六个色块） |
| 快捷键 | 新建便签 / 打开列表 / 显示收起全部 —— 点进输入框**直接按组合键**即可录制，× 清空表示不注册 |
| 其他 | 打开数据目录、打开日志 |

保存后字号、默认颜色和热键**立即生效**（热键会先校验：写法非法或被别的程序占了会当场报错，
且原来的热键不会被弄丢）；透明开关会重建所有窗口。删掉 `config.ini` 再启动等于恢复出厂。

颜色色块是按宿主的 `NoteWindow.Colors()` 现画的，页面里不另存一份表 —— 以后加颜色只改
AHK 那一处，设置面板自动多一个色块。

托盘菜单里也有「透明外观」开关，和设置面板里的是同一个值。

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

透明这条路有两个必踩的坑，都已经修好并写进了「实现笔记」，这里只说怎么回退：

如果便签窗口出现**黑底、全黑、或者内容看不见**：

1. 托盘菜单 → 取消「透明外观」（或者把 `config.ini` 里 `transparent` 改成 `0`）
2. 程序会重建成不透明实色窗口，其他功能不受影响

默认按透明启动，是因为它在绝大多数本机环境下效果更好。个别显卡驱动 / 远程桌面会话下
WebView2 的合成确实会有差异，这时才需要退回不透明。

---

## 已知限制

- **每张便签约占 45~50MB 内存**（一个 WebView2 渲染进程），10 张 ≈ 0.8GB。浏览器进程组
  （约 300MB）是所有便签共享的，只付一次。
- **收起的便签仍然占内存**：收起只是隐藏窗口，渲染进程还在。想彻底释放就删除它。
- **透明窗口没有系统阴影**：阴影只能画在窗口内部（往外画会被窗口边界裁掉），所以用的是内阴影 + 描边。
- **Win10 上四角可能露出方形底色**：DWM 圆角是 Win11 才有的，Win10 走 CSS 圆角。
- **纯文本粘贴照旧走浏览器默认**：只有带图片的粘贴会被接管，粘文字/表格还是 Chromium 自己的行为（表格会被压成纯文本）。
- **粘贴菜单项靠代按快捷键**：正文右键的「粘贴」会让宿主补发一次真实的 `Ctrl+V`（Chromium 不允许网页自己读剪贴板），所以那一瞬间窗口必须在前台。
- **代码块正在编辑时不上色**：为了不跳光标，正在打字的那个块保持素色，光标一移开立刻上色。
- **搜索是 `LIKE` 匹配**：几千张便签以内都很快；再大就需要 FTS5 索引。
- **单显示器缩放切换**：开了 PerMonitorV2，但跨不同缩放的屏幕拖动时可能有轻微模糊，松开鼠标后恢复。
- **打开右键菜单时窗口会短暂"卡住"**：原生菜单是同步的，菜单开着期间主线程不处理其他消息
  （其他便签也不响应），关掉菜单立刻恢复。这是 `Menu.Show()` 的固有行为。

---

## 目录结构

```
wv2-notes/
├─ note.ahk              主程序：单实例、托盘、热键、启动装载
├─ run.bat               ★ 开发调试入口：脚本模式跑，错误直接打在窗口里
├─ lib/
│  ├─ sqlite.ahk         SQLite 封装（优先用系统 winsqlite3.dll）
│  ├─ store.ahk          数据访问层（表结构、CRUD、搜索）
│  ├─ note-window.ahk    一张便签 = 一个 Gui + 一个 WebView2（含两套右键菜单）
│  ├─ list-window.ahk    列表面板（单例）
│  ├─ settings-window.ahk 设置面板（单例 WebView2，ui\settings.*）
│  ├─ export.ahk         单张导出：TXT / MD / HTML / RTF
│  ├─ win.ahk            窗口外观（透明/圆角/工作区/级联落点）
│  ├─ json.ahk           极简 JSON（只处理扁平字段；大字段走线性扫描，别用正则）
│  ├─ WebView2/          WebView2 AHK 绑定（第三方，v2.0.5）
│  └─ WebView2Loader.dll
├─ ui/
│  ├─ note.html/css/js   便签页面
│  ├─ list.html/css/js   列表页面
│  ├─ settings.html/css/js 设置面板页面
│  ├─ md.js              Markdown ⇄ HTML（纯函数，可单测）
│  ├─ code-hl.js         代码着色（管"什么时候可以重画"，见实现笔记 40）
│  └─ vendor/            highlight.js 11.9.0 + github 主题（BSD-3-Clause，本地不放 CDN）
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

# 端到端：输入→防抖→落库→切模式→改色→几何→重开（27 项断言）
runtime\AutoHotkey64.exe tools\e2e.ahk

# 列表面板：渲染/搜索/回调（11 项断言）
runtime\AutoHotkey64.exe tools\probe-list.ahk

# 列表顺序稳定性：编辑/打开/搜索都不许改变顺序（10 项断言，很快）
runtime\AutoHotkey64.exe tools\probe-sort.ahk

# 回归"点完新建就拖不动"：真鼠标点「新建」再拖两个窗口（8 项断言，需先启动 run.bat）
runtime\AutoHotkey64.exe tools\probe-newbug.ahk

# 菜单：回调参数个数、闭包、菜单项是否都包了包装器、两套右键菜单的两端是否对得上（77 项断言，很快）
runtime\AutoHotkey64.exe tools\probe-menu.ahk

# JSON 取值：大字段（1.6MB / 4MB）不许崩、转义引号 / 同名键 / 缩进边界（26 项断言，很快）
runtime\AutoHotkey64.exe tools\probe-json.ahk

# 程序级自检：收起全部→全部显示，看窗口是不是真回到屏幕上
runtime\AutoHotkey64.exe note.ahk --selftest-showall

# 程序级自检：把菜单弹出来（会一直开着，Ctrl+C 或关掉即可）
runtime\AutoHotkey64.exe note.ahk --selftest-menu

# 程序级自检：Ctrl+N 链路（热键注册 + 条件判定 + 延迟建窗不卡死）
runtime\AutoHotkey64.exe note.ahk --selftest-keys

# 程序级自检：延迟入口能不能真的把列表打开（回归"点菜单没反应"）
runtime\AutoHotkey64.exe note.ahk --selftest-list

# 程序级自检：Ctrl+滚轮 字号（合成 WheelEvent，验放大/上下限/落盘）
runtime\AutoHotkey64.exe note.ahk --selftest-font

# 程序级自检：富文本工具条 / Markdown 往返 / 图片插入（含源码模式）
runtime\AutoHotkey64.exe note.ahk --selftest-rich

# 程序级自检：粘贴链路 / 图片限高与看大图 / 右上角 X 只收起不删除
runtime\AutoHotkey64.exe note.ahk --selftest-note

# 程序级自检：大图粘贴(1.9MB base64) / Ctrl+S 回执 / 代码块多行输入与出路 /
#              代码着色 / 编辑菜单命令 / 双击标题栏最大化与还原
runtime\AutoHotkey64.exe note.ahk --selftest-edit

# 程序级自检：四种导出格式（TXT / MD / HTML / RTF）
runtime\AutoHotkey64.exe note.ahk --selftest-export

# 程序级自检：设置面板（开窗 + 读值 + 颜色色块 + 保存生效 + 非法热键拦截）
runtime\AutoHotkey64.exe note.ahk --selftest-settings

# 程序级自检：重命名框（置顶/普通两版 + 置顶便签的端到端）
runtime\AutoHotkey64.exe note.ahk --selftest-dialog

# 给 README 生成设置面板截图（写到 assets\shot-settings.png）
runtime\AutoHotkey64.exe note.ahk --shot-settings

# 给 README 生成列表窗口截图（写到 assets\shot-list.png）
runtime\AutoHotkey64.exe tools\shot-list.ahk

# 给 README 生成"带代码着色"的便签截图（写到 assets\shot-code.png）
runtime\AutoHotkey64.exe note.ahk --shot-code

# 给 README 生成"最大化之后"的截图（写到 assets\shot-max.png）
runtime\AutoHotkey64.exe note.ahk --shot-max

# 数据层
runtime\AutoHotkey64.exe tools\probe-store.ahk

# 分层窗口命中测试：不改代码也能确认"看得见的东西点得到"（10 项断言）
runtime\AutoHotkey64.exe tools\probe-hit.ahk

# 对**正在运行**的程序做交互验收：真鼠标拖顶栏 + 点按钮改库（需先启动 run.bat）
runtime\AutoHotkey64.exe tools\probe-live.ahk
runtime\AutoHotkey64.exe tools\probe-click.ahk

# 半透明是否真的生效：压在黑底/桌面各量一次像素
runtime\AutoHotkey64.exe tools\probe-blend.ahk

# 抓桌面截图（PowerShell 的 Add-Type 被安全策略挡了，这里用 GDI 自己写 BMP）
runtime\AutoHotkey64.exe tools\shot-screen.ahk out.bmp 0 0 800 600
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

12. **★ 分层窗口只加 `WS_EX_LAYERED` 不设 alpha，鼠标会全部穿透。**
    `WS_EX_LAYERED` 的命中测试按整窗 alpha 判定，而新建窗口的 alpha 默认是 **0**。
    只加样式不调 `SetLayeredWindowAttributes` 的后果是：
    **画面看得见**（WebView2 的合成层由 DWM 直接合成，不走窗口表面）、**鼠标全穿过去**
    ——点击落到桌面上，表现为"便签显示正常，一点就点到别的软件上"。
    修法就一句 `SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)`：255 只是把命中
    测试恢复成正常，**不会**让窗口变不透明（窗口自己没有表面可画，画面仍全来自 WebView2）。
    验证脚本 `tools\probe-hit.ahk`：不设 alpha 时 `WindowFromPoint` 返回 0，设完返回窗口句柄。

13. **★ `html` 元素千万别涂底色。** 透明模式下 `body.transparent { background: transparent }`
    只清掉 `body`，如果 `html` 也被 `html, body { background: rgb(...) }` 涂了一层，
    那层铺满整个视口，把窗口盖成一块实色——卡片永远"不透明"、窗口是硬边矩形。
    表现很迷惑：样式看着没错，`DefaultBackgroundColor` 也设了 0，就是不透。
    量像素才能发现：卡片中心恒等于便签色本身（`0xFFF3B0`），换背景不变。
    正确写法：`html { background: transparent }`，兜底底色只给 `body`。

14. **`-webkit-app-region: drag` + `IsNonClientRegionSupportEnabled` 在真机上拖不动。**
    WebView2 Runtime 是 156（够新），但列表窗口（`-Caption +Resize`）和透明便签窗口
    （分层）都实测"能点、拖不走"。所以拖动改成自己做：
    顶栏给 `app-region: no-drag`（否则浏览器把 `mousedown` 吃掉，页面收不到），
    页面按下发 `drag-start` → AHK 侧 `ReleaseCapture()` + `PostMessage(WM_NCLBUTTONDOWN,
    HTCAPTION)` 进系统移动循环。这条路任何窗口样式都能用，还白送贴边吸附。
    `config.ini` 里 `drag=native` 仍保留原生路线，只作排查用。

15. **编译版出错是"静默死亡"。** 没有控制台、没有 AHK 的语法错误框，双击后一闪就没了。
    三条兜底：启动阶段 `try App.Main()` 包住（失败弹框 + 写 `crash.log`）；
    `note.ahk --check` 只做加载检查、立刻退出，`tools\build.ps1` 编译前先跑一遍；
    打包后自动冒烟测试（便携模式启动 exe，6 秒后查进程存活 + 日志里有 `Boot 返回` + 没有
    `crash.log`）。日常调试用 `run.bat` 跑脚本版。

16. **测试时的两个环境坑（不是程序问题）**
    - Git Bash 会把 `/ErrorStdOut` 当成路径改写成 `C:\Program Files\Git\ErrorStdOut`，
      脚本莫名其妙以退出码 2 结束。加 `MSYS2_ARG_CONV_EXCL='*'`。
    - 本机沙箱里 `SendInput` 发**键盘**会卡死（鼠标 `Click`/`MouseMove` 正常），
      所以自动化验收别用键盘注入改数据，要验证点击就点一个会改库的按钮
      （`tools\probe-click.ahk` 点顶栏置顶按钮，看 `pinned` 有没有翻转）。

17. **★★ 菜单回调会被传 3 个参数，回调声明得少就全部失效。**
    AHK v2 调用菜单项时传的是 `(项目名, 序号, 菜单对象)`，参数个数在调用点严格检查。
    写成 `m.Add("置顶", ObjBindMethod(this, "TogglePin"))`（零参）会抛
    `Too many parameters passed to function.`，界面表现是**菜单弹得出来、点哪项都没反应**；
    更坑的是日志把行号记在 `m.Show()` 那行，看着像 `Show` 有问题。
    - 统一用 `NoteWindow.MB(fn)` / `ListWindow.Cb(fn)`（就是 `(*) => fn.Call()`）包一层。
    - `tools\probe-menu.ahk` 里有源码级 lint：含 `ObjBindMethod` 的 `Add(...)` 行必须同时
      出现 `MB(`，含 `ListMenu` 的必须出现 `Cb(`，新增菜单项忘了包会直接 FAIL。

18. **★ 闭包捕获的是变量，不是值。** 在 `for name, hex in Colors()` 循环体里直接写
    `m.Add(label, (*) => this.DoColor(name))`，所有菜单项会一起指向循环结束后的最后一个颜色。
    必须经由函数参数转一手：`ListMenuColor(id, name)` 返回 `() => ListWindow.Call(..., name)`，
    每次调用产生独立的局部变量。`probe-menu.ahk` 有两条断言专盯这个。

19. **★ "全部显示"必须遍历 `All()`，不能是 `Visible()`。** `Visible()` 只返回 `hidden=0` 的，
    而收起的便签恰好都是 `hidden=1` —— 用 `Visible()` 就是"一收起再也点不出来，点菜单毫无反应"。
    另外重新建窗时也要把 `hidden` 复位（`App.OpenNote` 里做），否则窗口画出来了、
    库里还标着已收起，下次启动又不见了。这两条都能用 `note.ahk --selftest-showall` 验证。

20. **菜单和消息框都要从 COM 回调里退出来再弹。** `Menu.Show()` 和 `MsgBox()` 都会阻塞线程，
    直接在 `WebMessageReceived` 处理函数里调，等于卡住 WebView2 的同步调用。
    所以消息分发里只做 `SetTimer(ObjBindMethod(this, "ShowMenu"), -10)`，真正弹菜单放到下一个
    线程去跑。副作用是菜单打开期间主线程被占着（原生菜单固有行为），关掉即恢复。

21. **★★ 绝不能在 `WebMessageReceived` 回调里建窗/关窗。** 这是本项目最凶的一个坑：
    建窗要 `CreateControllerAsync(...).await()`，而在 COM 事件回调里 **await 永远等不到完成**，
    整个线程就永久挂在那一句上。症状极具迷惑性——**定时器还在跑、按钮还能点、便签还能打字，
    但页面发来的消息全都进不来了**，于是"拖动"（靠页面发 `drag-start`）先失效：
    点一下列表窗口的「新建」，之后所有窗口都拖不动，但程序"没卡死"。
    日志里能一眼看出：`NewNote 被调用` 之后，再也没有 `建窗完成`。
    结论：回调里只读参数，动作一律 `SetTimer(..., -10)` 丢到独立线程去执行；
    拖动这种必须即时的才同步处理（`StartMove` 本身不阻塞）。同理，托盘菜单、条件热键、
    `OnMessage` 里调用建窗/关窗也全部走 `NoteDeferNew()` / `NoteDeferList()` 这一层。

22. **★ 列表顺序不能用 `updated_at` 排。** 打开、编辑、改显示状态都会刷新 `updated_at`，
    于是"点开哪张、哪张就窜到最前面"，看着就是"点一下就乱跳"。现在固定成
    `pinned DESC, created_at DESC, id DESC`（置顶 → 新建的在前 → id 兜底），
    编辑再多也不会动。`tools\probe-sort.ahk` 里 10 条断言盯着这件事（含"置顶允许插队"）。

23. **★ 列表窗口里的 `Ctrl+N` 页面根本收不到。** WebView2 默认把 `Ctrl+N` 当"新建窗口"
    这类浏览器快捷键吃掉，所以页面写 `keydown` 处理器也没用（表现：按了毫无反应）。
    两道保险：① `AreBrowserAcceleratorKeysEnabled := 0`（官方文档明确说只关浏览器功能键，
    不影响 `Ctrl+C/V/X/A/Z` 和 Home/End 这类编辑键）；② 用条件热键直接接管
    `HotIf(ListHotkeyCond)` + `Hotkey("^n", ...)`，只在列表窗口是前台时生效。
    注意条件必须是**命名函数**：内联箭头传给 `HotIf` 会报 `Invalid callback function`。

24. **★ `#Warn` 会把"跨文件调用的顶层函数"判成未赋值变量，但别用 `Func("名字")` 去绕。**
    `lib\note-window.ahk` 里写 `(*) => NoteDeferNew()`，当这个库被 `tools\probe-menu.ahk`
    单独 include 时（没有 note.ahk），AHK 认为 `NoteDeferNew` 是个从没赋值的局部变量，
    直接**弹一个模态警告框**把自动化测试卡住。第一版为此改用了 `SetTimer(Func("NoteNew"), -10)`
    —— 那是 AHK **v1** 的写法。v2 里 `Func` 是内置类，`Func("NoteNew")` 会走类构造并返回一个
    残缺对象，`SetTimer` 再调它的 `.Call()` 就抛 `Object.Call / Invalid base.`。更坑的是这个
    异常被 `OnError` 静默记进日志就完事（不弹框），界面表现是**点托盘菜单、点便签菜单全都没反应**。
    实测：`Func("X")` 直接抛 `Invalid base`，而裸函数名 `x := X` 的 `Type` 就是 `Func`。
    正确写法是调 `App` 的静态方法（`SetTimer(() => App.NewNote(), -10)`）——
    库被单独 include 时探针里也有同名 `App` 桩类，两边都能跑，还不用延迟解析函数名。

25. **自检脚本不要裸写 `ExitApp`。** 直接 `ExitApp 0` 会跳过 WebView2 controller 的
    `Close()`，进程退不掉（实测连 `timeout 45s` 都等不到），而且这段时间仍占着单实例互斥锁，
    紧接着跑下一个自检就会被"已经有一个实例在跑"顶掉，症状是测试莫名没反应。
    统一走 `SelfTestDone()` → `App.Quit()`（关窗口 → 关列表 → 关库 → 退出）。

26. **★ `Ctrl+滚轮` 要用页面自己的 `wheel` 处理器，不要指望 WebView2 的缩放。** 页面里
    `window.addEventListener('wheel', ..., { passive:false })` —— `passive:false` 必须显式写，
    否则 Chrome 按被动监听处理，`preventDefault()` 无效，会同时触发 WebView2 自己的整页缩放
    （字被放大两倍）。宿主侧再把 `IsZoomControlEnabled := 0` 关掉，双保险。
    字号是**全局**的（`config.ini` 的 `[appearance] fontSize`），不是每张便签一份：
    改完广播给所有开着的便签，两边一起变，和浏览器 Ctrl+滚轮 一个手感。

27. **★ 图片不要塞进数据库，正文里只存 `file:///` 链接。** `body_html` 和 `body_md` 各存一份，
    一张 base64 图会让记录涨到几 MB，而自动保存是"每 400ms 重写整条记录"，打字会明显发卡。
    现在的做法：页面把图读成 data URL 发给宿主 → 宿主用 `crypt32\CryptStringToBinaryW`
    解码（两遍调用：先问长度再真解）落盘到 `data\images\yyyyMMdd-HHmmss-xxxx.png`
    → 回一个 `file:///` URL，页面再把占位 `<img data-req="N">` 换成真图。
    上传是异步的，所以先插占位图：用户上传期间继续打字，图片位置也不会跑偏。

28. **★ 拖拽/粘贴插图要在 `#editor` 和 `#source` 上都挂监听。** 富文本模式和 Markdown
    源码模式是两个不同的宿主元素（contenteditable / textarea），只挂前者的话，用户在
    源码模式里拖图、粘图**完全没反应** —— 而 `document` 级的 `preventDefault` 又把浏览器的
    默认行为拦掉了，表现就是"什么都没发生"。textarea 里没有 DOM 选区，
    `caretRangeFromPoint` 对它无意义，源码模式直接跳过定位、按当前光标位置插。

29. **★ 加列不能只在 `ALTER TABLE` 里写，建表语句也得有；判断"要不要迁移"不能只看版本号。**
    踩过：`title_locked` 只加在 v1→v2 迁移分支里，`CREATE TABLE` 忘了写。结果新建的库
    版本号直接就是 2、迁移永远不跑，读行时 `m["title_locked"]` 抛 `Item has no value`，
    而且只在**新建的库**上炸（用户的老库先跑过迁移反而是好的），很难复现。
    现在的写法是 `_EnsureColumn()`：查 `PRAGMA table_info` 实测列在不在，不在就
    `ALTER TABLE`。版本号只说明"迁移跑过"，不说明"列真在"。

30. **便签标题默认由正文第一行派生，`title_locked` 记录"用户起过名字"。** 保存正文时用
    `UPDATE notes SET title=CASE WHEN title_locked=1 THEN title ELSE ? END`，一条 SQL
    搞定"没锁就跟着第一行变、锁了就绝不覆盖"。用户清空输入框 = 解锁 + 按第一行重算。

31. **★★ `AreBrowserAcceleratorKeysEnabled := 0` 会把 `Ctrl+V` 一起废掉。** 当初为了让
    `Ctrl+N` 不被 WebView2 当"新建窗口"吃掉，把这个设成 0，结果用户报"右键插入图片
    正常、`Ctrl+V` 毫无反应"。原因是 Chromium 的粘贴是**浏览器侧**的编辑命令，快捷键
    一关，renderer 根本不产生 `paste` 事件，页面里挂再多监听也收不到。
    正确做法：便签窗口保持默认（开启），改在页面 `keydown` 里 `preventDefault` 掉
    `F5` / `Ctrl+R` / `Ctrl+P` / `Ctrl+F` / `Ctrl+N` / `Ctrl+O` / `Ctrl+J`。
    列表窗口那边只关 Ctrl+N，仍然用 0（那里不需要粘贴）。
    **另**：`paste` 监听要挂在 `document`（capture 阶段）而不是 `#editor` 上 ——
    `paste` 投给"当前焦点元素"，用户点过标题栏或刚关掉原生右键菜单时焦点根本不在
    编辑区，挂 editor 上的监听永远不响。这两个坑叠在一起，症状就是"偶尔能粘、多数
    时候没反应"。

32. **图片默认缩略、点击看原图。** `.editor img { max-height:180px; object-fit:contain }`：
    不封顶的话一张 1080p 截图就能把便签撑满，一个字都写不了。看大图用独立的
    `position:fixed` 遮罩，**不要**用把 `img` 本身放大的做法 —— 遮罩不参与文档流，
    开关的时候正文不跳动、光标不丢。`Esc` 只关遮罩（先判断，别顺手把选区也清了）。

33. **窗口右上角的 `×` 不该是"删除"。** 原来它直接 `Destroy` + `Delete`，误点一次
    便签就没了。现在 `×` = 收起（`hidden=1`），删除只留右键菜单和列表两个入口。
    危险动作永远不要放在"窗户把手"上。语义变了记得同步 `title` / `aria-label`，
    否则鼠标悬停时提示还在骗人。

34. **RTF 导出：中文必须写成 `\uNNNN?`，而且 `RegExReplace` 的第三个参数不接受函数。**
    `\uNNNN` 里的 NNNN 是 16 位**有符号**数（U+9898 → -26472），转义函数里要
    `c > 32767 ? c - 65536 : c`。顺序也讲究：先把整行做 RTF 转义，再套 `{\b ...}`
    这类命令 —— 反过来的话自己插入的命令会被二次转义。另外替换进去的文本（比如
    `[图片]`）也要再过一遍转义，否则裸中文就混进 RTF 了。
    AHK 2.0 的 `RegExReplace(hay, needle, replacement)` 里 replacement 只能是字符串，
    传函数对象会报 `requires a String, but received a Func` —— 要回调只能自己扫
    `MatchCollection` 再拼（HTML 内嵌图片就是这么做的）。

35. **设置面板的两个坑。** ①"试注册"热键有副作用：`Hotkey(k, fn, "On")` 成功后就真的
    占住了，`Off` 又注销掉，所以**校验失败时要把原来的热键整体重绑回去**，否则用户
    改一个非法快捷键，原来的那个也没了。②打开设置要 `await CreateControllerAsync`，
    **绝不能在菜单回调里直接调** —— 这就是"点完菜单什么都没反应"那个老 bug 的复现路径，
    统一走 `SetTimer(..., -10)`。
    ③字号写盘是 400ms 合并的，自检里改完字号如果立刻 `ExitApp`，定时器被掐掉，
    配置就停在测试值上（踩过：用户配置文件被测试改成了 18）。

36. **AHK 的 `Map.Count` 是属性、自己类的 `Count()` 是方法。** 写 `App.Store.Count`
    （漏括号）拿到的是**函数对象**，拼进字符串时报 `Expected a String but got a Func`，
    行号还指在日志那一行，很难往这儿想。另外 `Hotkey(KeyName)` 在 2.0.31 上恒返回空串，
    查不到"这个热键注册了没有"，只能靠注册时自己打日志。

37. **`JsonStr` 这类"扁平 JSON 正则"不能碰大字段。** 这是"Ctrl+V 粘图一直没反应"
    的真正原因：图片 base64 有 800KB~几 MB，`"data"\s*:\s*"(...)"` 这种带嵌套量词
    的模式在这个量级上会撞 PCRE 的 match limit，直接抛
    `PCRE execution error.`（日志里只有一行 `未处理异常 [RegExMatch] ... @27`，
    `@27` 就是 `lib/json.ahk` 第 27 行）。异常从定时器里冒出来没人接，页面永远
    等不到 `image-ok`，正文里就留一个虚线空图框 —— 看起来像"粘贴功能没做"。
    现在 `JsonStr` 改成 `InStr` 找键 + 线性找结束引号（跳过 `\"`），4MB 只要 16ms。
    **教训**：凡是"长度由用户数据决定"的字符串，都不要交给正则。
    同理 `WriteDataUrl` 也从正则改成了 `InStr` 切一刀。
    另外 `tools\probe-json.ahk` 专门盯这条：1.6MB / 4MB 各来一遍。
    `--selftest-edit` 里也改成粘 700×700 噪点图（base64 1.9MB）——
    之前用 8×8 小图，"自检全绿、用户一粘就废"，因为几百字节根本触发不了这个 bug。

38. **`AreBrowserAcceleratorKeysEnabled = 0` 会把粘贴一起废掉。** Chromium 的粘贴是
    浏览器侧的编辑命令，关掉快捷键之后 renderer 根本不产生 `paste` 事件，
    页面里挂再多监听也收不到。要拦 F5/Ctrl+R 就在页面 keydown 里 `preventDefault`。
    另外 `paste` 事件投给**当前焦点元素**，监听必须挂在 `document`（capture 阶段），
    挂 `#editor` 的话"点过标题栏再粘"就收不到。

39. **AHK 续行段（`( LTrim Join` ... `)`）里绝对不能写 `//` 注释。** `Join` 是把各行
    直接拼在一起的，行注释会把**后面所有行**一起注掉，整段 JS 变成语法错误，而
    `ExecuteScriptAsync` 只会返回 `null` —— 测试里表现为三条断言全挂、看不出原因。
    要注释就用块注释。

40. **代码着色只在"光标不在那块里"时重画。** contenteditable 里 `<pre>` 一旦重画
    innerHTML，光标就没了，严重时还会吃掉刚敲的字。所以：
    · 正在打字的那块**不碰**（暂时是素的），光标一移开（`selectionchange` 里判）
      立刻补色；
    · 失焦时把所有块补一遍，导出/保存前看到的也就是成品；
    · 代码块正文一律"纯文本 + span 外套"，`textContent` 必须一个字符都不变；
    · 换行用**真换行符**而不是 `<br>`（`pre` 本来就是 `pre-wrap`），
      但用户按回车时 Chromium 爱插 `<br>`，所以读文本要走 `preText()`，
      把 `<br>` 折成 `\n` —— 直接用 `textContent` 会把两行粘成一行，
      导出的 Markdown 就毁了。

41. **代码块的"出得去"和"进得来"是两件事，别用同一条判据。** 第一版只看"光标后面
    到块尾全是空白"就跳出去 —— 可块末尾正常敲回车想加第二行时，光标后面本来就是空的，
    于是**一按回车就被弹出块外，多行代码根本敲不进去**（用户实测）。现在只认
    "当前这一行本来就是空行"：也就是说**连按两次回车**才出去，按一次永远是换行。
    判定不能用字符偏移比长度：`textOf()` 把 `<br>` 折成了 `\n`，而 `caretOffset()`
    只数文本节点，两者天生差几个字符。要问 DOM —— 从光标到块尾这一段 range 取字符串
    （`caretAtEnd()`）+ 块正文是否以换行结尾（`lastLineEmpty()`）。
    `Shift+Enter` 特意**不是**出口：那是"块内换行"的肌肉记忆，误触一次等于把正在写的
    行扔出块外，比没有出口更气人。现在的出口是：空行回车 / `Ctrl+Enter` / `Esc` /
    块尾 `↓` / 空块退格；`Tab`·`Shift+Tab` 在块里是缩进（不然按 Tab 会把焦点跳走）。
    每次插入代码块后还会自动在末尾补一个空段落（`ensureTrailingBlock`，
    h2/列表/引用/分割线之后同理）。

42. **`execCommand` 认的是"当前选区"，文档没焦点时它连选区一起丢。** 所以 `Tab` 缩进
    这条路上先 `grabCaret()` 存一份 range，插完核对正文长度，没变就 `putCaret()` +
    自己 `insertNode`。自检里（窗口后台、没有用户手势）永远走兜底那条；
    真人打字时走 execCommand，好处是 Ctrl+Z 能一路退回去。

43. **原生菜单点下去，页面已经没有"用户手势"了。** 所以编辑菜单里的复制/剪切不能
    用 `navigator.clipboard`（会被拒），而是把选中的文字发给宿主，由 AHK 写
    `A_Clipboard`；粘贴则反过来 —— `document.execCommand('paste')` 在 Chromium 里
    永远返回 false（只给扩展放行），`navigator.clipboard.read()` 又要手势，
    只能让宿主在菜单关掉之后补按一次真实的 `Ctrl+V`。

44. **代码语言有两张表，必须同步。** 宿主 `NoteWindow.CodeLangs()` 只负责画菜单，
    真干活的是 `ui\code-hl.js` 里的 `LANGS`（调 highlight.js）。
    对不上就会出现"选了 Python 没反应"。`probe-menu` 会把两张表逐项比对，
    顺手也把"宿主发得出的每条 `cmd` 页面都能接住"一起验了 —— 这类跨文件约定
    最容易在改名时悄悄坏掉。

45. **vendor 的 highlight.js 是本地文件，不走 CDN。** `ui\vendor\highlight.min.js`
    （11.9.0，BSD-3-Clause，121KB，含常用语言）和 `ui\vendor\highlight-github.css`。
    单机便签断网是常态，引 CDN 等于功能随时消失。导出 HTML 的色板也是直接读这份
    CSS 内联进去（`Export.HljsCss()`，读不到就退回内置的紧凑色板），
    两边共用一份，颜色不会慢慢跑偏。

46. **双击标题栏不能靠 `dblclick` 事件。** 便签顶栏的拖动是"页面按下 → 宿主补发
    `WM_NCLBUTTONDOWN` → 系统进模态移动循环"，按下那一瞬间鼠标就被系统接管了，
    第二下的 `click` / `dblclick` 派不派发到页面不由我们说了算。
    所以页面自己数点击：同一屏幕坐标（±6px）、380ms 内的第二下就当双击，
    并且**这一下不再发 `drag-start`** —— 否则第二次按下又去拽窗口，"放大"变成"挪一下"。
    用 `screenX/screenY` 而不是 `clientX/Y`：第一下如果让窗口挪动了一两个像素，
    客户区坐标会变，屏幕坐标不会。宿主侧再兜一层：最大化之后 `StartMove` /
    `StartResize` 直接不理，页面也不再发这两个消息（`state.maxed`），
    CSS 里 `body[data-max="1"] .grip` 顺手把手柄藏了。

47. **最大化不是 `WS_MAXIMIZE`，是"搬到工作区"。** 这窗口是 `-Caption` 无边框的，
    真走系统最大化会按旧边框算法吃掉客户区，125%/150% 缩放下还会露边。直接
    `WinMove` 到当前显示器的工作区（`Win.WorkAreaOf`，按 `MonitorFromWindow` 取，
    多屏时不会拿错主屏那份），视觉上一样，还原时把原几何搬回去就行。
    两个坑：
    - **`SaveGeometryNow` 在最大化期间必须直接 return。** 不然满屏那一份被写进库，
      下次开机动不动就一张满屏便签。`restGeo` 只放内存。
    - **旗子要先立再动窗口。** `GeoTick` 每 800ms 巡检"窗口动过没有"，而 AHK 的
      定时器随时能打断当前线程 —— 先 WinMove 再置 `maximized`，巡检就会趁
      `SetMax` 还没返回把满屏几何写进库（自检里真踩到了：`300x280 -> 1920x1040`）。
    收起（`Hide`）时先还原再收：从列表点开一张满屏便签既吓人又挡事。

48. **`InputBox` 不接受 Gui 选项，"置顶便签的重命名框"只能自己搭。**
    想让对话框置顶，最自然的写法是 `InputBox(prompt, title, "w420 h170 +AlwaysOnTop")`，
    但这版 AHK 直接抛 `Invalid option.`（Options 只认 `Wn/Hn/Xn/Yn/Tn`）。
    于是重命名改用 `App.AskText()`：一个普通 Gui（Text + Edit + 确定/取消），
    `topmost=1` 时整窗 `+AlwaysOnTop`。照着 InputBox 的手感补齐细节：
    回车=确定（按钮的 `Default` 选项）、`Esc`=取消（Gui 的 Escape 事件）、
    打开时 `EM_SETSEL(0,-1)` 全选、`WinWaitClose` 把调用线程停住（调用方拿到
    返回值时用户已经答完）。置顶判据有两条：**这张便签是 pinned**，或者
    **列表窗口置顶**（从列表右键重命名时，对话框不能被列表盖住）。
    同理，从置顶的列表打开设置面板时，设置窗口也临时 `+AlwaysOnTop`。

49. **AHK v2 的 Map 遍历顺序不是插入顺序。** `Map("yellow",…, "pink",…)` 第一个
    吐出来的可能是 `blue`（哈希序）。颜色菜单/设置面板要是直接
    `for k, v in Colors()`，六个颜色每次开机都换位置，看着像坏了。
    现在单独有 `NoteWindow.ColorKeys()` 定显示顺序，便签菜单、列表菜单、设置面板
    都按它排；`probe-menu` 会把两张表互相比对，漏一个或多一个都报。
    设置面板的色块也由宿主把颜色表发过去现画，页面里不存第二份表。

50. **`HasVal()` 在这个 AHK 版本里不存在。** 探针里用它查数组，`#Warn` 把
    `HasVal` 当成"从未赋值的全局变量"，弹了个模态框把整个探针卡住 —— 现象是
    "没有日志、没有输出、退出码 2"，很难往"少了个内置函数"上想。查表写循环。

51. **列表窗口的置顶是"窗口偏好"，不是条目字段。** 条目置顶（`notes.pinned`）会让
    那张便签窗口永远在最前；列表窗口的置顶只管它自己，存 `[window] listTopmost`。
    两边别搞混。页面点图钉只发"想变成什么"（`window-topmost` + `on`），宿主改完
    窗口样式再回 `{type:'topmost'}` 点亮按钮 —— 页面不自己翻 class，就不会出现
    "按钮亮着但其实没置顶"。开窗时也要**在建窗前**决定（`Gui` 的 `+AlwaysOnTop`
    只能创建时给），否则会看到闪一下。
