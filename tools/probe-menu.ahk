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

for m in ["ShowMenu", "Call", "Cb", "Push", "Open", "Close"]
    Check("ListWindow 有方法 " m, ListWindow.HasMethod(m))

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

App.Log("=== 结束：PASS " PassN " / FAIL " FailN)
Sleep 150
ExitApp FailN ? 1 : 0
