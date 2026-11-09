# 待办提醒（Todo）—— 设计方案

> 状态：**已评审通过，分期实施中**。
> 进度：**P1 已完成**（v4 迁移 / 事项 CRUD / 待办页 / 列表分类型，commit `06b4dc0`）；
> **P2 已完成**（规则面板 / `next_fire_at` / tick / 幂等 / 错过判定 / 托盘提示）；
> **P3 已完成**（SMTP / Webhook / 外部程序三种投递 + 设置页 + 开机自启 + 规则级通道开关）。
> P4（`.qntodo` 导入导出）未开始。
> 影响面：数据库 v3 → v4、新增一个便签类型与一个页面、主进程新增调度与投递。
> 相关文件：`lib/store.ahk`、`lib/note-window.ahk`、`note.ahk`、`ui/note.js`、`docs/ipc.md`。

---

## 0. 一页速览

| 问题 | 结论 |
|---|---|
| 改造现有便签，还是新增类型 | **新增类型**：`notes.kind = 'note' \| 'todo'` |
| 一个待办便签装什么 | 一个事项列表；事项在 `todos` 表 |
| 状态怎么存 | 存 4 态（todo/doing/done/canceled），`已逾期/即将到期` 现算不落库 |
| 计划时间到了要不要改库 | 不改，只影响显示 |
| 提醒在哪跑 | 主进程 5 秒 tick 只挑作业，**实际投递交给一次性子进程** |
| 重复触发怎么防 | `todo_fires` 唯一索引 `(todo_id, reminder_id, fire_at)`，先记账再发 |
| 关机期间漏掉的 | 10 分钟内补发，更早只记 `missed` 并汇总提示 |
| 程序没在跑 | 加「开机自启」开关，与漏发补扫并存 |
| 导出 | 单文件 `.qntodo`（JSON），图片 base64 内嵌 |

---

## 1. 范围

### 1.1 要做

1. 新的便签类型「待办便签」，一页多个事项，每个事项是独立富文本块；
2. 每个事项有标题、计划开始时间、预计完成时间、状态；
3. 事项可拖动/上下箭头排序，可关联一张普通便签；
4. 两种提醒规则（锚点提前 N 分钟 / 提前 N 天每天定时），三种投递通道；
5. 单独的导入导出格式，换机不丢属性和图片；
6. 列表页区分两种类型，可筛选、可看进度。

### 1.2 明确不做（本轮）

| 不做 | 原因 |
|---|---|
| 事项跨便签移动 | 会引入"移动即改归属"的权限/关联/提醒重建问题，复杂度不划算 |
| 重复任务（每天/每周那种） | 与"每天定时提醒"是两件事，混在一起规则会失控；表结构留了加 `rrule` 的余地 |
| 回收站 / 软删除 | 删除前有确认框；要找回就用导出包 |
| 日历视图 / 甘特图 | 本轮只做列表 + 排序；`start_at/due_at` 已经够将来画图 |
| 多人共享、云同步 | 单机桌面工具 |
| 事项级提醒的"贪睡 5 分钟" | 可作为后续小功能，需先想清楚它与 `daily` 规则的叠加语义 |

---

## 2. 路线：新增类型，复用容器

### 2.1 为什么不是改造现有便签

三条都是代码里能指到位置的硬约束：

1. **编辑器是单实例写死的。** `ui/note.js` 里 `editor` 出现 66 次、`scheduleSave` 23 次、`paintCodes` 6 次，保存 / 着色 / 粘贴 / 插图 / 末尾兜底 / 字数统计全部假设"一个 `contenteditable`"。要做成 N 个并列的富文本块，等于重写这个 1535 行的文件，而它正是靠光标细节活着、被 71 条 md 用例和十几套自检盯着的地方。

2. **现在的"待办"是正文的一部分。** `task-line` 就是 `<li>` + `<span class="chk">`，`data-done` 只是渲染标记，它参与 `MD.toMarkdown()` 往返、参与导出、参与 `Ctrl+Z`。而提醒会发邮件、起进程——**副作用不能挂在可撤销的编辑器内容上**。

3. **提醒必须脱离窗口存在。** 现有编辑逻辑全在窗口页面里，窗口一关就没了。提醒得是独立的数据 + 主进程调度。

### 2.2 复用与新增

| 层 | 复用 | 新增 |
|---|---|---|
| 便签容器（`notes`） | 窗口、配色、置顶、透明度、快捷键、列表、搜索、IPC、托盘 | 一列 `kind` |
| 窗口类（`NoteWindow`） | 窗口生命周期、透明、缩放、菜单框架、单实例 | 按 `kind` 选页面、菜单分叉 |
| 编辑器 | `md.js`、`code-hl.js`、`vendor/`、图片管线 | 抽出 `ui/editor-core.js` 供两页共用 |
| 列表窗口 | 排序、筛选、搜索、右键菜单 | 类型徽标、类型筛选、进度 |
| 数据 | SQLite + 现有 `Sqlite` 封装 | `todos`、`todo_reminders`、`todo_fires` |
| 导出 | 现有导出框架 | `.qntodo` 包 |

