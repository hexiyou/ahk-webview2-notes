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
| 每张便签的透明度 | 便签右键「透明度」可单独设 30%~100%（存库里，跟这一张走）；列表右键有「重置透明度（100%）」兜底 |
| 便签快捷键 | 最多 10 张便签各挂一个全局热键，一键呼到最前（再按收起），列表里带角标；没有设的便签行为不变 |
| 六种颜色 | 黄 / 粉 / 蓝 / 绿 / 紫 / 灰，随时切换，颜色存在库里 |
| **待办便签** | **一种新的便签类型：一张便签里装一列事项，每件事有自己的标题、正文、状态、计划/截止时间和顺序** —— 跟普通便签同一个窗口、同一套外观，列表里靠徽标和「3/7」进度区分。详见下面的[待办便签](#待办便签) |
| **到点提醒** | **每条事项可挂多条规则：按「开始/截止」提前 N 分钟，或「开始前 N 天，每天几点」。到点时按规则**弹托盘提示 / 发邮件 / 调 Webhook / 跑外部程序**（四种通道可任意组合，不配就走托盘）**；10 分钟内的迟到补发，更早的只记一条 `missed` 备查，不会开机后被十几条旧提醒淹没。详见[待办便签](#待办便签) |
| 富文本 | 加粗、斜体、删除线、标题、列表、待办勾选、行内代码、引用、链接、代码块、分割线 |
| 代码着色 | 代码块自动上色（本地 highlight.js，离线可用）；右键「代码语言」可手动指定，语言跟着块走 —— 可视化 ⇄ Markdown 源码来回切、反复重画都不丢；导出 HTML 也带着颜色 |
| **代码一键复制** | 鼠标移到代码块上，右上角浮出「复制」按钮，点一下整段代码进剪贴板（换行是 CRLF，粘进记事本也是一行一行）；右键菜单里也有「复制这段代码」，按钮被滚走时用它 |
| 三套右键菜单 | 正文里是**编辑菜单**（撤销/剪切/复制/粘贴/全选/清除格式），图片上是**图片菜单**（复制图片/另存为/删除），标题栏和其它地方是**便签菜单**（置顶/颜色/导出/删除…） |
| 插入图片 | 拖文件进来 / `Ctrl+V` 粘截图 / 右键「插入图片…」；图片存 `data\images`，正文只留链接 |
| 看图 | 正文里的图按 180px 高缩略显示，点一下铺满窗口看原图（再点或 `Esc` 关） |
| **图片能带出去** | **对着图片右键（大图预览里、正文缩略图上都行）→「复制图片」直接粘到 Word / 微信 / 画图，或「另存为…」存到你要的位置**；另附复制文件路径、在文件夹中显示、从正文中删除 |
| 导出 | 右键「导出」→ TXT / Markdown / HTML / RTF / **PDF** / **Word**；HTML 把图片内嵌成 data URI，RTF 也把图拼进文件里，PDF 走 WebView2 原生打印（A4 + 1.5cm 边距），Word 靠本机 Office 转版（没装会提示，不会崩） |
| **导入** | 右键「导入文件…（TXT / Markdown）」把外部笔记搬进来：便签里已有内容时会问**覆盖**还是**追加**；编码自动认（UTF-8 带/不带 BOM、UTF-16、GBK） |
| 设置面板 | 托盘「设置…」或列表空白右键：启动行为、外观、新建便签的默认颜色、三个全局热键都能改 |
| 自定义标题 | 列表和便签的右键菜单都有「重命名…」；不手动改就按正文第一行自动取 |
| 重命名不被盖 | 便签/列表置顶时，重命名输入框也跟着置顶（AHK 自带 InputBox 做不到，见笔记 48） |
| Markdown | `Ctrl+M` 在所见即所得和源码之间切换，两边双向转换 |
| 字号缩放 | 编辑区 `Ctrl+滚轮` 实时放大 / 缩小（10~32px），所有便签一起变并记住 |
| 自动保存 | 停止输入 400ms 自动落库，关窗/收起/失焦时补一次 |
| 位置记忆 | 关掉重开，位置、尺寸、颜色、置顶状态都还原；列表和设置面板也各自记住自己的大小/位置 |
| 列表与搜索 | `Ctrl+Alt+L` 打开总览，按关键字全文搜索（含已收起的便签）；列表自己也能置顶（右上角图钉）、可拖边框改大小（有最小尺寸） |
| **列表排序** | 顶部下拉：默认（置顶优先）/ 标题 / 创建时间 / 更新时间，每种都能正序倒序；选择记在 `config.ini`，下次打开还是这个排法 |
| **列表过滤** | 按「有快捷键 / 已置顶 / 已展开 / 含图片 / 含代码块」筛选，五个条件可叠加（AND）；按钮上带数字徽标，一键清空 |
| **多选 + 批量** | 每行前面有复选框，可全选；勾上之后底部出现批量条：清空快捷键、置顶/取消置顶、收起/展开、改颜色、调透明度、批量导出、批量删除（删除有二次确认，写明不可恢复） |
| 右键菜单 | 便签和列表都支持，用的是系统原生菜单（能超出小窗口边界） |
| 托盘常驻 | 全局热键随时新建/呼出，关掉便签窗口不退出进程 |
| **外部调用** | **别的程序发一条窗口消息就能新建便签（纯文本或 JSON），还能拿回新便签的 id** —— 不起 HTTP、不装插件。见 [docs/ipc.md](docs/ipc.md) |

### 待办便签

一种新的便签类型（`kind = 'todo'`）。窗口、外观、置顶、透明度、颜色、快捷键全都和普通便签共用，
只是正文区从"一大块富文本"换成"一列事项卡片"。新建入口有三处：托盘菜单、列表空白处右键、待办便签自己的右键菜单。

| 操作 | 说明 |
|---|---|
| `+ 新事项` / `Ctrl+Enter` | 在末尾追加一条，光标直接落到标题上 |
| 点勾选框 | 未完成 ⇄ 已完成（已完成再点一次回到未完成；「已取消」只在状态菜单里） |
| `Ctrl+Shift+D` | 同上，不用摸鼠标 |
| 点状态胶囊 | 弹出状态子菜单：未开始 / 进行中 / 已完成 / 已取消 |
| 点时间胶囊 | 行内弹出「计划开始 / 预计完成」两个时间框，**精确到秒**；逾期会标红并写「逾期 2 小时」这样的相对时长 |
| 拖左边把手 | 调整顺序（只有按住把手才能拖，否则会吃掉正文里的选字） |
| `Alt+↑` / `Alt+↓` | 同上，事项多或窗口很窄时更好用 |
| `⋮` / 事项内右键 | 全量菜单：Markdown 源码、状态、计划/截止时间、关联便签、上移/下移、删除事项；光标落在代码块里时还会多出「复制这段代码」和「代码语言」 |
| `↗` | 跳到这条事项关联的便签；没关联过就直接进"选便签"；关联的便签被删了按钮会变灰，点它是重新选一张 |
| 事项正文 | 每条事项都是独立的富文本编辑器，支持加粗/列表/代码块/插入图片，跟普通便签的编辑体验完全一致 |
| `Ctrl+S` | 立刻落库（平时是停手 400ms 自动保存，`Ctrl+S` 只是"我现在就要存"） |
| 事项菜单 →「Markdown 源码…」 | 只对**单条事项**编辑源码，不是整页 —— 一页十几个块同时变源码没有使用场景，还会让 `Ctrl+M` 的语义变含糊，所以待办页**不注册**整页 md 模式，`Ctrl+M` 在这里没有绑定 |

三个阶段标志（**逾期 / 即将到期 / 进行中（自动）**）都是显示时现算的，不落库：改成"存进库"就得处理
"电脑关机三天再开机，库里那批逾期状态怎么补算"的问题，不划算。

#### 提醒

`⋮` →「提醒设置…」在页面里展开一块规则面板（行内，不弹系统对话框），两种规则：

| 规则 | 写法 | 语义 |
|---|---|---|
| 提前 | 「开始 / 截止」前 N 分钟（单位可选分钟/小时/天） | **一次性**。响过就停，面板上显示「已提醒过，不会再触发」 |
| 每天 | 开始前 N 天起，每天 `HH:MM` | 到计划开始时间即自动停止；关机错过的日子直接跳过，不补一屏 |

| 行为 | 说明 |
|---|---|
| 到点 | 主进程每 5 秒扫一次，到点按规则投递（见下） |
| 迟到 ≤10 分钟 | **补发**，`todo_fires.detail` 标 `late` |
| 迟到 >10 分钟 | 不发，只记一条 `missed` 并写明晚了多久 —— 早上开机收到十几条昨晚的提醒只会让人把提醒关掉 |
| 同一时刻 | 唯一索引挡住重复，重启/时钟来回拨都不会重复响 |
| 事项完成 / 取消 | 它的规则全部停掉；**改回未完成不会自动复活**（"我明明关掉的提醒又响了"是投诉） |
| 加规则时时间已过 | 当场提示「这个提醒时间已经过了，不会触发」，不等 10 分钟后悄悄记一条 `missed` |
| 排不上 | 没设计划开始时间就加「每天」规则，面板会写明原因，补上时间就能用 |

**投递通道**在规则面板上逐条勾选，四种可以任意组合；一个都不勾就是托盘提示（P2 的老行为）。

| 通道 | 配置 | 说明 |
|---|---|---|
| 托盘提示 | 不用配 | 永远可用。非阻塞（模态框会冻住整个程序的单 UI 线程） |
| 邮件 | 勾「邮件」；服务器/授权码在**设置面板 → 提醒邮件**配 | 主题 `[待办] 标题 · 状态`。465 走隐式 SSL，其余走 STARTTLS |
| Webhook | 勾「Webhook」并填 URL | `POST`，JSON 体里带标题/状态/时间/正文摘要。只允许 http/https |
| 外部程序 | 规则里写程序 + 参数 | 参数支持 `{title}` / `{status}` 之类变量，注入前先剥换行与控制字符 |

> 勾了 Webhook 却没填 URL 等于没配 —— 会静默退回托盘，而不是存一条永远发不出去的规则。

邮件/Webhook/外部程序**在子进程里发**（`note.ahk --notify <job> --result <res>`）：主进程只写一份
作业 JSON 就撒手，下次 tick 扫回执写回 `todo_fires`。这样 SMTP 的超时、Webhook 的 DNS 卡顿
都不会冻住界面；子进程不碰 SQLite，也就没有 `SQLITE_BUSY`。发之前先把这行标成 `sending`，
5 分钟没回执判超时 —— 重启后不会重复发。

`todo_fires` 表就是提醒历史：哪天几点、哪个通道、返回了什么，出问题能直接查。
`detail` 里永远不出现授权码（写日志前先过一遍"抹掉凭据"）。

> 边界：**程序没跑就不会响**。这是进程内调度的固有代价，设置页里的**开机自启**能缩小这个窗口，
> 但没法消除。投递通道（托盘 / 邮件 / Webhook / 外部程序）已经做完，导入导出包（P4）还没做。

> 便签正文区显示的是 `todos` 表的**只读派生摘要**（`- [ ] 标题` 清单）。数据层直接拦住了
> 对 `kind='todo'` 便签的 `SaveBody`（返回 0），所以不会出现"两边各写一份、谁也不服谁"。
>
> 导入导出包（`.qntodo` 打包 / 批量）还没做，属于后续阶段。设计见 [docs/todo-design.md](docs/todo-design.md)。

### 快捷键

便签窗口内：

| 按键 | 作用 |
|---|---|
| `Ctrl+B` / `Ctrl+I` / `Ctrl+U` | 加粗 / 斜体 / 下划线 |
| `Ctrl+S` | 立即保存，状态栏回「✓ 已保存 时:分:秒」 |
| `Ctrl+M` | 切换 Markdown 源码 |
| `Ctrl+滚轮` | 放大 / 缩小正文字号（也可用右键菜单的「字号」） |
| `Ctrl+V` | 粘贴截图 / 图片（拖文件到便签里同样可以） |
| `Ctrl+C`（看图时） | 把正在看的那张图复制到剪贴板（等于图片菜单的「复制图片」） |
| 双击标题栏 | 最大化 / 还原窗口（铺满当前显示器的工作区，不遮任务栏） |
| `Enter`（代码块里） | 正常换行，可以一行一行往下敲 |
| 鼠标移到代码块上 | 右上角浮出「复制」按钮，点一下复制整段代码 |
| `Enter`（空行上）/ `Ctrl+Enter` / `↓`（块尾） | 跳出代码块 |
| `Tab` / `Shift+Tab`（代码块里） | 缩进 / 退掉两格 |
| `Esc` | 代码块里 = 跳出；看图时 = 关闭大图；其它情况 = 失焦并保存 |

全局：

| 按键 | 作用 |
|---|---|
| `Ctrl+Alt+N` | 新建便签 |
| `Ctrl+Alt+L` | 打开便签列表 |
| `Ctrl+Alt+H` | 全部收起 / 再按全部显示 |
| 自定义（每张便签一个） | 在便签或列表的右键菜单里「设置快捷键…」分配，最多 10 张。按下＝没开就开、开着就提到最前、已经在最前则收起 |

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

**便签窗口的右键菜单分三套**，按你点在哪儿决定 —— 在正文里弹出"删除这张便签"
是最容易误点的组合，所以必须分开：

- 点**正文**（编辑区）的文字 → 编辑菜单
- 点**图片**（大图预览里，或正文里的缩略图）→ 图片菜单
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
复制这段代码                  光标在代码块里才有；和右上角的悬浮按钮同一条路
代码语言 ›   自动识别 / 纯文本 / JS / TS / Python / HTML / CSS / JSON / Bash …
             （只有光标在代码块里时才出现，当前语言打勾）
插入代码块
插入图片…
────────────
保存        Ctrl+S
```

**图片菜单**（对着图右键 —— 大图预览里、正文缩略图上都是这一套）：

```
复制图片          Ctrl+C      直接进剪贴板，粘到 Word / 微信 / 画图都行
另存为…                       弹系统保存框，原样拷一份出去
────────────
复制文件路径
在文件夹中显示
────────────
从正文中删除这张图            只断正文里这一处引用，图片文件留在 data\images
```

文件找不到时（数据目录搬过家、图片被手删了）前四项会变灰，免得点下去只弹一句"找不到"。

**便签菜单**（标题栏或 `⋯`）：

```
新建便签
便签列表…
────────────
重命名…
设置快捷键… / 快捷键…（Ctrl+Alt+1）   给这一张挂个全局热键，留空=取消
────────────
最大化窗口 / 还原窗口大小   双击标题栏（菜单项会跟着状态变）
置顶 / 取消置顶
颜色  ›        黄 / 粉 / 蓝 / 绿 / 紫 / 灰（当前色打勾）
透明度  ›      100%（不透明） / 90% / 80% / 70% / 60% / 50% / 40% / 30%（当前档打勾）
────────────
切换 Markdown 源码（源码模式下变成"切换到富文本编辑"）
复制全文
保存            Ctrl+S
插入图片…
导入文件…（TXT / Markdown）  便签里已有内容时会问「覆盖」还是「追加」
字号  ›        放大 / 缩小 / 恢复默认
导出  ›        TXT / Markdown / HTML / RTF
               PDF 文档 (*.pdf)
               Word 文档 (*.docx)
               ↑ 前四项是纯文本/标记，后两项要排版（PDF 建离屏窗口、Word 起 Office），
                 慢一点，菜单里用分隔线隔开了
────────────
收起这张
删除这张…      带二次确认
```

**列表窗口**（右上角是「新建 / 📌置顶 / ⋯ / 关闭」，Esc 也能关）：

- 右上角的 📌 切换**列表窗口自己的置顶**（亮起来 = 置顶中）。这是窗口偏好，
  存在 `config.ini` 的 `[window] listTopmost`，下次打开还是置顶的
- 在某一行的任意位置右键 → `打开 / 重命名… / 设置快捷键… / 置顶·取消置顶 / 颜色› /
  透明度›（头一项是「重置透明度（100%）」）/ 导出› / 收起这张 / 删除…`
- **「重置透明度」为什么必须放在列表里**：便签透到 30% 时可能已经"看着像没了"，
  这时还得能从一个稳定入口把它拉回 100% —— 列表就是那个入口
- 在空白处或标题栏右键（也可以点右上角 `⋯`）→ `新建便签 / 刷新列表 / 全部显示 / 全部收起 / 窗口置顶 / 设置… / 打开数据目录`

**排序、过滤、多选批量**（搜索框下面那一行）：

- 左边是**排序下拉**：`默认 / 标题↑ / 标题↓ / 创建↑ / 创建↓ / 更新↑ / 更新↓`。
  「默认」是置顶优先、新建在前，也就是平时看惯的顺序
- 右边是**过滤按钮**：点开是原生勾选菜单 —— 有快捷键 / 已置顶 / 已展开 / 含图片 /
  含代码块，五项都是"勾了才算"（不是互斥），可以叠加；按钮上会显示生效的条件数
- 排序和过滤都会写进 `config.ini`（`listSort` / `listFilter`），下次打开列表还是这个样子；
  不想再看了，点过滤按钮旁边的「清空」
- **每行前面有复选框**，勾上任意一条，底部就浮出批量条：

```
清快捷键 / 置顶·取消置顶 / 收起·展开 / 颜色 / 透明度 / 导出 / 删除…
```

  按钮文字会跟着选中项的状态变（选中的都是置顶的，就显示「取消置顶」）；
  批量删除会弹二次确认并列出要删的标题，默认按钮是「取消」——回车不会删掉一批东西

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
listGeo=             ; 列表窗口上次的大小/位置，格式 x,y,w,h（程序自己写，别手改）
settingsGeo=         ; 设置面板同上
listSort=default     ; 列表排序：default / title:asc / title:desc / created:… / updated:…
listFilter=          ; 列表过滤条件，格式 hotkey=1,pinned=1,shown=0,image=1,code=0（程序自己写）

[hotkey]
new=^!n              ; 留空表示不注册
list=^!l
toggle=^!h

[app]
showAllOnStart=0     ; 1=启动时把所有便签都显示出来
openListOnStart=0    ; 1=启动时打开便签列表

[debug]
devtools=0           ; 1=允许 F12 打开开发者工具

[ipc]
enabled=1            ; 0=关掉外部调用（只保留"第二个实例唤醒"）
activate=1           ; 外部塞进来的便签要不要抢焦点
```

### 设置面板

托盘菜单 →「设置…」，或者列表窗口空白处右键 →「设置…」。能改的东西：

| 分组 | 项 |
|---|---|
| 启动 | 启动时显示所有便签 / 启动时打开列表 / **开机自启**（写 `HKCU\...\Run`，值名 `QuickNote`） |
| 外观 | 半透明开关、正文字号（10~32）、新建便签的颜色（六个色块） |
| 快捷键 | 新建便签 / 打开列表 / 显示收起全部 —— 点进输入框**直接按组合键**即可录制，× 清空表示不注册 |
| **提醒邮件** | SMTP 服务器 / 端口 / 用户名 / **授权码** / 发件人 / 收件人 / 超时，带一个「发一封测试邮件」按钮 |
| 其他 | 打开数据目录、打开日志 |

保存后字号、默认颜色和热键**立即生效**（热键会先校验：写法非法或被别的程序占了会当场报错，
且原来的热键不会被弄丢）；透明开关会重建所有窗口。删掉 `config.ini` 再启动等于恢复出厂。

颜色色块是按宿主的 `NoteWindow.Colors()` 现画的，页面里不另存一份表 —— 以后加颜色只改
AHK 那一处，设置面板自动多一个色块。

**授权码怎么存**：用 Windows 的 DPAPI（`CryptProtectData`，绑定当前用户）加密后 base64
写进 `config.ini` 的 `pass_enc`，配置拷到别的机器/别的账号下解不开。密码框**永远是空的** ——
页面只知道「存过没有」，密文不回传、明文更不回传；留空保存 = 不改。授权码不是邮箱登录
密码：QQ / 163 要去邮箱设置里单独生成。

托盘菜单里也有「透明外观」开关，和设置面板里的是同一个值。

---

## 外部调用（IPC）—— 让别的程序往便签里塞东西

这是本程序**最重要的扩展点**：别的程序（你的 AHK 脚本、Python 工具、计划任务、CI 脚本）
不需要改它、也不需要插件系统，发一条 Windows 消息就能建便签。

```autohotkey
hwnd := DllCall("FindWindowW", "ptr", 0, "wstr", "QuickNoteAnchor", "ptr")
SendMessage(0x8010, 0x514E, 0, , "ahk_id " hwnd)          ; 新建一张空便签
; 带内容要发 WM_COPYDATA，见下面链接里的完整例子
```

| 能力 | 消息 |
|---|---|
| 新建空便签 | `0x8010` |
| 打开便签列表 | `0x8011` |
| 带内容新建（纯文本 / 扁平 JSON：标题、颜色、置顶、位置） | `WM_COPYDATA`（`dwData='QN01'`） |
| 回执：把新便签 id 发回你的窗口 | `0x8014`（宿主 → 调用方） |

* 现成参考实现：`tools\ipc-send.ahk`（独立 AHK，不引用本项目源码）、`tools\ipc-send.py`
  （Python，只用标准库，含回执）。
* 命令行也能用：`note.ahk --new "买牛奶"`、`note.ahk --list`。程序已在跑时，新起的那次
  会自动把参数转发给正在运行的进程。
* **完整协议、字段表、注意事项、排障表 → [docs/ipc.md](docs/ipc.md)**。

三个必须先知道的边界：

1. `SendMessage` 返回 1 只代表**已受理**，便签是随后在主线程建出来的；
   要 id 就在载荷里带 `replyTo`，等 `0x8014` 回执。
2. 只在**同一登录会话、同一权限级别**内有效（UIPI / 会话隔离，代码管不了）。
3. 载荷上限 64 KB，队列上限 32 条；`WM_COPYDATA` 不能用 `PostMessage` 发。

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

调试和测试可以用 `--data-dir <目录>` 换一个数据目录跑（`note.ahk --data-dir data\_try`），
自检就是这么做的 —— 不会往你真正的便签库里塞测试便签。

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
- **WebP 图片不能「复制图片」**：复制走的是 GDI+ 解码，它只认 BMP / JPEG / GIF / PNG / TIFF。
  WebP 请用「另存为…」（纯文件复制，不经过解码器）。
- **复制出去的图是 24 位白底位图**：剪贴板里同时写了 PNG 格式（Chromium、Office 会优先读它，
  透明保得住），但只认 `CF_DIB` 的老程序拿到的是白底版本 —— 这是 Windows 剪贴板的通病。
- **代码块正在编辑时不上色**：为了不跳光标，正在打字的那个块保持素色，光标一移开立刻上色。
- **修复前存过的代码块，语言可能已经丢了**：旧版着色会把渲染时写下的
  `<code class="language-x">` 冲掉，而库里存的就是着色后的 HTML —— 那批块里已经没有任何
  语言信息（`body_md` 也是从 HTML 反推的，一并丢了）。这属于信息已经不存在，升级不会
  自动恢复；在可视化里右键「代码语言」重新指定一次即可，**此后**无论怎么切换视图、
  重复着色都不会再丢（见实现笔记 92）。
- **导入只认 TXT / Markdown**：docx、pdf 要解析器，不属于"便签"的范围；图片也不会跟着进来
  （Markdown 里的 `![](本地路径)` 会变成裂图，需要的话拖进来重新插图）。
- **过滤"含图片/含代码块"是看正文 HTML**：查的是 `body_html` 里有没有 `<img` / `<pre`，
  不做语义解析。手工粘进来的、导出后再导入的内容同样算数。
- **搜索是 `LIKE` 匹配**：几千张便签以内都很快；再大就需要 FTS5 索引。
- **单显示器缩放切换**：开了 PerMonitorV2，但跨不同缩放的屏幕拖动时可能有轻微模糊，松开鼠标后恢复。
- **打开右键菜单时窗口会短暂"卡住"**：原生菜单是同步的，菜单开着期间主线程不处理其他消息
  （其他便签也不响应），关掉菜单立刻恢复。这是 `Menu.Show()` 的固有行为。
- **外部调用只在本会话、同权限级别内有效**：管理员身份运行的便签收不到普通权限脚本的消息
  （UIPI），另一个 RDP 会话/另一个登录用户也发不进来。要跨这些边界就得换成命名管道或 HTTP
  （见 `docs\ipc.md` 第 2 节的取舍）。
- **提醒邮件授权码绑定当前 Windows 账号和这台机器**：DPAPI 密文换机器、换账号都解不开，
  便携模式整个目录搬走之后要重新填一次授权码（其余配置照常）。这是刻意的取舍 ——
  配置能跟着程序走，密码不能。

---

## 目录结构

```
wv2-notes/
├─ note.ahk              主程序：单实例、托盘、热键、启动装载
├─ run.bat               ★ 开发调试入口：脚本模式跑，错误直接打在窗口里
├─ lib/
│  ├─ sqlite.ahk         SQLite 封装（优先用系统 winsqlite3.dll）
│  ├─ store.ahk          数据访问层（表结构、CRUD、搜索、排序 + 过滤）
│  ├─ todo-store.ahk     ★ 待办事项数据层（todos / todo_reminders / todo_fires，含 seq 排序与派生摘要）
│  ├─ reminder.ahk       ★ 提醒调度内核（规则→next_fire_at、tick、幂等、错过判定；可注入假时钟）
│  ├─ notify.ahk         ★ 投递内核：托盘之外的三种通道（邮件 / Webhook / 外部程序），主进程派发 + 子进程执行 + 回执回收
│  ├─ dpapi.ahk          ★ 凭据加密（CryptProtectData，绑定当前 Windows 用户）
│  ├─ note-window.ahk    一张便签 = 一个 Gui + 一个 WebView2（含两套右键菜单）
│  ├─ list-window.ahk    列表面板（单例；含排序/过滤/多选批量的宿主侧）
│  ├─ settings-window.ahk 设置面板（单例 WebView2，ui\settings.*）
│  ├─ ipc.ahk            ★ 外部调用接口：锚点窗口消息 + WM_COPYDATA + 回执（见 docs\ipc.md）
│  ├─ export.ahk         导出：TXT / MD / HTML / RTF（含图片内嵌）+ 批量（选目录、重名加序号）
│  ├─ pdf.ahk            ★ PDF：WebView2 PrintToPdfAsync，A4 + 1.5cm 边距（见笔记 85）
│  ├─ word.ahk           ★ Word：HTML → docx，交子进程跑 Word COM（见笔记 86–89）
│  ├─ clip.ahk           ★ 剪贴板：文字（LF→CRLF）+ 图片（CF_DIB + PNG）
│  ├─ win.ahk            窗口外观（透明/圆角/工作区/级联落点）
│  ├─ json.ahk           极简 JSON（只处理扁平字段；大字段走线性扫描，别用正则）
│  ├─ WebView2/          WebView2 AHK 绑定（第三方，v2.0.5）
│  └─ WebView2Loader.dll
├─ ui/
│  ├─ note.html/css/js   便签页面
│  ├─ editor-core.js     ★ 编辑器内核（代码块/光标/图片/插入），便签页与待办页共用
│  ├─ todo.html/css/js   ★ 待办页面（事项卡片、时间弹层、单事项 Markdown 源码）
│  ├─ list.html/css/js   列表页面
│  ├─ settings.html/css/js 设置面板页面
│  ├─ md.js              Markdown ⇄ HTML（纯函数，可单测）
│  ├─ code-hl.js         代码着色（管"什么时候可以重画"、语言存哪，见笔记 40 / 92）
│  └─ vendor/            highlight.js 11.9.0 + github 主题（BSD-3-Clause，本地不放 CDN）
├─ assets/note.ico       图标
├─ runtime/              自带的 AutoHotkey 运行时
├─ tools/                冒烟测试、端到端测试、图标生成
│  ├─ _run-st.sh         ★ 自检批跑器：一条命令跑一组 --selftest-*，只打结论行
│  ├─ probe-todo.ahk     ★ 待办数据层探针（不需要 WebView2，含 v3 老库升级用例）
│  ├─ probe-remind.ahk   ★ 提醒引擎探针（不需要 WebView2，假时钟跑跨日/错过/幂等）
│  ├─ probe-notify.ahk   ★ 投递内核探针（不需要 WebView2、不发真邮件：自带一个本机 HTTP 服务验 Webhook，验作业/回执格式）
│  ├─ ipc-send.ahk       ★ 外部调用示例（AHK，独立可拷走）
│  └─ ipc-send.py        ★ 外部调用示例（Python，含回执）
├─ tests/md.test.js      Markdown 单测
└─ docs/
   ├─ ipc.md             ★ 外部调用协议文档
   └─ todo-design.md     ★ 待办便签设计方案（分四期，当前已完成 P1 / P2 / P3）
```

---

## 开发与测试

```bash
# 全量回归（推荐姿势）：一条命令跑一组自检，只打结论行，挂了才把失败明细贴出来。
# DATA 固定落在 data\_st，绝不碰你自己的库。
# 注意 rc 那一列：自检结论行是脚本自己写的，进程在退出的收尾阶段崩掉时，
# 结论照样是"通过"，只有退出码会露出来（Git Bash 下显示 127）。见实现笔记 25。
bash tools/_run-st.sh rich edit codelang codecopy note import \
                        export image batch settings pdf docx \
                        list del font hotkey opacity showall todo remind notify

# Markdown 渲染 / 纯文本提取 / 标题提取
node tests/md.test.js

# 单窗口冒烟（真 WebView2，会写 data\_win.log）
runtime\AutoHotkey64.exe tools\probe-window.ahk

# 端到端：输入→防抖→落库→切模式→改色→几何→重开（27 项断言）
runtime\AutoHotkey64.exe tools\e2e.ahk

# 列表面板：渲染/搜索/回调 + 排序/过滤/多选批量条（43 项断言）
runtime\AutoHotkey64.exe tools\probe-list.ahk

# 排序与过滤：三种排序 × 正倒序、五种过滤条件、叠加、持久化（33 项断言，很快）
runtime\AutoHotkey64.exe tools\probe-sort.ahk

# 回归"点完新建就拖不动"：真鼠标点「新建」再拖两个窗口（8 项断言，需先启动 run.bat）
runtime\AutoHotkey64.exe tools\probe-newbug.ahk

# 菜单：回调参数个数、闭包、菜单项是否都包了包装器、三套右键菜单的两端是否对得上、
#       代码复制按钮的接线 + Clip.SetText 的 CRLF 转换 +
#       导入/排序/过滤/批量/PDF/Word 的两端接线（213 项断言，很快）
runtime\AutoHotkey64.exe tools\probe-menu.ahk

# 待办数据层：建表/迁移、事项 CRUD、seq 排序与重编号、派生摘要、关联失效、
#              v3 老库升级（52 项断言，很快，不需要 WebView2）
runtime\AutoHotkey64.exe tools\probe-todo.ahk

# 提醒引擎：offset/daily 两种规则的时间推算、跨日与"已过点跳过"、10 分钟宽限的两侧边界、
#          同一时刻反复 tick 只一条、时钟来回拨、终态停规则、消息文案（69 项断言，很快，
#          不需要 WebView2 —— 时间全靠 Reminder.Clock 注入）
runtime\AutoHotkey64.exe tools\probe-remind.ahk

# JSON 取值：大字段（1.6MB / 4MB）不许崩、转义引号 / 同名键 / 缩进边界 / 键存在性（35 项断言，很快）
runtime\AutoHotkey64.exe tools\probe-json.ahk

# 程序级自检：收起全部→全部显示，看窗口是不是真回到屏幕上
runtime\AutoHotkey64.exe note.ahk --selftest-showall

# 程序级自检：把菜单弹出来（会一直开着，Ctrl+C 或关掉即可）
runtime\AutoHotkey64.exe note.ahk --selftest-menu

# 程序级自检：Ctrl+N 链路（热键注册 + 条件判定 + 延迟建窗不卡死）
runtime\AutoHotkey64.exe note.ahk --selftest-keys

# 程序级自检：延迟入口能不能真的把列表打开（回归"点菜单没反应"）+
#              拖边框改窗口大小后页面有没有跟着重铺 + 尺寸下限 + 尺寸记忆
runtime\AutoHotkey64.exe note.ahk --selftest-list

# 程序级自检：删/置顶之后列表要立刻刷新（页面 ✕ 按钮与右键菜单两条路）
runtime\AutoHotkey64.exe note.ahk --selftest-del

# 程序级自检：每张便签的透明度（页面 opacity / 不透明外观下重建成分层窗口 /
#              列表右键「重置透明度」；判据取页面自己算出来的值）
runtime\AutoHotkey64.exe note.ahk --selftest-opacity

# 程序级自检：便签快捷键（真注册 / 非法键 / 撞全局键 / 撞别的便签 / 上限 10 /
#              收起后能呼出 / 列表角标）
runtime\AutoHotkey64.exe note.ahk --selftest-hotkey

# 程序级自检：图片带出去（贴一张 320×180 的图 → 复制进剪贴板并核对 CF_DIB 宽高/位深/像素 +
#              PNG 格式 → 另存为补扩展名 + 只复制路径 → 三套菜单的 zone=image / Ctrl+C /
#              从正文删除；17 项断言）
runtime\AutoHotkey64.exe note.ahk --selftest-image

# 程序级自检：代码块右上角的复制按钮（悬停浮出 + 位置/归属 + 剪贴板内容与 CRLF +
#              「已复制」回执 + 移开收起 + 重新着色后仍可用 + 右键菜单入口 +
#              不污染落库的 HTML；19 项断言）
runtime\AutoHotkey64.exe note.ahk --selftest-codecopy

# 程序级自检：代码块的语言标记在「可视化 ⇄ Markdown 源码」往返中不丢
#              （源码里给围栏标 python → 可视化 + 重画后仍是 python → 菜单改语言 →
#               切回源码围栏还在 → 选「纯文本」→ 在 <code> 里回车/输入不粘行 →
#               落库的 HTML 带 language-x；18 项断言）
runtime\AutoHotkey64.exe note.ahk --selftest-codelang

# 程序级自检：导入（UTF-8 BOM/无 BOM/UTF-16/GBK 四种编码识别 + TXT 覆盖 +
#              Markdown 追加渲染 + 接缝只留一个空行 + 空文件/超 4MB 被挡；17 项断言）
runtime\AutoHotkey64.exe note.ahk --selftest-import

# 程序级自检：批量操作（清快捷键并真的释放键 / 置顶同步窗口 / 改色 / 收起展开 /
#              透明度 / 批量删除 + 批量导出的重名去重；21 项断言）
runtime\AutoHotkey64.exe note.ahk --selftest-batch

# 程序级自检：Ctrl+滚轮 字号（合成 WheelEvent，验放大/上下限/落盘）
runtime\AutoHotkey64.exe note.ahk --selftest-font

# 程序级自检：富文本工具条 / Markdown 往返 / 图片插入（含源码模式）
runtime\AutoHotkey64.exe note.ahk --selftest-rich

# 程序级自检：粘贴链路 / 图片限高与看大图 / 右上角 X 只收起不删除
runtime\AutoHotkey64.exe note.ahk --selftest-note

# 程序级自检：大图粘贴(1.9MB base64) / Ctrl+S 回执 / 代码块多行输入与出路 /
#              代码着色 / 编辑菜单命令 / 双击标题栏最大化与还原
runtime\AutoHotkey64.exe note.ahk --selftest-edit

# 程序级自检：六种导出格式（TXT / MD / HTML / RTF / PDF / Word）
#              RTF 断言会验图片真的编进了 \pict、hex 长度 = 2×文件大小、大图被降到 1600px
runtime\AutoHotkey64.exe note.ahk --selftest-export

# 程序级自检：PDF 导出（A4 尺寸 / 图片 / 字体子集 / 批量两张，8 项断言，约 5 秒）
runtime\AutoHotkey64.exe note.ahk --selftest-pdf

# 程序级自检：Word 导出（起子进程跑 Word COM，验 docx 里图片内嵌、代码底色、
#              两张批量；本机没装 Office 时第一条就报"没有 Word"并整体判未通过，
#              不会崩、也不会卡住等超时，6 项断言，约 20 秒）
runtime\AutoHotkey64.exe note.ahk --selftest-docx

# 程序级自检：待办便签 —— 老库(v3)升级不丢数据 → 建窗 → 事项增删改 → 勾选/逾期 →
#              排序 → 关联便签（含 ↗ 跳过去不卡死）→ 筛选 → 时间弹层 → 单事项 Markdown 源码 → 删除
#              （54 项断言，约 9 秒）。它会真的建一张待办便签再删掉，还会写一个 v3 老库样本，
#              所以务必配独立 --data-dir，别拿日常库跑
runtime\AutoHotkey64.exe note.ahk --data-dir data\_st --selftest-todo

# 程序级自检：提醒规则 —— 面板加/删/开关、卡片脚部条数、到点才发、同一时刻不重复、
#              补发与错过、终态停止、默认托盘通道（33 项断言，约 7 秒）
#              会自己关掉 5 秒定时器并注入假时钟，跑完还原
runtime\AutoHotkey64.exe note.ahk --data-dir data\_st --selftest-remind

# 程序级自检：提醒投递 —— SMTP 配置与 DPAPI 密文、密码留空不改、开机自启注册表、
#              端到端派发（真的起一个 note.ahk --notify 子进程）→ 回执回收 → 库里 ok、
#              无通道退回托盘、页面开关拼 notify（29 项断言，约 6 秒）
runtime\AutoHotkey64.exe note.ahk --data-dir data\_st --selftest-notify

# 程序级自检：设置面板（开窗 + 读值 + 颜色色块 + 拖大窗口重铺 +
#              保存生效 + 非法热键拦截 + 提醒邮件字段 + 密码框不被预填 + 开机自启，29 项）
runtime\AutoHotkey64.exe note.ahk --selftest-settings

# 程序级自检：重命名框（置顶/普通两版 + 置顶便签的端到端）
runtime\AutoHotkey64.exe note.ahk --selftest-dialog

# 程序级自检：外部调用接口 —— 真起一个独立进程（tools\ipc-send.ahk）发消息，
#              验纯文本/JSON/回执/三种拒绝/开关闸（33 项断言，约 8 秒）
runtime\AutoHotkey64.exe note.ahk --data-dir data\_ipctest --selftest-ipc

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

25. **★ 退出路径必须先把 WebView2 关掉，否则 Windows 会弹"已停止工作"。** 这条踩了两次，
    第二次的代价是一整轮返工：
    ① 直接 `ExitApp 0` 会跳过 WebView2 controller 的 `Close()`，进程退不掉（实测连
       `timeout 45s` 都等不到），而且这段时间仍占着单实例互斥锁，紧接着跑下一个自检就会被
       "已经有一个实例在跑"顶掉，症状是测试莫名没反应；
    ② **带着活着的 controller 退出会真的崩**。事件日志里是 `AutoHotkey64.exe`
       `0xC0000005`（访问违例）+ `0xC000041D`（用户回调里的致命异常）、偏移固定
       `0x8ffe8`，Windows 补一个"AutoHotkey v2.0 已停止工作"框。日志里一点异常都没有 ——
       因为它崩在 `OnExit` 之后的对象拆除阶段，脚本已经不管事了。用户看到的就是
       "最近老弹崩溃框"。
    定位方法（全都不需要调试器，一小时能定死）：
      · **时间对得上** —— 崩溃时刻永远是日志最后一行 `退出：reason=Exit code=0`
        之后 2~3 秒，跑几次就 1:1 对上；
      · **模块对得上** —— WER 的 `Report.wer` 里出现 `EmbeddedBrowserWebView.dll`，
        说明崩的是真建过 WebView2 的那个进程，不是 `--notify` 子进程；
      · **空脚本对得上** —— 只有 `ExitApp` 的脚本跑 5 次零崩溃；建窗但不关再跑 3 次全崩。
        这一步把"环境/第三方钩子"（本机有 Listary、搜狗注入）干净排除掉。
    现在两道保险：`App.Quit()` 关完窗口/列表/库之后**直接 `ExitProcess`**，跳过 AHK 那层
    和 WebView2 异步收尾互相踩踏的对象拆除；`NoteOnExit` 里再兜一道 —— 任何裸 `ExitApp`
    走到这里都先把还活着的窗口关掉。
    回归里靠 `tools/_run-st.sh` 的 `rc` 列盯：这类崩溃的自检结论行照样是"通过"，
    只有退出码会露出来（Git Bash 下显示成 `127`）。

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
    重画的落点是 `<code>`（没有就落在 `<pre>` 上），语言另存在 `pre[data-lang]`，
    原因见笔记 92。

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

52. **★★ `OnMessage` 回调里绝不能建 WebView2。** 回调跑在 AHK 的**新线程**里，会随时
    打断主线程（和 `SetTimer` 一个性质）；而建 controller 要 `await`，COM 回调里
    `await` 永不返回。真在那儿建窗，症状是**发送方的 `SendMessage` 一直卡着、整个程序冻住**
    —— 比"点了没反应"更难查，因为看起来是外部程序坏了。
    所以 IPC 回调只做「校验 + 入队」，真正建窗交给 `SetTimer(IpcDrain, -1)`。
    这条纪律和菜单/设置窗那几处是同一套（见笔记 20）。

53. **`WM_COPYDATA` 是同步的，返回 1 只代表"已受理"。** 发送方会一直等到你返回，
    而你的返回必须**早于**便签被建出来（建窗要 200~500ms）。所以语义只能是
    "收下了"，不是"建好了"。要 id 就得传 `replyTo`、建完再 `PostMessage(0x8014, id)`。
    文档里必须写死这一条，否则调用方会拿返回值当 id 用。

54. **★ 64 位 `COPYDATASTRUCT` 的 `lpData` 在偏移 16，不是 12。**
    布局是 `DWORD_PTR(8) + DWORD(4) + 4 字节对齐 + PVOID(8)`。
    手搓指针时按 8/12 取会读到垃圾指针，轻则拒收、重则访问违例。
    用结构体声明（C#/Python `ctypes.Structure`）就不会错；AHK 里只能自己算，
    所以 `A_PtrSize = 8 ? 16 : 8` 两路都写了。

55. **AHK 的 `PostMessage` 找不到 message-only 窗口。** 回执的信箱窗口常常是
    `CreateWindowEx(..., HWND_MESSAGE, ...)` 建的"消息窗口"，而 AHK 的 WinTitle
    搜索只覆盖**顶层窗口** —— `PostMessage(0x8014, id, 0, , "ahk_id " h)` 会**静默失败**。
    用 Python 那版示例验证时踩到：`app.log` 里是"投递失败"，调用方永远等不到回执。
    改成 `DllCall("PostMessageW", "ptr", h, "uint", msg, "ptr", w, "ptr", 0, "int")` 就好了。
    （顺带：这也说明"AHK 自己的 API 发不出去"不一定是对面的问题。）

56. **"指定标题"和"自动标题"必须是两条路。** `SetTitle` 的语义是"用户亲自命名"，
    会写 `title_locked=1`；而外部塞进来的正文一开始没有标题，得先按首行生成一个给列表看，
    但用户之后改首行时它应该继续跟着变。第一版图省事用了 `SetTitle`，结果外部建的便签
    标题被永久钉死 —— `--selftest-ipc` 的"自动标题没上锁"那条断言当场抓到，
    于是补了 `Store.SetAutoTitle()`（显式 `title_locked=0`）。
    结论：**名字里带"设置"的方法，先想清楚它是不是隐含了"锁定"语义。**

50. **`HasVal()` 在这个 AHK 版本里不存在。** 探针里用它查数组，`#Warn` 把
    `HasVal` 当成"从未赋值的全局变量"，弹了个模态框把整个探针卡住 —— 现象是
    "没有日志、没有输出、退出码 2"，很难往"少了个内置函数"上想。查表写循环。

51. **列表窗口的置顶是"窗口偏好"，不是条目字段。** 条目置顶（`notes.pinned`）会让
    那张便签窗口永远在最前；列表窗口的置顶只管它自己，存 `[window] listTopmost`。
    两边别搞混。页面点图钉只发"想变成什么"（`window-topmost` + `on`），宿主改完
    窗口样式再回 `{type:'topmost'}` 点亮按钮 —— 页面不自己翻 class，就不会出现
    "按钮亮着但其实没置顶"。开窗时也要**在建窗前**决定（`Gui` 的 `+AlwaysOnTop`
    只能创建时给），否则会看到闪一下。

57. **`+Resize` 的窗口，网页内容不会自己跟着长大。** 列表窗口和设置面板都是"普通 Gui +
    WebView2"，而 controller 的尺寸**只由 `Fill()` 决定**（内部 `GetClientRect` +
    `put_Bounds`）—— Windows 不会替你转告 WebView2。没接 `Gui.OnEvent("Size", ...)`
    时的表现就是"窗口拉大了，内容还停在原来的尺寸，右边一大片空白"（用户报的正是这个）。
    补法是 `g.OnEvent("Size", ListOnSize)`，回调里判一下 `minMax = -1`（最小化时客户区是 0，
    铺上去等于把页面压成一条，还原时会闪），再 `wvc.Fill()`。
    这里**直接 Fill，不要转给 `SetTimer`**：用户拖边框时系统在模态的 `WM_SIZING` 循环里
    排队派发消息，脚本自己的消息循环不转，定时器会被推迟到松手之后；Size 回调本身就在
    窗口过程里，最及时。
    自检判据要看**页面自己的 `document.documentElement.clientWidth`**，不能只看窗口宽度：
    controller 没跟上时，窗口明明变宽了而页面一无所知，viewport 一点没动，只有这个断言抓得住。

58. **右键菜单改完数据必须自己回推一次列表。** 列表页有两条入口：页面上的按钮（✕ 收起 /
    ✕ 删除）走 `Handle`，末尾统一 `Push`；右键菜单走 `Menu.Show` 的回调，是另一条路。
    第一版菜单只调了宿主钩子、没补 `Push`，于是"右键删除后那一行还赖在列表里，手快再点
    它一下就报『便签已经被删除』"（用户报的）。新建/改名/置顶/换色/收起 全是同一个毛病。
    现在统一走 `ListWindow.CallThenPush()`：调完钩子立刻把新列表推下去。
    教训：**同一个动作有两个入口时，收尾逻辑要么做成唯一出口，要么两边各写一遍并且都写对。**

59. **存窗口几何要存"客户区"，不是外框。** `Gui.Show("w" w " h" h)` 的 w/h 说的是
    **客户区**，而 `WinGetPos` / `Win.Rect` 给的是**外框**。第一版把外框写进配置、再拿外框
    去 `Show`，结果每开一次窗口就长一圈边框（这台机器上 14px）—— `--selftest-list` 的
    "尺寸记忆"那条断言（关前 620x520，重开后 634x534）当场抓到。现在存 `Win.ClientSize()`
    拿到的客户区（`[window] listGeo/settingsGeo`），位置仍存外框的 x/y。
    读回来还要过 `Win.Clamp`：上次可能是在另一块屏或更大的分辨率上拖的，直接照搬会开到
    看不见的地方去。

60. **尺寸下限要拦 `WM_GETMINMAXINFO(0x0024)`。** Gui 没有"最小尺寸"这种选项，能一路拖成
    一条缝。挂 `OnMessage(0x0024, ...)`，`lParam` 指向 `MINMAXINFO`，`ptMinTrackSize` 在
    偏移 24(x) / 28(y)，按 hwnd 认窗口再 `NumPut`。列表 380×300、设置 460×420。
    注意回调必须按 hwnd 过滤（这个窗口消息是全局的），不然会把便签窗口也一起限制住。


61. **"半透明"要淡页面，不能调 `SetLayeredWindowAttributes` 的 alpha。** 那个 alpha 在这套
    结构里**只影响命中测试**（画面走 WebView2 自己的合成树，不经过窗口的重定向表面）——
    调低了的效果是"看着没变、但点不到了"，非常容易误判成"透明度没生效"。
    正确做法：窗口保持分层 + alpha=255，把 `<html>` 的 **CSS opacity** 降下去。
    必须挂在 `html` 上而不是 `.note` 上：不透明外观那条路 body 铺着便签色，只淡卡片的话
    透出来的是 body 那块实色，看上去一点没变。100% 时把 inline style 清掉，别留 `opacity:1`。
    验证方法：`tools\shot-screen.ahk` 抓桌面（页面截图看不出桌面透不透），
    45% 与 100% 两张一对比就能确认（文字变淡、能看见下面的窗口）。

62. **每张便签的透明度上限是"要重建窗口"的。** 分层与否是建窗时的扩展样式
    （`WS_EX_LAYERED|NOREDIRECTIONBITMAP`）+ `DefaultBackgroundColor=0`，建完就改不了。
    默认外观是透明（本来就分层），改透明度只是发一条 CSS；但外观设成不透明白色时，
    100% 的便签是普通窗口，调到 <100 必须**重建**这一张。重建要 `wvc.Close()` + 重新
    `await` 建 controller，所以走 `SetTimer` 独立线程，不要放在菜单回调里。
    从 <100 调回 100 **不用**重建（分层窗口画不透明内容完全正常），只有页面 opacity 回到 1。
    菜单点的是档位（100/90/…/30）而不是滑杆，也是为了让重建最多只发生一次。

63. **便签快捷键的冲突必须自己比。** AHK 的 `Hotkey()` 对同一个键**重复注册不报错**，
    是后来者把前一个的函数顶掉 —— 两个便签填同一个键，表现是"先设的那个按了没反应"，
    而不是报错。而且 `^!A` 和 `!^a` 在 AHK 眼里是同一个键（大小写、修饰符顺序都不敏感），
    所以判重前要归一化：修饰符拆出来按 `#!^+` 固定顺序排、主键转小写（`App.NormHotkey`）。
    三个全局热键与便签快捷键也要互相拦：设置面板保存时同样查一遍，否则"保存成功，
    某张便签的键却没了"。上限 10 张，超出时明确拒绝而不是静默顶掉。

64. **"呼出/收起"一个键，判据是窗口在不在前台。** 逻辑分两步：窗口不存在 → 打开；
    已在前台 → 收起；其余 → 提到最前。判断必须在**定时器线程**里做（热键线程只
    `SetTimer(NoteSummonTick.Bind(id), -10)`）：`OpenNote` 要 `await` WebView2，
    在热键线程里建窗和以前踩过的"回调里建窗"是同一类坑。
    列表角标写字用的是 `NoteWindow.HotkeyPretty`（`^!1` → `Ctrl+Alt+1`）——放在窗口层
    而不是 App 里，是因为 `tools\probe-list.ahk` 这类测试只加载窗口层、不带 App。

65. **图片复制必须由宿主写剪贴板，而且两种格式要一次写完。** 右键菜单是原生菜单，
    点下去的那一刻页面已经没有用户手势，`navigator.clipboard.write()` 会被 Chromium
    直接拒掉（和编辑菜单的"复制"绕回宿主是同一个原因）。
    `EmptyClipboard()` 会把先前放进去的格式**全部清掉**，所以 `CF_DIB` 和 `"PNG"` 必须在
    同一次 `OpenClipboard` 里写完；分两次写等于白写第一种。
    两种都要的理由：`CF_DIB` 是所有 Windows 程序都认的公共分母，但只有 24 位，透明部分
    会被合到白底上；`"PNG"` 注册格式保得住透明，可老程序（部分 Office、老版画图）根本
    不读它。只写一种，总有一半软件粘出来不对。

66. **`GdipCreateBitmapFromFile` + `GetDIBits` 写 `CF_DIB`：请求 24 位，别用 32 位。**
    32 位 `BI_RGB` 的 alpha 字节在多数程序里被当成"未使用"，粘出来要么全黑要么全透；
    24 位白底反而处处正常。每行按 4 字节对齐（`((w*24+31)//32)*4`），`biSizeImage` 写
    实际字节数，`biHeight` 用正数（自下而上，最通用的方向）。
    GDI+ 只认 BMP / JPEG / GIF / PNG / TIFF —— WebP 会失败，这时返回 false 让上层提示
    改用「另存为」（纯 `FileCopy`，什么格式都行），而不是给用户一个空剪贴板。

67. **`file:///` 还原成本地路径，不要用 `PathCreateFromUrlW`。** 它对 `%E5%9B%BE` 这种
    UTF-8 序列按**单字节**摊开，结果是 "å¾" —— 中文文件名当场变乱码（`probe-menu` 里
    "百分号编码过的中文也能还原"这条断言第一次跑就抓到了）。
    自己解更可靠：`%XX` 收成字节、普通字符按 UTF-8 写进 Buffer，最后整体
    `StrGet(buf, "UTF-8")`。另外页面发 src 时要用 `getAttribute('src')` 而不是 `.src`：
    前者是作者写的原样（中文还是中文），后者是浏览器规范化后的（中文会变成 `%E5…`）。

68. **图片菜单要比 `zoneOf()` 先判。** 大图预览的遮罩是 `body` 的直接子元素，不在
    `#editor` 里，按落点判会落到 `zone=note` —— 右键一张图却弹出"删除这张便签"，正是
    最容易误点的组合。所以 `contextmenu` 回调第一件事判 `lightbox.hidden`，第二件判
    `e.target.tagName === 'IMG'`，之后才走原来的两套。
    删图走 `execCommand('delete')`（进浏览器撤销栈，误删能 Ctrl+Z），不要 `el.remove()`
    直接撸 DOM —— 那样删完就真没了。图片文件本身不删：同一条便签可能引用了两次。

69. **`Menu.Disable` 认的是 `Add` 时的完整名字，包括 `\t` 和加速键文本。** 给
    `m.Add("复制图片`tCtrl+C", …)` 之后写 `m.Disable("复制图片")` 会抛
    `Nonexistent menu item.`；被 `try` 吞掉之后表现是"该灰的项没灰"，用户点下去才发现
    找不到文件。`probe-menu` 里专门留了一条断言钉这个规则。
    顺便记一下：菜单项回调要套 `MB()`（笔记 44）、菜单只能在独立线程里 `Show`。

70. **代码块上的悬浮按钮不能住在 `<pre>` 或 `#editor` 里。** 两个方向都会坏：
    放进 `<pre>` —— `CodeHL.paint()` 会换掉 `<code>` 的 innerHTML，按钮会被整块冲掉；而且
    `textOf()` 会把按钮上"复制"两个字算进代码，复制/导出全带上它。
    放进 `#editor` —— `snapshot()` 取的就是 `editor.innerHTML`，按钮会被当成正文存进库，
    重新打开便签凭空多出一个按钮。
    所以它是 `body` 下的一级节点，`position: fixed`，靠 `getBoundingClientRect()`
    跟着块走。不在文档流里，开关也不影响光标和排版。
    同理，监听器**不能挂在 `<pre>` 上**（重绘时整块换掉，监听器跟着没了），
    统一挂 `document` 的 `mousemove`，用 `e.target` 反查是哪一块。

71. **`display: none` 的元素量不出尺寸。** 第一版是"先量位置、再显示"，于是
    `offsetWidth` 永远是 0，每次都落到兜底的 56px —— 窄便签里按钮会顶到右边框
    外面 6px（自检量出来是 12px 的留白）。改成**先 `hidden = false` 再
    `placeCodeCopy()`**，摆不下（块已经滚出视野）再收回去。自检里"右侧留 0~20px"
    那条断言就是抓这个的：修之前 12，修之后正好 6。

72. **页面给的文字进剪贴板，要自己把 LF 换成 CRLF。** AHK 的 `A_Clipboard` 赋值
    **不会**自动转换（实测：写 `"a`nb"` 进去，读回来长度 3、没有 CR），而记事本、
    Word、不少国产办公软件只认 CRLF —— 多行代码粘过去会挤成一行。
    统一走 `Clip.SetText()`（`RegExReplace(text, "\r?\n", "`r`n")`），
    `clipboard-set` 那条消息也顺手改用它，编辑菜单的"复制/剪切"一起受益。
    正则用 `\r?\n` 而不是裸 `\n`，已经带 CR 的输入不会变成 `\r\r\n`。

73. **复制整段代码要削掉末尾那个换行。** `<pre>` 的排版产物末尾总带一个 `\n`
    （用户回车留下的空行也在里面），原样塞进剪贴板，粘到目标位置会多一个空行。
    `codeText()` 里 `replace(/\n+$/, '')`，和 Markdown 导出（`md.js`）保持同一套规则。

74. **"移开就收起"要留 200ms 缓冲。** 从代码块挪到按钮上那一瞬间会先收到
    "离开块"的 mousemove，立刻隐藏的话按钮根本点不到。做法是 200ms 的
    `setTimeout`，鼠标一进入按钮就 `clearTimeout`。按住鼠标（拖选文字）时一律
    不显示，免得挡住选区。

75. **导入要自己猜编码，不能只按 UTF-8 读。** 国内用户从记事本/老编辑器另存的 txt
    很大比例是 GBK，按 UTF-8 硬读会整篇变成 U+FFFD（方块）。判据分三段：
    先看 BOM（UTF-8 的 `EF BB`、UTF-16 的 `FF FE` / `FE FF`）；没有 BOM 就先当
    UTF-8 读，**读出来含 U+FFFD 或整篇为空**再退回 `CP936` 重读一次。
    别用 `FileRead(path)` 的默认编码 —— 那是 ACP，跟文件真实编码没关系。
    顺带把 `\r\n` 和裸 `\r` 统一成 `\n`，否则追加导入的接缝会凭空多出空行。

76. **追加导入要先削掉正文末尾的空块。** `<pre>` 之外的正文是 `<div>` 堆出来的，
    用户每敲一次回车就多一个 `<div><br></div>`；原文末尾常常已经挂了两三个。
    直接再补一个分隔用空行，接缝看起来就是"三四行的大空档"。
    做法：追加前把末尾**纯空白且不含 `img/pre/table/hr`** 的 `<div>` 全删掉，
    再补一个空段落 —— 自检里"接缝只留一个空行"（`gap1`）就是钉这个的。
    末尾停着一张图的块不能削，那是正文内容。

77. **批量操作必须"库 + 已经开着的窗口"一起改。** 只改库的话，桌面上那张便签
    还是旧颜色、旧透明度 —— 用户会以为没生效。每个分支都顺手 `ApplyPin/ApplyColor/
    ApplyOpacity/Hide/Show`，最后**只刷一次**列表和托盘（`BatchNotes` 末尾统一收口）；
    逐张刷会把列表刷成幻灯片，逐张 `RebindNoteHotkeys()` 也是白折腾十次。

78. **批量删除的默认按钮必须是"取消"。** 确认框里列出前 5 个标题（超过就写
    "…等共 N 张"），并写明"正文、标题、快捷键、窗口设置都会一起消失，图片文件仍
    留在数据目录"。默认落在取消上，回车不会把一批东西删掉。

79. **批量导出选一次目录，别逐张弹"另存为"。** 十张便签就是十个对话框，中途取消
    还会留下一半文件。文件名去重要处理两件事：同一批内重名（用过的名字记账，
    **键转小写** —— Windows 文件系统不区分大小写）和目录里已有同名文件（也往后排，
    批量导出是多出几份，不该悄悄吃掉上次导出的东西）。

80. **探针绝不能弹模态框。** `note-window.ahk` 用了 `Clip.*`，但依赖只写在 `note.ahk`
    里 —— 谁单独加载窗口层（`probe-list`、`e2e`、`probe-shot`…）就会漏掉 `clip.ahk`，
    AHK 在**加载阶段**弹一个 "variable appears to never be assigned a value" 的
    警告框，然后一直等点击。无人值守跑测试时整轮就挂死在那儿（这个坑真踩了）。
    两条防线：① 窗口层自己 `#Include clip.ahk`（`#Include` 是 include-once，
    调用方重复带不会出问题）；② `tools\*.ahk` 顶部把 `VarUnset` 改成写 stdout：
    ```
    #Warn VarUnset, StdOut            ; 真漏了依赖 → 打到控制台，不阻塞
    #Warn LocalSameAsGlobal, OutputDebug
    #Warn Unreachable, OutputDebug
    ```
    为什么不全用 `All, StdOut`：`LocalSameAsGlobal` 这类警告在既有代码里有一堆
    （`f` / `t` / `i` 这种局部变量名和全局撞），全打出来会淹没真正的错误。

81. **自检不能假定用户的库是干净的。** 库里早就有几张便签挂着 `^!1`、`^!8`
    （用户自己设的），写死键名会让自检直接报"这个键已经给了便签"——那是**正常状态**。
    改成先探测：`TestPickFreeHotkey()` 从 `^!F9…` 里挑一个没被占的，并且排除已经
    挑走的那个。角标数量同理，`wantBadges` 现数"库里 hotkey 非空的条数"，不写死 2。
    批量操作的断言还要注意**顺序无关**：页面按当前列表顺序发 id，倒序排序时就是
    `3,2,1`，拿 `1,2,3` 去比会假失败（`probe-list` 里用 `SortedIds()` 先排序再比）。

82. **`hidden` 属性不一定真的隐藏。** 浏览器默认样式是 `[hidden]{display:none}`，
    但只要元素上有类选择器写了 `display`（`.fcount` 是 `inline-grid`、`.chip` 是
    `inline-flex`），类选择器优先级更高，元素照样显示 —— 表现是"没设过滤时，
    过滤按钮上挂着一个 `0`"。`list.css` 顶部加了一条 `[hidden]{display:none !important}`
    兜底。对应的断言也不能只看 `.hidden` 属性（那是 `true` 但视觉上还在），
    要看 `getComputedStyle(el).display === 'none'`。

83. **RTF 里塞图片，就是把文件 hex 一遍再拼进 `\pict`。** 格式是
    `{\pict\pngblip\picw<px>\pich<px>\picwgoal<twips>\pichgoal<twips> <HEX>}`，
    `\pngblip` / `\jpegblip` 按扩展名选。换算 **1px ≈ 15 twips**（1440/96），
    宽度上限留 9000 twips 才不会顶出页边。代价要知道：hex 是**两倍体积**，
    实测 2.88MB 的 PNG 导出后是 5.77MB 的 RTF —— 图多的便签会明显变大，
    这是格式本身决定的，不是实现问题。
    另外行内图和整行图要分开处理：整行 `![alt](src)` 直接出 `\pard\qc ... \par`；
    行内的（夹在文字里）得先在 `RtfInline` 里抽成 `QNIMGM<n>QNIMGE` 占位符，
    套完粗斜体那些正则之后再 `StrReplace` 换回来 —— 否则 hex 里随便一个数字
    都可能被粗体正则咬掉半截。

84. **`CryptBinaryToStringW` 的两个坑，一个坑 base64 一个坑 hex。** base64 用
    `CRYPT_STRING_BASE64(1)` 时默认**每 64 字符插一个换行**，得再 `| 0x40000000`
    （`CRYPT_STRING_NOCRLF`）才是干净的单行；十六进制更阴，`CRYPT_STRING_HEXRAW(0xC)`
    输出末尾**带一个 CRLF**，70 字节的文件本该 140 字符，实际拿到 142 ——
    断言当场对不上。统一 `Trim(..., " \t\r\n")` 一下最省事。
    （这个 bug 只在断言里暴露，粘进 RTF 后 Word 也能忍那个换行，很容易漏。）

85. **`PrintToPdfAsync` 三件事：回调里不能 await、默认是 Letter、背景要单独开。**
    ① `ICoreWebView2_7.PrintToPdfAsync(path, settings)` 是无对话框直接出 PDF，没装
    打印机的机器也能用。但**不能在 COM 事件回调里 `await` 它** —— 事件线程上等
    自己派发的完成事件，永远不会返回，表现为"点了没反应"。要 `SetTimer(..., -30)`
    退到独立线程再 await。② 默认纸张是**美式 Letter**（MediaBox 612×792），
    必须自己 `CreatePrintSettings()` 设 `PageWidth=8.27 PageHeight=11.69`（英寸），
    边距 `0.5906`（=1.5cm）。③ `ShouldPrintBackgrounds` 默认是 **false**，
    代码块的浅底色会整片消失；`ShouldPrintHeaderAndFooter` 默认 true，会平白多出
    页眉页脚。还有个小细节：`CreatePrintSettings` 要从 `wv.Environment` 取，
    写成 `wvc.Environment`（屏幕那一侧）拿不到这个方法。
    验 PDF 不能去 `InStr` 找 `/MediaBox` —— 文件里第一个 NUL 就把 `StrGet(..., "CP0")`
    截断了，什么也搜不到。要么逐字节扫，要么按二进制读。

86. **Word 必须甩进子进程跑，不能在本进程里 `ComObject("Word.Application")`。**
    Word 只要弹一个模态框（"文档包含宏"、"是否恢复"、字体缺失），主进程的 UI 线程
    就整个冻住 —— 便签窗口不动了，用户只能杀进程。做法是：主进程把每张便签先写成
    HTML（`Export.HtmlForWord`）丢到临时目录，再写一份 `jobs.tsv` 清单，`Run` 起
    自己（带 `--word-export <清单> --result <结果文件>`）跑一个隐藏子进程，主进程
    `SetTimer` 轮询结果文件、180 秒不落地就超时收摊，顺手 Toast 汇总。
    **子进程分支必须写在单实例锁之前** —— 写在后面的话第二次启动会被当成"又一个
    实例"转发给已经运行的进程然后退出，永远出不来结果。

87. **Word 导 HTML 只认标签选择器和内联 style，class 选择器一律不生效。**
    代码着色是 `<span class="hljs-keyword">` 这种，Word 打开后**全黑**。
    `HtmlForWord` 干的就是把 `class="hljs-*"` 换成 `style="color:#xxxxxx"`，
    comment / quote 再加个 `font-style:italic`。验的时候比 `w:color` 的出现次数：
    改之前 0 个色值，改之后 3 个。

88. **Word 导入图片默认存成外链，换个机器就全裂。** HTML 里 `<img src="file:///...">`
    进来后 `TargetMode="External"`，`word/media` 目录是空的。要逐张
    `InlineShapes.Item(i).LinkFormat.SavePictureWithDocument := true` 再 `BreakLink()`
    才真正嵌进 docx。验法是解包看 `word/media/image1.png` 在不在、大小对不对。

89. **`for p in doc.Paragraphs` 会偶发卡死，必须 `Item(i)`。** 想给代码块加底纹
    （`Paragraphs.Item(i).Shading.BackgroundPatternColor := 0xE5EDF0`，注意 Word
    的 `BackgroundPatternColor` 是 **BGR** 不是 RGB）时，第一版用了 `for p in`，
    结果子进程连日志都不写就挂在那儿。换成 `for i in 1..doc.Paragraphs.Count` 逐个
    `Item(i)` 就稳了 —— 集合的 IEnumVARIANT 枚举在 Word 上不可靠。
    `<pre>` 的 CSS 背景本来也不导入（生成的 XML 里 `w:shd` 是 0），只能靠这段补。

90. **AHK v2 的 `Run()` 不返回 PID。** 这个版本里 `pid := Run(cmd)` 拿到的是**空串**，
    下游"进程还活着吗"一判就是"已经退出"，于是刚起子进程就报失败。
    要用输出参数：`Run(cmd, , "Hide", &pid)`。
    **★ 这条已经踩过两次**（`word.ahk` 一次、`notify.ahk` 的 `_DoRun` 又一次）：第二次的表现
    更隐蔽 —— `ProcessExist("")` 立刻为假，于是"外部程序还没跑完"被当成"已退出"报
    `run:ok`，回执写着成功但程序写出来的文件还不存在。同一类坑还有 `CapturePreviewAsync`
    那种"回调没等到就当成功"。**判"成功"之前一定要验副作用**（文件在不在、库里有没有），
    别只信返回值。

91. **二进制文件不能 `StrGet(buf, size, "CP0")` 转了再 `InStr`。** 文件里必然有 NUL，
    字符串在第一个 NUL 处就断了，后面全看不见 —— 表现是"PDF 里明明有 `/Image`、
    `/FontFile2`，断言全 FAIL"。要么按字节扫（写个 `BytesHas(blob, needle)` 双指针
    逐个比），要么就别用字符串函数。顺带：A4 的 MediaBox 是
    `[0 0 594.95996 841.91998`，8.27 英寸换算过来带浮点尾巴，断言只能比前缀
    `/MediaBox [0 0 59`（Letter 是 612，一撞就分得开）。

92. **代码块的语言必须同时挂在 `<pre>` 上，不能只靠 `<code class="language-x">`。**
    highlight.js 的输出是**一串 span，没有 `<code>`**，而 `paint()` 早先写的是
    `pre.innerHTML = html` —— 于是渲染时那个 `<code>` 在第一次上色后就没了。
    `toMarkdown()` 当时又只从 `code.className` 读 language-x，两条路一齐断在
    这个看不见的节点上：屏幕上看着还对（`pre` 上留着 `data-hl`），一切换视图
    语言就变回没有语言的围栏，再切回来高亮也没了。
    现在的规则是：
    · `paint()` 只换 `<code>` 的 innerHTML（没有 `<code>` 的老数据保持原样，
      不凭空加节点 —— contenteditable 的节点结构一变，回车和粘贴的行为就跟着变）；
    · 每次上色都把语言写进 `pre[data-lang]`，它是唯一活得比 DOM 重绘更久的载体；
    · `toMarkdown()` 按 `code.language-x` → `code[data-lang]` → `pre[data-lang]`
      依次回退，三处都认；
    · `detect()` 本来就 `pre[data-lang]` 优先，右键菜单的勾选因此也稳了
      （以前重画一次，"代码语言"里的勾会跳回「自动识别」）。
    顺带一句：`language-text` 不是标准语言名，选「纯文本」时只写 `data-lang`，
    所以回退顺序里必须有 `data-lang` 那一档，否则选纯文本的块切回源码就丢标记。
