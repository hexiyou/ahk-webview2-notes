#Requires AutoHotkey v2.0
#ErrorStdOut UTF-8
; ============================================================================
;  probe-menu.ahk —— 菜单相关回归测试（不需要 WebView2，跑得很快）
;
;  盯的是两类踩过的坑：
;    1) AHK v2 的菜单回调被调用时会收到 3 个参数（项目名、序号、菜单对象），
;       回调声明得比这少会抛 "Too many parameters passed to function."，
;       界面表现是"菜单弹得出来，点哪项都没反应"。
;    2) 闭包捕获的是变量本身。在 for 循环体里直接建箭头，所有菜单项会一起
;       指向循环结束时的最后一个值（六个颜色全变成同一个）。
;  另外验一下"全部显示"走的是 All() 而不是 Visible()。
; ============================================================================

#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\clip.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk
#Include ..\lib\list-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_menu.log"
    static Log(m) => FileAppend(m "`n", App.LogPath, "UTF-8-RAW")
    static Toast(t) => 0
    static NewNote() => 0
    static ShowList() => 0
    static ZoomFont(step) => 0
    static RenameNote(id) => 0
    static ExportNote(id, fmt) => 0
    static SaveImage(raw, id) => 0
    static SetFontSize(px) => 0
    static RefreshTray() => 0
    static OpenExternal(u) => 0
}

global PassN := 0, FailN := 0
global HookId := 0, HookColorVal := ""

Check(name, cond, detail := "") {
    global PassN, FailN
    if cond {
        PassN++
        App.Log("PASS  " name (detail != "" ? "  [" detail "]" : ""))
    } else {
        FailN++
        App.Log("FAIL  " name (detail != "" ? "  [" detail "]" : ""))
    }
}

if FileExist(App.LogPath)
    FileDelete App.LogPath
App.Log("=== probe-menu 开始 (AHK " A_AhkVersion ")")

; ---------------------------------------------------------------------------
; 1. 菜单回调的参数个数
; ---------------------------------------------------------------------------

class Sink {
    N := 0
    Bump() => this.N += 1
}

s := Sink()

; 裸 ObjBindMethod 被塞 3 个参数 -> 必须抛错（证明这个坑是真的）
raw := "没抛"
try ObjBindMethod(s, "Bump").Call("项目", 1, "菜单")
catch as e
    raw := e.Message
Check("裸回调吃 3 个参数会抛错", raw != "没抛", raw)

; 套一层 NoteWindow.MB 之后必须能吃下 3 个参数，并真的执行到
before := s.N
wrapped := NoteWindow.MB(ObjBindMethod(s, "Bump"))
try wrapped.Call("项目", 1, "菜单")
catch as e
    App.Log("  包装后仍抛错：" e.Message)
Check("MB 包装后能被传 3 个参数", s.N = before + 1, "调用次数 " before " -> " s.N)

; ListWindow.Cb 是同一套逻辑
before := s.N
wrapped2 := ListWindow.Cb(ObjBindMethod(s, "Bump"))
try wrapped2.Call("项目", 2, "菜单")
catch as e
    App.Log("  ListWindow.Cb 抛错：" e.Message)
Check("ListWindow.Cb 包装后能被传 3 个参数", s.N = before + 1, "调用次数 " before " -> " s.N)

; ---------------------------------------------------------------------------
; 2. 循环里的闭包：每个菜单项必须记住自己的参数
; ---------------------------------------------------------------------------

ListWindow.Hooks := Map("onColor", HookOnColor)
HookOnColor(id, c) {
    global HookId, HookColorVal
    HookId := id
    HookColorVal := c
}

a := ListWindow.Cb(ListMenuColor(11, "pink"))
b := ListWindow.Cb(ListMenuColor(22, "blue"))
a.Call("项目", 1, "菜单")
gotA := HookId "," HookColorVal
b.Call("项目", 2, "菜单")
gotB := HookId "," HookColorVal
Check("菜单项各记自己的 id/颜色（第一个）", gotA = "11,pink", gotA)
Check("菜单项各记自己的 id/颜色（第二个）", gotB = "22,blue", gotB)