> 纪律：**抽 `editor-core.js` 是"搬家"不是"重写"。** 先抽完、跑全套现有自检（md 71 条 + codecopy/edit/rich/export 等）全绿，再动新页面。反过来做，一旦出问题分不清是抽取引入的还是新页面引入的。

---

## 3. 数据模型（v4）

### 3.1 时间单位

**沿用现有约定：Unix 秒（UTC 整数）**，展示层转本地时间。`lib/store.ahk` 开头写得很明确：*"所有时间戳都是 Unix 秒（UTC）"*。

不用毫秒：秒级精度对"提醒到点"完全够（tick 本身是 5 秒），而混用两种单位迟早会有人把 `due_at` 当毫秒传给 `Date`。

`0` 表示"未设置"，不是 `NULL`——SQLite 里 `NULL` 参与比较会得到 `NULL`，排序和过滤都会悄悄出错。

### 3.2 迁移（`SCHEMA_VERSION` 3 → 4）

```sql
-- 表结构：一律 IF NOT EXISTS，不看版本号也建
ALTER TABLE notes ADD COLUMN kind TEXT NOT NULL DEFAULT 'note';   -- 经 _EnsureColumn 加
CREATE INDEX IF NOT EXISTS idx_notes_kind ON notes(kind);

CREATE TABLE IF NOT EXISTS todos(
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id      INTEGER NOT NULL,
  seq          INTEGER NOT NULL DEFAULT 1000,
  title        TEXT    NOT NULL DEFAULT '',
  title_locked INTEGER NOT NULL DEFAULT 0,
  body_html    TEXT    NOT NULL DEFAULT '',
  body_text    TEXT    NOT NULL DEFAULT '',
  body_md      TEXT    NOT NULL DEFAULT '',
  status       TEXT    NOT NULL DEFAULT 'todo',   -- todo|doing|done|canceled
  start_at     INTEGER NOT NULL DEFAULT 0,
  due_at       INTEGER NOT NULL DEFAULT 0,
  done_at      INTEGER NOT NULL DEFAULT 0,
  canceled_at  INTEGER NOT NULL DEFAULT 0,
  link_note_id INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL DEFAULT 0,
  updated_at   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_todos_note ON todos(note_id, seq);
CREATE INDEX IF NOT EXISTS idx_todos_due  ON todos(due_at);

CREATE TABLE IF NOT EXISTS todo_reminders(
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  todo_id       INTEGER NOT NULL,
  kind          TEXT    NOT NULL DEFAULT 'offset',  -- offset|daily
  anchor        TEXT    NOT NULL DEFAULT 'start',   -- start|due（仅 offset）
  offset_min    INTEGER NOT NULL DEFAULT 0,         -- 仅 offset
  at_time       TEXT    NOT NULL DEFAULT '09:00',   -- 仅 daily
  days_before   INTEGER NOT NULL DEFAULT 1,         -- 仅 daily
  notify        TEXT    NOT NULL DEFAULT '',        -- JSON，见 §6.5
  enabled       INTEGER NOT NULL DEFAULT 1,
  next_fire_at  INTEGER NOT NULL DEFAULT 0,
  last_fired_at INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL DEFAULT 0,
  updated_at    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_rem_next ON todo_reminders(enabled, next_fire_at);

CREATE TABLE IF NOT EXISTS todo_fires(
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  todo_id     INTEGER NOT NULL,
  reminder_id INTEGER NOT NULL,
  fire_at     INTEGER NOT NULL,
  state       TEXT    NOT NULL DEFAULT 'sending',  -- sending|ok|failed|missed
  detail      TEXT    NOT NULL DEFAULT '',
  started_at  INTEGER NOT NULL DEFAULT 0,
  finished_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE(todo_id, reminder_id, fire_at)
);
CREATE INDEX IF NOT EXISTS idx_fires_todo ON todo_fires(todo_id, fire_at DESC);
```

> **防坑（本项目踩过一次）**：`_Migrate` 里 `if (cur < 3)` 这类分支只在老库上跑，新建的库版本号直接就是最新值，分支永远不执行。所以新表新索引一律用 `CREATE ... IF NOT EXISTS` 无条件建，`kind` 列用现有的 `_EnsureColumn` 按 `PRAGMA` 实测补，`meta.schema_version` 只作为记录。

### 3.3 `notes` 行对一张待办便签意味着什么

待办便签的**正本是 `todos` 表**，`notes` 行只是一个容器 + 摘要缓存：

| `notes` 字段 | 待办便签下的含义 |
|---|---|
| `kind` | `'todo'` |
| `title` | 用户给这个列表起的名字（如「本周上线」），可空 |
| `body_text` | **派生**：所有事项标题 + 正文摘要拼成一段，供搜索与列表摘要 |
| `body_md` | **派生**：`- [ ] 标题` 的清单，供普通 Markdown 导出与搜索 |
| `body_html` | **派生**：与 `body_md` 对应的简单 HTML |
| `mode` | 恒为 `rich`，不使用 |
| `color/x/y/w/h/pinned/hidden/opacity/hotkey` | 与普通便签完全一致 |

派生字段在 `TodoStore.SaveItem` / `DeleteItem` 的**同一个事务**里重算，保证列表摘要、搜索、`hasImage`/`hasCode` 角标全部免费可用。