; ---------------------------------------------------------------------------
; 3. 菜单里用到的动作方法都得存在（改名时能立刻发现）
; ---------------------------------------------------------------------------

for m in ["ShowMenu", "TogglePin", "DoPin", "ApplyPin", "DoColor", "ApplyColor"
    , "CopyAll", "Hide", "Show", "ConfirmDelete", "SendType", "Rename"
    , "ExportAs", "PickImage", "InsertImageFile"]
    Check("NoteWindow 有方法 " m, NoteWindow.Prototype.HasMethod(m))
Check("NoteWindow 有静态方法 MB", NoteWindow.HasMethod("MB"))

for m in ["ShowMenu", "Call", "Cb", "Push", "Open", "Close", "SetTopmost", "ToggleTopmost"]
    Check("ListWindow 有方法 " m, ListWindow.HasMethod(m))
Check("列表窗口置顶状态默认是关", ListWindow.Topmost = 0, ListWindow.Topmost)

; 颜色表要和"显示顺序表"对得上：漏一个就会出现"菜单里少了个颜色"
; 注意别用 HasVal()：这个 AHK 版本没有它，#Warn 会当成未赋值变量弹模态框，
; 整个探针就卡在那儿了（第一次写就踩了）。
cAll := NoteWindow.Colors()
cKeys := NoteWindow.ColorKeys()
missing := ""
for k, _ in cAll {
    hit := 0
    for k2 in cKeys
        if (k2 = k)
            hit := 1
    if !hit
        missing .= " " k
}
badKey := ""
for k in cKeys
    if !cAll.Has(k)
        badKey .= " " k
Check("ColorKeys 覆盖全部颜色", missing = "", missing = "" ? cKeys.Length " 项" : "缺" missing)
Check("ColorKeys 里没有不存在的颜色名", badKey = "", badKey)
Check("颜色个数是 6", cAll.Count = 6, cAll.Count)

; 顶层包装（列表窗口的 Hooks 里放的就是这些函数对象）。note.ahk 不 include
; 进测试（它会直接启动整个程序），所以按源码声明检查。
srcNote := FileRead(A_ScriptDir "\..\note.ahk", "UTF-8")
for f in ["NoteNew", "NoteOpen", "NoteDelete", "NoteHide", "NotePin", "NoteColor"
    , "NoteShowAll", "NoteHideAll", "NoteDataDir", "NoteExport", "NoteShowSettings"]
    Check("顶层包装存在 " f, RegExMatch(srcNote, "(?m)^" f "\(") > 0)

; ---------------------------------------------------------------------------
; 4. 菜单项回调一律要过 MB：源码层面的 lint（这一条专防"新增菜单项忘了包"）
; ---------------------------------------------------------------------------

LintMenuCallbacks(path, label) {
    global PassN, FailN
    txt := FileRead(path, "UTF-8")
    bad := 0
    total := 0
    for line in StrSplit(txt, "`n", "`r") {
        t := Trim(line)
        ; em.Add( 是「导出」子菜单，也属于菜单项，别漏掉
        if !(SubStr(t, 1, 6) = "m.Add(" || SubStr(t, 1, 8) = "sub.Add("
            || SubStr(t, 1, 7) = "em.Add(")
            continue
        need := ""
        if InStr(t, "ObjBindMethod")
            need := "MB("
        else if InStr(t, "ListMenu")
            need := "Cb("
        else
            continue
        total++
        if !InStr(t, need)
            bad++
    }
    Check(label " 的 Add 回调都套了 MB", bad = 0, "检查 " total " 行，未包装 " bad " 行")
}

LintMenuCallbacks(A_ScriptDir "\..\lib\note-window.ahk", "note-window")
LintMenuCallbacks(A_ScriptDir "\..\lib\list-window.ahk", "list-window")

; ---------------------------------------------------------------------------
; 5. 全部显示：All() 必须包含已收起的，Visible() 必须不包含
; ---------------------------------------------------------------------------

dataDir := A_ScriptDir "\..\data"
for f in [dataDir "\_menu.db", dataDir "\_menu.db-wal", dataDir "\_menu.db-shm"]
    if FileExist(f)
        FileDelete f
st := Store(dataDir "\_menu.db")
st.Create(Map("title", "看得见的", "body_text", "a"))
st.Create(Map("title", "收起的", "body_text", "b", "hidden", 1))
Check("All() 含已收起的（2 张）", st.All().Length = 2, "count=" st.All().Length)
Check("Visible() 不含已收起的（1 张）", st.Visible().Length = 1, "count=" st.Visible().Length)
st.Close()

src := srcNote
Check("ShowAll 遍历 Store.All()"
    , RegExMatch(src, "static ShowAll\(\)\s*\{[^}]*Store\.All\(\)") > 0)
Check("ShowAll 不再用 Store.Visible()（会导致收起后再也点不出来）"
    , RegExMatch(src, "static ShowAll\(\)\s*\{[^}]*Store\.Visible\(\)") = 0)

; ---------------------------------------------------------------------------
; 6. 两个页面都挂了右键菜单
; ---------------------------------------------------------------------------

noteJs := FileRead(A_ScriptDir "\..\ui\note.js", "UTF-8")
listJs := FileRead(A_ScriptDir "\..\ui\list.js", "UTF-8")
Check("便签页有 contextmenu → menu", InStr(noteJs, "contextmenu") > 0 && InStr(noteJs, "type: 'menu'") > 0)

; ---------------------------------------------------------------------------
; 6b. 列表窗口的置顶按钮 / 设置页的颜色色块
;     这两处都是"宿主发一个东西、页面照着做"，最容易在改名后悄悄断掉。
; ---------------------------------------------------------------------------

Check("列表页有置顶按钮", InStr(listJs, "btnPin") > 0)
Check("列表页点置顶发 window-topmost", InStr(listJs, "window-topmost") > 0)
Check("列表页会跟着宿主的 topmost 消息刷新按钮", InStr(listJs, "type === 'topmost'") > 0)
Check("列表页 init 里读了置顶状态", InStr(listJs, "setTopmost(msg.topmost)") > 0)

settingsHtml := FileRead(A_ScriptDir "\..\ui\settings.html", "UTF-8")
settingsJs := FileRead(A_ScriptDir "\..\ui\settings.js", "UTF-8")
settingsWin := FileRead(A_ScriptDir "\..\lib\settings-window.ahk", "UTF-8")
Check("设置页有颜色色块容器", InStr(settingsHtml, "id=`"swatches`"") > 0)
Check("设置页按宿主颜色表画色块（不自己抄表）"
    , InStr(settingsJs, "buildSwatches") > 0 && InStr(settingsJs, "cfg.colors") > 0)
Check("设置页保存时带上 defColor", InStr(settingsJs, "defColor: defColor") > 0)
Check("设置窗口按 ColorKeys() 下发颜色表", InStr(settingsWin, "NoteWindow.ColorKeys()") > 0)

; 重命名对话框必须是"能置顶"的那一版，且置顶与否跟着便签/列表走
Check("App 里有可置顶的 AskText", RegExMatch(srcNote, "(?m)^    static AskText\(") > 0)
Check("重命名走 AskText，不再是 InputBox", InStr(srcNote, "App.AskText(") > 0)
Check("置顶判断同时看便签和列表窗口"
    , InStr(srcNote, "note.pinned") > 0 && InStr(srcNote, "ListWindow.Topmost") > 0)

; ---------------------------------------------------------------------------
; 7. 右键菜单分两套：正文给"编辑菜单"，其它地方给"便签菜单"
;    这套东西最容易坏的形态是"跨文件对不上" ——
;    宿主 Cmd("xxx") 发出去，页面 runCmd 里没有对应的 case，点了就是没反应。
;    所以这里把两边都扫一遍，逐条对。
; ---------------------------------------------------------------------------

Check("宿主有 ShowEditMenu", NoteWindow.Prototype.HasMethod("ShowEditMenu"))
Check("宿主有 Cmd 转发", NoteWindow.Prototype.HasMethod("Cmd"))
Check("宿主有 PasteKey（代按 Ctrl+V）", NoteWindow.Prototype.HasMethod("PasteKey"))
Check("宿主有 CodeLangs", NoteWindow.HasMethod("CodeLangs"))

srcWin := FileRead(A_ScriptDir "\..\lib\note-window.ahk", "UTF-8")
Check("页面按落点区分 zone=edit / note"
    , InStr(noteJs, "zone: inText ? 'edit' : 'note'") > 0 || InStr(noteJs, "'edit' : 'note'") > 0)
Check("宿主按 zone 分发菜单", InStr(srcWin, 'this.menuZone = "edit"') > 0)

; 宿主能发出的每一条 cmd，页面必须能接住
pos := 1, cmds := Map()
while RegExMatch(srcWin, 'ObjBindMethod\(this, "Cmd", "([a-z-]+)"', &m, pos) {
    cmds[m[1]] := 1
    pos := m.Pos + m.Len
}
Check("宿主发得出至少 8 条编辑命令", cmds.Count >= 8, "共 " cmds.Count " 条")
for name, _ in cmds {
    has := RegExMatch(noteJs, "case '" name "':") > 0
    Check("页面能接住 cmd：" name, has, has ? "" : "runCmd 里缺 case")
}

; 反过来：页面认识的命令，宿主菜单里也得有入口（save 还有 Ctrl+S，不必在菜单里）
for name in ["undo", "redo", "cut", "copy", "paste", "delete", "select-all"
    , "clear-format", "codeblock", "codelang"]
    Check("编辑菜单里有：" name, cmds.Has(name) || RegExMatch(srcWin, '"Cmd", "' name '"') > 0)

; 两张语言表必须一致：宿主画菜单、页面调 highlight.js，对不上就会出现
; "选了 Python 但没反应"
langsAhk := NoteWindow.CodeLangs()
hlJs := FileRead(A_ScriptDir "\..\ui\code-hl.js", "UTF-8")
badLang := ""
for k, v in langsAhk {
    ; ui\code-hl.js 里的写法是 ['javascript', 'JavaScript']
    if !InStr(hlJs, "['" k "', '" v "']")
        badLang .= (badLang = "" ? "" : ",") (k = "" ? "(空)" : k)
}
Check("代码语言表和 ui\code-hl.js 一致", badLang = "", badLang = "" ? langsAhk.Count " 项" : "对不上：" badLang)
Check("宿主语言表覆盖常见语言", langsAhk.Count >= 15, langsAhk.Count " 项")

Check("列表页有 contextmenu → menu", InStr(listJs, "contextmenu") > 0 && InStr(listJs, "type: 'menu'") > 0)
Check("便签页处理宿主下发的 pin", InStr(noteJs, "case 'pin'") > 0)

; ---------------------------------------------------------------------------
; 8. 双击标题栏最大化：三处必须对上
;     页面发 toggle-max → 宿主收 → SetMax 改窗口 → 回 "max" 给页面。
;     中间断一环，表现就是"双击没反应"或"放大了但拖不动/停不下来"。
; ---------------------------------------------------------------------------

Check("宿主有 ToggleMax", NoteWindow.Prototype.HasMethod("ToggleMax"))
Check("宿主有 SetMax", NoteWindow.Prototype.HasMethod("SetMax"))
Check("宿主收得到 toggle-max", InStr(srcWin, 'case "toggle-max"') > 0)
Check("宿主把状态回给页面", InStr(srcWin, '"type":"max"') > 0)
Check("页面接得住 max 消息", InStr(noteJs, "case 'max'") > 0)
Check("页面会发 toggle-max", InStr(noteJs, "'toggle-max'") > 0)
Check("页面自己数双击（不依赖 dblclick 事件）"
    , InStr(noteJs, "DBL_MS") > 0 && !RegExMatch(noteJs, "addEventListener\(\s*'dblclick'"))
Check("最大化时页面不再发 drag-start / resize-start"
    , InStr(noteJs, "if (state.maxed) return;") > 0)
Check("最大化时不写库（否则开机满屏）"
    , RegExMatch(srcWin, "SaveGeometryNow\(\)\s*\{[^}]*this\.maximized\s*[\r\n]+\s*return") > 0)
Check("最大化用当前显示器的工作区", InStr(srcWin, "Win.WorkAreaOf(") > 0)
Check("Win 有 WorkAreaOf", Win.HasMethod("WorkAreaOf"))
wa := Win.WorkAreaOf(0)
Check("WorkAreaOf(0) 退化成主屏工作区", wa.w > 200 && wa.h > 200, wa.w "x" wa.h)

; ---------------------------------------------------------------------------
; 9. 图片右键菜单：复制图片 / 另存为
;    剪贴板那一段要真跑一遍得往剪贴板里塞东西（污染用户的剪贴板、还要 GDI+），
;    这里只验零件齐不齐、路径往返对不对；端到端在 note.ahk --selftest-image。
; ---------------------------------------------------------------------------

Check("宿主有 ShowImageMenu", NoteWindow.Prototype.HasMethod("ShowImageMenu"))
for m in ["CopyImage", "SaveImageAs", "CopyImagePath", "RevealImage", "DeleteImage", "Hint"]
    Check("NoteWindow 有方法 " m, NoteWindow.Prototype.HasMethod(m))
for m in ["ImageLocalPath", "UrlToPath", "CopyImageFile"]
    Check("NoteWindow 有静态方法 " m, NoteWindow.HasMethod(m))

hasClip := 0
try hasClip := Clip.HasMethod("SetImageFile") ? 1 : 0
Check("Clip 能把图片写进剪贴板", hasClip = 1)
Check("宿主按 zone=image 分发菜单", InStr(srcWin, 'this.menuZone = "image"') > 0)
Check("宿主收得到 copy-image（看图时 Ctrl+C）", InStr(srcWin, 'case "copy-image"') > 0)
Check("页面有图片菜单 zone", InStr(noteJs, "zone: 'image'") > 0)
Check("大图预览里右键先判图片（不然会落到便签菜单）"
    , InStr(noteJs, "if (!lightbox.hidden)") > 0)
Check("页面会发 copy-image", InStr(noteJs, "type: 'copy-image'") > 0)
Check("页面能接住 delete-image", InStr(noteJs, "case 'delete-image':") > 0)

imgProbe := A_ScriptDir "\..\data\_图片 测试.png"
if FileExist(imgProbe)
    FileDelete imgProbe
FileAppend "x", imgProbe, "UTF-8-RAW"
probeUrl := NoteWindow.FileUrl(imgProbe)
back := NoteWindow.ImageLocalPath(probeUrl)
Check("file:/// 还原成本地路径（中文 + 空格）", back = imgProbe, back)
encUrl := StrReplace(probeUrl, "图片", "%E5%9B%BE%E7%89%87")
back2 := NoteWindow.ImageLocalPath(encUrl)
Check("百分号编码过的中文也能还原", back2 = imgProbe, back2)
Check("网络图片不当成本地文件", NoteWindow.ImageLocalPath("https://a/b.png") = "")
Check("空 src 返回空", NoteWindow.ImageLocalPath("") = "")

saveProbe := A_ScriptDir "\..\data\_另存 测试.png"
for f in [saveProbe, A_ScriptDir "\..\data\_另存 2"]
    if FileExist(f)
        FileDelete f
saved := NoteWindow.CopyImageFile(imgProbe, saveProbe)
Check("另存为真的把文件拷过去", saved = saveProbe && FileExist(saveProbe), saved)
noext := A_ScriptDir "\..\data\_另存 2"
saved2 := NoteWindow.CopyImageFile(imgProbe, noext)
Check("另存为会自动补扩展名", saved2 = noext ".png" && FileExist(noext ".png"), saved2)
Check("源文件不在时另存为失败而不是抛异常"
    , NoteWindow.CopyImageFile(A_ScriptDir "\..\data\_没有这个.png", saveProbe) = "")
for f in [imgProbe, saveProbe, noext ".png"]
    if FileExist(f)
        FileDelete f

; 图片菜单里"文件找不到就灰掉"用到 Menu.Disable。它认的是 Add 时的**完整名字**
; （`t + 加速键文本），只写显示名会抛 "Nonexistent menu item." —— 被 try 吞掉后
; 表现是"该灰的没灰"，点了才提示。这条断言把规则钉住。
mm := Menu()
mm.Add("甲`tCtrl+1", (*) => 0)
byName := 0, byFull := 0
try {
    mm.Disable("甲")
    byName := 1
}
try {
    mm.Disable("甲`tCtrl+1")
    byFull := 1
}
Check("Menu.Disable 必须传带加速键的完整名字"
    , byName = 0 && byFull = 1, "显示名=" byName " 完整串=" byFull)

; ---------------------------------------------------------------------------
; 10. 代码块右上角的「复制」按钮
;     这里只钉住"位置和接线"这几条容易改坏的地方：
;       · 按钮必须在 #editor 外面（进去就会被当成正文存进库）
;       · 按钮不能在 <pre> 里（进去就会被着色重绘冲掉）
;       · 点击发 clipboard-set，宿主用 Clip.SetText 写（顺带换 CRLF）
;     端到端（位置、剪贴板内容、回执、收起）在 note.ahk --selftest-codecopy。
; ---------------------------------------------------------------------------

noteHtml := FileRead(A_ScriptDir "\..\ui\note.html", "UTF-8")
Check("页面有代码复制按钮", InStr(noteHtml, "id=`"codeCopy`"") > 0)
iEd := InStr(noteHtml, "id=`"editor`"")
iBtn := InStr(noteHtml, "id=`"codeCopy`"")
Check("按钮在 #editor 之后（不在编辑区里）"
    , iEd > 0 && iBtn > iEd, "editor=" iEd " btn=" iBtn)
Check("按钮是 #editor 的兄弟节点，不在 <pre> 里"
    , RegExMatch(noteHtml, "(?s)<div[^>]*id=`"editor`".*?</main>.*id=`"codeCopy`"") > 0)
Check("页面点按钮发 clipboard-set", InStr(noteJs, "type: 'clipboard-set'") > 0)
Check("页面能接住 copy-code（右键菜单那条路）", InStr(noteJs, "case 'copy-code':") > 0)
Check("宿主有「复制这段代码」菜单项", InStr(srcWin, "复制这段代码") > 0)
Check("宿主用 Clip.SetText 写文字剪贴板"
    , InStr(srcWin, "Clip.SetText(") > 0 && Clip.HasMethod("SetText"))
Check("页面鼠标移开就收起（有 200ms 缓冲）"
    , InStr(noteJs, "hideCodeCopySoon") > 0 && InStr(noteJs, "200") > 0)

/* Clip.SetText 的 CRLF 转换是"记事本里不挤成一行"的前提，直接验一遍。
   测完把剪贴板还原，别动用户的东西。 */
oldText := ""
try oldText := A_Clipboard
okSet := Clip.SetText("甲`n乙")
gotLf := ""
try gotLf := A_Clipboard
Check("Clip.SetText 把 LF 换成 CRLF"
    , okSet = 1 && gotLf = "甲`r`n乙", StrLen(gotLf))
okSet2 := Clip.SetText("甲`r`n乙")
gotCrlf := ""
try gotCrlf := A_Clipboard
Check("Clip.SetText 不会把 CRLF 变成 CRCRLF"
    , okSet2 = 1 && gotCrlf = gotLf, StrLen(gotCrlf))
Check("Clip.SetText 空串不写剪贴板", Clip.SetText("") = 0)
try A_Clipboard := oldText

App.Log("=== 结束：PASS " PassN " / FAIL " FailN)
Sleep 150
ExitApp FailN ? 1 : 0