> **这条带来一个必须守住的约束**：`notes.body_*` 对 `kind='todo'` 的行是**只读派生数据**。任何原本直接写 `notes` 正文的路径（`Store.SaveBody`、`App.ImportNote`）在这个类型上必须绕行，否则会被下次摘要刷新覆盖，表现为"导入的内容自己消失了"。

### 3.4 容量与索引

- 单页事项软上限 **500 条**，超过时新增按钮提示"建议拆成两张待办便签"。这是 UI 层限制，不是数据库限制。
- 常用查询都走索引：按便签取列表（`idx_todos_note`）、到点扫描（`idx_rem_next`）、按截止时间取逾期（`idx_todos_due`）。

---

## 4. 事项模型

### 4.1 正文与 Markdown

每个事项有自己的三份表示，和普通便签同构：`body_html`（富文本正本）/ `body_md` / `body_text`。

- 富文本块支持现有全部能力：加粗、颜色、列表、引用、表格、代码块（含语言与高亮）、拖拽/粘贴插图。
- `body_md` 由 `MD.toMarkdown()` 从 HTML 反推，与普通便签同一套代码，因此**不会出现两套转换逻辑**。
- Markdown 源码模式是**单事项级**的：事项 `⋮` 菜单 →「Markdown 源码」，弹一个该事项的源码编辑区。不做整页 md 模式——一页十几个块同时变成源码没有使用场景，而且会让 `Ctrl+M` 的语义变得含糊。
- 打字时不上色、失焦后补色这条现有策略原样保留，`editor-core` 里按根节点作用域执行。
- 保存防抖沿用现有 **400ms**，但按事项 id 分别排队：一个事项在打字不应该把别的事项也提交一遍（那会让 `updated_at` 集体乱跳，也让"最近编辑"的语义失真）。

### 4.2 标题

- `title` 单行，是提醒邮件主题、列表摘要、Webhook payload 的主要标识。
- 空标题时按正文第一行自动生成（与 `notes.title` 同规则，60 字截断），`title_locked=0` 表示仍是自动的；用户手动改过就 `title_locked=1`，正文再变也不覆盖。
- 沿用 `Store.SetTitle` / `SetAutoTitle` / `ClearTitle` 的三分法，别混用。

### 4.3 状态：存 4 态 + 派生 2 标志

**存储态**（只有用户操作或明确事件才写）：

| 值 | 界面名 | 进入方式 |
|---|---|---|
| `todo` | 未开始 | 新建默认 |
| `doing` | 进行中 | 用户手动切换 |
| `done` | 已完成 | 勾选复选框 / 菜单；写 `done_at` |
| `canceled` | 已取消 | 菜单；写 `canceled_at` |

**派生标志**（每次渲染按 `now` 现算，不落库）：

| 标志 | 条件 | 显示 |
|---|---|---|
| 已逾期 | `due_at > 0 && now > due_at && status ∈ {todo, doing}` | 时间胶囊变红 + 文案「已逾期 2 天」 |
| 即将到期 | `due_at - now ≤ 24h && status ∈ {todo, doing}` | 时间胶囊变橙 |
| 自动进行中 | `status = 'todo' && start_at > 0 && now ≥ start_at` | 状态胶囊显示「进行中（自动）」 |

三条规则合起来的效果：**计划时间到了不用改库**，显示就对了；改了计划时间，显示跟着退回去，不会留下"进行中"的既成事实。

`done` / `canceled` 是终态：不再参与逾期计算、提醒自动停（见 §5.8），但时间字段保留，便于事后核对。

### 4.4 排序

- `seq` 用**留空隙的整数**：新建 `1000、2000、3000…`，插入到两者之间取中值。
- 拖动一次只 `UPDATE` 一条；只有当两个相邻值间隙耗尽（差 ≤1）时才重排该便签的全部 `seq`（`1000, 2000, …` 重新编号）。这样"拖到第 3 位"这种操作不会写 500 行。
- 上下箭头 = 与相邻项交换 `seq`，与拖动共用同一套 `MoveTo`。
- 排序只在同一 `note_id` 内有效，不做跨便签的全局顺序。

### 4.5 关联普通便签

- `link_note_id` 指向被关联的便签；`0` = 未关联。
- 事项行首显示 `↗` 按钮：**点它才打开**被关联便签（`App.OpenNote`），点行内其它地方是编辑正文。这样"编辑"和"跳转"不会打架。
- 被关联便签删除后：`link_note_id` 置 0，事项保留，行尾打一个灰色「关联已失效」标记。**不做级联删除**——删一张便签顺手删掉一堆事项是最糟的意外。
- 打开列表时不做 N+1 查询：渲染所需的目标标题随事项一起查出来（`LEFT JOIN notes`）。

### 4.6 删除

删除事项 = 物理删除，前置一次性确认框（「删除这个事项？它的提醒也会一起删除。」）。删除时同事务清理 `todo_reminders`、保留 `todo_fires` 历史（外键不级联，历史留着排查"为什么那天没提醒"）。

---

## 5. 提醒引擎

### 5.1 两种规则

| 规则 | 字段 | 语义 |
|---|---|---|
| `offset` | `anchor`（start/due）、`offset_min` | 锚点前 N 分钟提醒一次。`N=0` 表示正点 |
| `daily` | `days_before`、`at_time`（`HH:MM`） | 从锚点前 N 天起，每天 `at_time` 提醒一次，到达锚点自动停止 |

`daily` 的锚点固定是**计划开始时间**（`start_at`）；需求里"任务开始前 N 天每天提醒"就是它。若 `start_at` 未设，规则无法生效，UI 上直接禁用并提示「先设置计划开始时间」。

一个事项可挂多条规则（例如「提前 1 天每天 9:00」+「开始前 30 分钟」），它们各自独立调度、各自独立记账。

### 5.2 `next_fire_at` 计算

调度器只认 `next_fire_at`，规则如何翻译成时间点由这两段函数负责：

```
offset:
  anchor := (anchor='due') ? due_at : start_at
  if anchor = 0: return 0                        // 无锚点，不排
  t := anchor - offset_min * 60
  if last_fired_at > 0: return 0                 // 单次规则，发过就不再排
  return t                                        // 允许是过去时间，交给 §5.5 判定补发

daily:
  if start_at = 0: return 0
  day := start_at 的本地日期 - days_before 天
  t := day + at_time
  while t <= now: t += 86400                      // 只向前找，不用循环历史
  if t >= start_at: return 0                      // 到开始时间即停
  return t
```

两个细节：

- `daily` 用"本地日期 + 时分"拼，再转 UTC 秒。跨时区/夏令时不在考虑范围（国内无夏令时），但如果以后要支持，这里是唯一改动点。
- `while t <= now` 最多走 `days_before` 次，不会死循环。

### 5.3 tick

主进程一个 `SetTimer(App.TickReminders, 5000)`，每次做四件事，全部是轻量查询：

1. 扫 `todo_reminders`：`enabled=1 AND next_fire_at > 0 AND next_fire_at <= now`，并 `JOIN todos` 排除终态事项；
2. 对每条：`INSERT OR IGNORE INTO todo_fires(...)`（唯一索引去重），`changes=0` 说明已发过，直接跳到第 4 步；
3. 拉起子进程投递（§6），`todo_fires.state='sending'`；
4. 重算这条规则的 `next_fire_at`（`offset` 置 0 并 `enabled=0`；`daily` 取下一个时间点，到点则停）；
5. 顺带扫 `data\notify\*.json` 结果文件，回写 `ok/failed` 并删除。

5 秒的间隔是有意的：比 1 秒省电，比 30 秒不至于让"到点"看起来像迟到了。数据库查询走索引，500 条事项也不到毫秒级。

**可测性要求**：`TickReminders(now)` 接受注入的 `now`，默认取 `Store.Now()`。否则测试只能等真实时间，等于没法测。

### 5.4 幂等

三层保护，缺一不可：

| 层 | 手段 | 挡住什么 |
|---|---|---|
| 数据 | `UNIQUE(todo_id, reminder_id, fire_at)` + `INSERT OR IGNORE` | 同一时刻重复触发（两次 tick 抢同一行） |
| 状态 | 发之前先写 `sending`，再拉起子进程 | 重启后重复发 |
| 进程 | 子进程带 `fire_id`，只处理自己那一行 | 子进程重复启动 |

`todo_fires` 同时就是「提醒历史」，出问题能查「那天到底发了没、通道返回了什么」。

### 5.5 错过（关机、休眠、程序没开）

启动时和每次 tick 都做一次判定，`fire_at` 距今：

| 距离 | 处理 | 记录 |
|---|---|---|
| ≤ 0（到点） | 正常发 | `ok / failed` |
| 0 ~ 600 秒（10 分钟） | **补发**，`detail` 标 `late` | `ok / failed` |
| > 600 秒 | 不发 | `missed`，`detail` 写明晚了多久 |

超过宽限的不逐条补发：早上开机收到 12 条昨晚的提醒只会让人把提醒功能关掉。改为在列表页顶部一条汇总：「有 3 条提醒在关机期间错过 · 查看」，点开是 `todo_fires` 里的一屏清单。

还有一处要顺手拦住：**新建提醒时若算出 `fire_at` 已经是过去时间**（比如任务 5 分钟后开始，却设了"提前 30 分钟"），保存时就该提示「这个提醒时间已经过了，将不会触发」，而不是等 10 分钟后悄悄记一条 `missed`。

同时纠正一个常见误解：**程序没跑就不会响**。这是进程内调度的固有边界，所以配 §7.3 的「开机自启」开关来缩小这个窗口，而不是假装它不存在。

### 5.6 时间跳变与睡眠

- 所有判定用**绝对时间比较**，不用倒计时累加。用户手动改系统时间、笔记本合盖唤醒，都不会让提醒漂移。
- 唤醒时 `now` 可能一次性跳过几个小时 → 落在 §5.5 的「>10 分钟」分支，记 `missed`，不补发。
- tick 里不缓存 `now`，每次重新取。

### 5.7 并发与卡死

- 同时最多 4 个子进程（`[notify] maxParallel`），其余在队列里等下一次 tick。防止"10 条同时到点"把机器拖住。
- `state='sending'` 且 `started_at` 超过 5 分钟仍是 `sending` → 视作子进程崩溃，改 `failed`，`detail='超时未回执'`，不自动重试。
- 失败重试只有一次（`[notify] retry=1`），且只在**通道返回可重试错误**时（连接失败/5xx），4xx 不重试。

### 5.8 终止条件

满足任一条即 `enabled=0`，并在 UI 上显示原因（不是静默消失）：

- 事项进入 `done` 或 `canceled`；
- `offset` 规则已发过一次；
- `daily` 规则算出的下一个时间点 ≥ `start_at`（"任务已到开始时间"）；
- 用户手动关闭该条提醒。

事项从终态改回 `todo/doing` 时，**不自动复活**已停的规则，只提示「这条提醒已停止，需要重新开启」——自动复活会让"我明明关掉的提醒又响了"变成投诉。

---

## 6. 投递

### 6.1 为什么必须是子进程

AHK 是单 OS 线程的协作式调度，定时器和消息回调都是伪线程。一次 SMTP 超时 10 秒，整个程序（所有便签窗口）就冻 10 秒。这不是理论风险，是 AHK 的固有行为。

所以：**主进程只挑作业 + 记账 + `Run`，投递全部在一次性子进程里做**，主进程立刻返回。

子进程入口 `--notify <fire_id>`，必须像现有的 `--word-export` 一样**放在单实例锁之前**判断（`note.ahk` 里那条注释已经把原因写清楚了：放在锁后面会被正在跑的实例当成"重复启动"转发一下就退出，父进程永远等不到结果）。

启动方式兼容脚本版与编译版：

```
exe  := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
args := (A_IsCompiled ? "" : '"' A_ScriptFullPath '"') ' --notify ' fireId
Run('"' exe '"' args, , "Hide")
```

### 6.2 三种通道

| 通道 | 实现 | 超时 | 备注 |
|---|---|---|---|
| SMTP | 子进程内起 `powershell.exe -NoProfile`，按端口选实现：465 → CDO（`cdosys.dll`，本机已确认存在）；587 → `System.Net.Mail` | 20s | 两条 TLS 路线各测一家邮箱再定默认值 |
| Webhook | `WinHttp.WinHttpRequest.5.1`（与 launcher 项目同一套用法） | 15s | 只发 POST；响应体只取前 2KB 记进 `detail` |
| 外部程序 | `Run` 目标命令，可选等待 | 10s（等待时） | 闹铃就走这条：`powershell -c "(New-Object Media.SoundPlayer 'C:\a.wav').PlaySync()"` |

**参数注入防护**：`{title}` 之类变量替换进命令前，必须剥掉换行、去掉控制字符、截断到 200 字；能用参数数组就不要拼一整个命令行字符串。

### 6.3 结果回传：写文件，不跨进程写库

子进程**不直接写 SQLite**。两个进程同时写同一个库会撞 `SQLITE_BUSY`，而现有 `sqlite.ahk` 封装没设 busy timeout，一撞就是报错。

流程：主进程把**作业**写成 `data\notify\<fire_id>.job.json`（通道清单 + 订阅者 + 规则快照），起子进程 `note.ahk --notify <job> --result <res> --data-dir <dir>`；子进程跑完把**回执**写到 `<fire_id>.res.json`（`{fireId, ok, detail, ms}`），主进程下一次 tick 调 `Notify.Collect()` 扫这个目录回写 `todo_fires`，然后把 job 和 res 都删掉。
回执只更新 `state='sending'` 的行 —— 重启后残留的旧回执不会覆盖已经判过超时的记录。
这个方向与项目现有的 IPC 哲学一致：**跨进程只传事实，不共享状态**。
子进程走的是 `App.Main()` 里**单实例锁之前**的分支，只读作业文件、发请求、写结果，不建窗口、不开数据库。

### 6.4 凭证

- SMTP 密码用 **DPAPI**（`CryptProtectData`，按当前用户）加密后 base64 存 `config.ini` 的 `pass_enc`，解密只在子进程里做一次。
- 密码**从 stdin 传给 PowerShell**，不放命令行——命令行在进程列表和事件日志里都能看见。
- 日志与 `todo_fires.detail` 里永远不出现密码；通道报错信息先过一遍"抹掉凭据"再记录。

### 6.5 消息内容

一条提醒的统一字段：

```
待办：{标题}
便签：{所属便签标题}
状态：{未开始/进行中}
计划：{2026-11-09 09:00} → {2026-11-10 18:00}
提醒：{规则描述，如"开始前 30 分钟"}
```

- **SMTP**：主题 `[待办] {标题} · {状态}`，正文纯文本（可选 HTML 版）。
- **Webhook**：POST JSON，字段固定，方便对方写规则：

```json
{
  "source": "QuickNote",
  "event": "todo.reminder",
  "todoId": 12,
  "noteId": 3,
  "title": "提交季度报表",
  "status": "todo",
  "startAt": 1762736400,
  "dueAt": 1762822800,
  "message": "…",
  "firedAt": 1762734600
}
```

- **外部程序**：`{title}` / `{status}` / `{startAt}` 等变量可用，参数化传递。

每条提醒的 `notify` 列存各通道的开关与目标：

```json
{
  "smtp":    {"on": 1, "to": ""},
  "webhook": {"on": 1, "url": "https://example.com/hook",
              "headers": {"Authorization": "Bearer xxx"}},
  "run":     {"on": 0, "exe": "powershell.exe",
              "args": "-c \"(New-Object Media.SoundPlayer 'C:\\alarm.wav').PlaySync()\""}
}
```

多个通道可同时开，任一成功即算 `ok`，全失败才 `failed`（`detail` 里逐条记）。

---

## 7. 界面

### 7.1 待办便签页（`ui/todo.html`）

窗口顶部沿用现有工具栏（配色、置顶、透明度、关闭不变），下加一条待办专用操作条：

```
[+ 新事项]   排序：手动 ▾   筛选：全部 / 未完成 / 已逾期   进度 3/7
```

每个事项一张卡片：

```
┌─────────────────────────────────────────────────┐
│ ≡  ☐  标题（单行，可编辑）      [进行中▾] [时间] [↗] [⋮] │
│     ┌───────────────────────────────────────┐   │
│     │ 富文本正文（可折叠，默认展开）           │   │
│     └───────────────────────────────────────┘   │
│     计划 11-09 09:00 → 11-10 18:00 · 提醒 2 条    │
└─────────────────────────────────────────────────┘
```

- 左侧 `≡` 是拖动把手；`☐` 勾选即 `done`（再点回 `todo`）。
- 状态胶囊点开是菜单：未开始 / 进行中 / 已完成 / 已取消。
- 时间胶囊点开是行内弹出层（两个 `datetime-local` + 秒），不用系统对话框——便签窗口最小只有 180px 宽。
- `↗` 打开关联便签；`⋮` 是「Markdown 源码 / 关联便签 / 提醒设置 / 上移下移 / 删除」。
- 正文为空时显示占位文案，不显示空的 `contenteditable`。
- 事项很多时只给可见项着色（`IntersectionObserver`），避免一页 200 个代码块同时高亮。

### 7.2 列表页

- 顶部加类型筛选：**全部 / 普通便签 / 待办便签**（与现有 `hotkey/pinned/image/code` 那套筛选并列）。
- 每行加类型徽标；待办便签在摘要位置显示「3/7 · 2 条逾期」。
- 右键菜单新增「新建待办便签」「导入待办包…」。

### 7.3 设置页

新增两个区块：

| 区块 | 项 |
|---|---|
| 提醒 | SMTP 主机/端口/加密方式/账号/密码（写入即加密）/发件人/默认收件人/超时；Webhook 默认超时；最大并发 |
| 启动 | **开机自启**（写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值名 `QuickNote`，内容按脚本版/编译版区分） |

开机自启与漏发补扫是两件事，都要有：自启缩小"没在跑"的窗口，补扫兜住关机那段。

### 7.4 快捷键（仅待办页生效）

| 键 | 行为 |
|---|---|
| `Ctrl+Enter` | 新事项（光标进正文） |
| `Alt+↑ / Alt+↓` | 上移 / 下移当前事项 |
| `Ctrl+Shift+D` | 切换当前事项完成状态 |

与现有 `Ctrl+M`（普通便签的 md 模式）不冲突：待办页不注册整页 md 模式。

### 7.5 窗口默认尺寸

待办便签默认 `460 × 540`（普通便签是 `300 × 280`），仅在新建时使用；用户拉过之后按库里的几何走。

---

## 8. 导入导出

### 8.1 文件格式

扩展名 `.qntodo`，内容是 UTF-8 JSON（不是 zip，避免引入压缩依赖）。

```json
{
  "schema": 1,
  "kind": "quicknote.todo",
  "app": "QuickNote",
  "exportedAt": 1762736400,
  "note": { "title": "本周上线", "color": "yellow", "createdAt": 1762000000 },
  "linkedNotes": [
    { "exportId": "n1", "title": "上线检查单", "bodyHtml": "…", "bodyMd": "…" }
  ],
  "items": [
    {
      "title": "提交季度报表",
      "bodyHtml": "…", "bodyMd": "…", "bodyText": "…",
      "status": "todo",
      "startAt": 1762736400, "dueAt": 1762822800,
      "seq": 1000,
      "linkNote": "n1",
      "reminders": [
        {"kind": "offset", "anchor": "start", "offsetMin": 30,
         "notify": {"smtp": {"on": 1, "to": ""}}},
        {"kind": "daily", "daysBefore": 2, "atTime": "09:00",
         "notify": {"webhook": {"on": 1, "url": "…"}}}
      ]
    }
  ],
  "images": { "qnimg-1.png": "<base64>" }
}
```

设计要点：

- **`bodyHtml` 与 `bodyMd` 都给**。只给一个的话，导入端要么丢失富文本细节，要么丢失手写 Markdown 的原貌。
- **`schema` 必须校验**，版本高于本程序支持的就拒绝并提示升级，不要"尽力而为"地导入。
- **`linkNote` 用导出期临时 id**（`n1`），不用真 id——真 id 到另一台机器一定撞。

### 8.2 图片（这是最大的坑）

现有正文里的图片存的是 `file:///C:/.../data/images/xxx.png` **绝对路径**，图片文件在 `data\images\`，不在数据库里。直接导出 `body_html` 到另一台机器，**所有图片全碎**，而且是静默碎。

处理：

1. 导出时扫描 `body_html` 里所有 `file:///.../data/images/*`，读文件、base64 进 `images`，正文改写成 `qnimg://原名`；同一张图被引用多次只存一份。
2. 导入时写回 `data\images\`，生成不冲突的新文件名（原名被占用就加 `-1`），再把 `qnimg://` 换成本机绝对 `file:///`。
3. 图片体积按现有 `PrepImage`（导出用的降采样）先缩一遍，避免一个包几百 MB。
4. 找不到源文件时不阻断导入：保留 `qnimg://` 占位并在导入结果里报「2 张图片缺失」。

### 8.3 关联重映射

- 导出：若事项有关联便签，把该便签正文一并放进 `linkedNotes`（用户可在导出对话框勾掉"包含关联便签"）。
- 导入：先建 `linkedNotes` 拿到新 id，再建事项并按 `exportId → 新 id` 映射。
- 用户选择"不包含关联便签"或目标便签不在包里 → `link_note_id=0`，事项上打「关联已失效」。

### 8.4 导入策略与入口

| 入口 | 行为 |
|---|---|
| 列表页右键 →「导入待办包…」 | 新建一张待办便签并导入全部事项 |
| 待办便签内菜单 →「导入待办包（追加）」 | 追加到当前列表末尾，`seq` 顺延 |
| 待办便签内菜单 →「导入待办包（替换）」 | 清空当前事项后导入，二次确认 |

导入结果用一次性汇总提示：「已导入 12 个事项、4 条提醒；2 张图片缺失」。不做逐条弹窗。

---

## 9. 代码落点

| 文件 | 动作 | 内容 |
|---|---|---|
| `lib/store.ahk` | 改 | `SCHEMA_VERSION=4`；建 3 张表与索引；`_EnsureColumn('notes','kind')`；`Store.Query` 支持 `kind` 过滤；`Create` 接受 `kind` |
| `lib/todo-store.ahk` | 新 | 事项 CRUD、排序（`seq` 中值与重排）、状态流转、`next_fire_at` 重算入口、摘要刷新（同事务） |
| `lib/reminder.ahk` | 新 | 规则 → `next_fire_at`（可注入 `now`）、`TickReminders`、幂等记账、错过判定、outbox 回写 |
| `lib/notify.ahk` | 新 | `--notify` 子进程入口；SMTP / Webhook / Run 三个实现；DPAPI 解密；结果写 outbox |
| `lib/todo-export.ahk` | 新 | `.qntodo` 序列化/反序列化、图片抽取与还原、关联重映射 |
| `lib/note-window.ahk` | 改 | `Navigate` 处按 `note.kind` 选 `note.html` / `todo.html`；菜单按 kind 分叉（待办页隐藏 md 模式、导出改为待办包）；新增待办相关菜单项 |
| `lib/list-window.ahk` | 改 | `Push` 增加 `kind` 与进度字段；右键菜单加两项 |
| `note.ahk` | 改 | `--notify` 在**单实例锁之前**处理；`App.NewTodoNote`；启动 `TickReminders`；托盘加「新建待办便签」；开机自启写/删注册表 |
| `ui/editor-core.js` | 新 | 从 `note.js` 搬出的编辑内核：`paintCodes`、防抖保存、粘贴图片、末尾兜底、字数、`insertTask` |
| `ui/note.js` | 改 | 改为调用 `editor-core`，**行为不变**（这是回归重点） |
| `ui/todo.html` / `todo.css` / `todo.js` | 新 | 待办页 |
| `ui/list.js` / `list.css` | 改 | 类型徽标、类型筛选、进度、新菜单项 |
| `ui/settings.html` / `settings.js` | 改 | 提醒区块、开机自启 |
| `tests/`、`tools/` | 新 | 见 §10 各期验收 |

---

## 10. 分期与验收

每一期都能独立跑通、独立验收，不必等齐。

| 期 | 内容 | 验收（自检名 · 关键断言） |
|---|---|---|
| **P1** 数据与页面 | v4 迁移；事项 CRUD；富文本块；时间；状态与派生逾期；排序；关联；列表分类型 | `--selftest-todo` 30+ 项：老库升 v4 不丢数据、新建事项默认值、`seq` 中值插入、拖动后顺序、勾选写 `done_at`、逾期只在非终态出现、删便签后关联失效不崩、摘要与 `body_text` 同步 |
| **P2** 提醒引擎 | 规则 UI；`next_fire_at`；tick；幂等；错过；托盘提示 | `--selftest-remind`：注入假时钟跑一整天（含跨日、`at_time` 已过、`start_at` 未设、终态停止）；同一 `fire_at` 反复 tick 只产生一条 `todo_fires`；9 分钟前补发、11 分钟前记 `missed`；改系统时间不产生重复 |
| **P3** 投递通道 | run → webhook → smtp；outbox；DPAPI | `--selftest-notify`：`run` 通道执行 `cmd /c echo > 文件` 并校验回执；本地起一个临时 HTTP 服务收 webhook 并断言 JSON 字段；SMTP 只做配置校验与"缺密码时报错不卡住"（真发信手动测） |
| **P4** 导入导出 | `.qntodo` 双向；图片；关联重映射 | `--selftest-todoio`：导出 → 换空数据目录 → 导入 → 逐字段比对（状态/时间/规则/顺序）；图片字节与原文件一致；`schema` 过高时拒绝并给出可读提示 |

**跨期回归**（每次都要跑）：`md.test` 71 条、`--selftest-codecopy`、`--selftest-edit`、`--selftest-rich`、`--selftest-export`、`--selftest-note`、`--selftest-list`。P1 抽 `editor-core` 那次尤其要全绿。

---

## 11. 风险与已知边界

| 风险 | 应对 |
|---|---|
| SMTP 两种 TLS 路线行为不一（CDO 擅长 465，.NET 擅长 587） | 端口分流实现；上线前 QQ / 163 各实测一次，把结论写进 README |
| AHK 伪线程被阻塞会冻住全程序 | 投递一律子进程，主进程不等结果（§6.1） |
| 两个进程同时写 SQLite 撞 `SQLITE_BUSY` | 子进程只写结果文件，主进程回写库（§6.3） |
| 图片是绝对路径，换机必碎 | 导出内嵌 base64 + `qnimg://` 占位（§8.2） |
| `editor-core` 抽取可能改坏现有编辑行为 | 先搬家、先跑全套老自检，绿了再写新页（§2.2） |
| 事项过多时页面卡顿 | 软上限 500；只给可见项着色；整页一次 fragment 插入 |
| 提醒依赖程序在跑 | 「开机自启」开关 + 10 分钟宽限补扫 + 错过汇总，三件一起上 |
| 派生摘要被旧路径覆盖 | `kind='todo'` 时 `SaveBody` / `ImportNote` 直接拒绝并写日志（§3.3） |
| 用户手改系统时间 | 全部绝对时间比较，不做倒计时（§5.6） |

---

## 12. 附录

### 12.1 `config.ini` 新增段

```ini
[smtp]
enabled=1
host=smtp.qq.com
port=465
mode=ssl
user=me@qq.com
from=QuickNote <me@qq.com>
to=me@qq.com
pass_enc=AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA...   ; DPAPI 密文（base64），不存明文
timeout=20

[notify]
maxParallel=4
retry=1

[app]
autostart=0
```

### 12.2 一条提醒的完整生命周期

```
新建事项（status=todo, start=09:00, due=18:00）
  └ 加规则 offset(start, 30)          → next_fire_at = 08:30
    └ tick 在 08:30:02 命中
      └ INSERT todo_fires(sending)    → 唯一索引占位
        └ Run --notify 41             → 主进程立刻返回
          └ 子进程发 SMTP + Webhook   → 写 notify\41.json
            └ 下次 tick 回写 ok       → 规则 last_fired_at=..., enabled=0
              └ UI 显示「已提醒 08:30」
```

### 12.3 已确认的拍板结论（评审时对照）

| # | 议题 | 结论 |
|---|---|---|
| 1 | 状态模型 | 存 4 态 + 派生逾期 |
| 2 | 时间到点是否写库 | 不写库，只改显示 |
| 3 | 错过宽限 | 10 分钟内补发，更早只汇总 |
| 4 | 开机自启 | 加开关，且与漏发补扫并存 |
| 5 | 导出 | 单文件内嵌图片 |
| 6 | 事项归属 | 一个待办便签 = 一个列表，不做跨便签移动 |
| 7 | 打开关联便签 | 点 `↗` 才跳转，点行内是编辑 |

### 12.4 方案里我替你定的默认值（有异议请指出，改起来都不贵）

上面 7 条是你拍过板的。下面这些是写方案时顺手定的，**没有你的明确授权**，列出来供复核：

| # | 默认取舍 | 理由 | 改的代价 |
|---|---|---|---|
| 1 | 时间存 **Unix 秒**（不是毫秒） | 与本项目既有约定一致（`store.ahk` 开头明确了），秒级精度对 5 秒 tick 足够 | 低，但要在 P1 前定，动表结构之后改要迁移 |
| 2 | 待办便签的 `notes.body_*` 是**只读派生**，`SaveBody` / `ImportNote` 在这个类型上直接拒绝 | 否则摘要刷新会把用户内容冲掉 | 中，影响导入入口的设计 |
| 3 | 不做整页 Markdown 模式，只做**单事项**的源码编辑 | 十几个块同时变源码没有使用场景，还会让 `Ctrl+M` 语义含糊 | 低 |
| 4 | 事项删除是**物理删除**，无回收站 | 有二次确认；要找回用导出包 | 中（回收站要加软删列与清理任务） |
| 5 | 提醒失败**只重试 1 次**，且 4xx 不重试 | 反复重试只会刷屏；4xx 是配置错，重试也不会好 | 低 |
| 6 | 事项进入终态后再改回，**不自动复活**已停的提醒 | 自动复活会被当成"关不掉的提醒" | 低 |
| 7 | 单页事项**软上限 500** | 一页几百个 `contenteditable` 会明显卡 | 低 |
| 8 | 待办便签默认窗口 **460×540** | 现有 300×280 塞不下一张卡片 | 低 |
| 9 | 导入时 `schema` 高于本程序支持就**拒绝**，不做"尽力导入" | 半懂不懂地导入比不导入更糟 | 低 |

如果这些都认可，P1 可以直接开工。
