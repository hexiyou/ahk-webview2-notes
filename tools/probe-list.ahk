#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
#Include ..\lib\json.ahk
#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk
#Include ..\lib\win.ahk
#Include ..\lib\WebView2\WebView2.ahk
#Include ..\lib\note-window.ahk
#Include ..\lib\list-window.ahk

class App {
    static LogPath := A_ScriptDir "\..\data\_list.log"
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
    ; 列表窗口要读/写 config.ini（置顶偏好），测试里用内存版的够用了
    static CfgStore := Map()
    static Cfg(sec, key, def) {
        k := sec "." key
        return App.CfgStore.Has(k) ? App.CfgStore[k] : def
    }
    static SetCfg(sec, key, val) => App.CfgStore[sec "." key] := val
}

global PassN := 0, FailN := 0
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

; "3,2,1" -> "1,2,3"。批量操作的断言只关心集合，不关心顺序。
SortedIds(csv) {
    out := []
    for part in StrSplit(csv, ",") {
        p := Trim(part)
        if (p != "")
            out.Push(Integer(p))
    }
    ; 元素不多（测试里最多三条），冒泡足够，不引排序库
    loop out.Length {
        i := A_Index
        loop out.Length - i {
            if (out[A_Index] > out[A_Index + 1]) {
                t := out[A_Index]
                out[A_Index] := out[A_Index + 1]
                out[A_Index + 1] := t
            }
        }
    }
    s := ""
    for v in out
        s .= (s = "" ? "" : ",") v
    return s
}

if FileExist(App.LogPath)
    FileDelete App.LogPath
try DllCall("user32\SetProcessDpiAwarenessContext", "ptr", -4)

dataDir := A_ScriptDir "\..\data"
for f in [dataDir "\_list.db", dataDir "\_list.db-wal", dataDir "\_list.db-shm"]
    if FileExist(f)
        FileDelete f

st := Store(dataDir "\_list.db")
id1 := st.Create(Map("title", "买菜", "body_text", "鸡蛋 牛奶 面包", "color", "yellow"))
id2 := st.Create(Map("title", "工作周报", "body_text", "本周完成了搜索功能", "color", "blue", "pinned", 1))
id3 := st.Create(Map("title", "已收起的", "body_text", "后台维护任务", "color", "gray", "hidden", 1))
App.Log("=== probe-list 开始，三条 id=" id1 "," id2 "," id3)

openId := 0
ListWindow.Store := st
ListWindow.Ctx := {
    uiDir: A_ScriptDir "\..\ui",
    dllPath: A_ScriptDir "\..\lib\WebView2Loader.dll",
    dataDir: dataDir "\webview2",
    imagesDir: dataDir "\images",
    devtools: 0,
    appearance: { transparent: 0, fontSize: 15, drag: "native" }
}
ListWindow.Hooks := Map(
    "onNew", NoteHookNew,
    "onOpen", NoteHookOpen,
    "onDelete", NoteHookDelete,
    "onHide", NoteHookHide,
    "onBatch", NoteHookBatch,
    "onClose", NoteHookClose)
NoteHookNew() => App.Log("hook:new")
NoteHookClose() => App.Log("hook:close")
NoteHookOpen(id) {
    global openId
    openId := id
    App.Log("hook:open " id)
}
NoteHookDelete(id) => App.Log("hook:delete " id)
NoteHookHide(id) => App.Log("hook:hide " id)

; 批量操作钩子：页面点批量按钮 → onBatch(action, ids, arg)。
; ids 拼成 "1,2" 方便断言，顺便确认参数顺序没接错。
batchAction := "", batchIds := "", batchArg := ""
NoteHookBatch(action, ids, arg := "") {
    global batchAction, batchIds, batchArg
    batchAction := action
    s := ""
    for i, id in ids
        s .= (i > 1 ? "," : "") id
    batchIds := s
    batchArg := arg
    App.Log("hook:batch " action " [" s "] arg=" arg)
}

ListWindow.Open()
App.Log("Open 返回，Win=" (ListWindow.Win ? "ok" : "null"))
Sleep 1600
App.Log("等待结束，Win=" (ListWindow.Win ? "ok" : "null"))

if !ListWindow.Win {
    App.Log("Win 为空，中止")
    ExitApp
}
cnt := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("列表渲染 3 条", cnt = "3", "count=" cnt)

first := ListWindow.Win.wv.ExecuteScript("document.querySelector('#list .item .name').textContent")
Check("第一条是置顶的工作周报", first = '"工作周报"', first)

badge := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .badge').length")
Check("已收起有标记", badge = "1", "badge=" badge)

pin := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .pin').length")
Check("置顶有标记", pin = "1", "pin=" pin)

cntText := ListWindow.Win.wv.ExecuteScript("document.getElementById('count').textContent")
Check("底部计数正确", InStr(cntText, "3") > 0, cntText)

; 搜索走宿主 SQL
ListWindow.Push("面包")
Sleep 500
cnt2 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("搜面包命中 1 条", cnt2 = "1", "count=" cnt2)

ListWindow.Push("后台维护")
Sleep 500
cnt3 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("能搜到已收起的", cnt3 = "1", "count=" cnt3)

ListWindow.Push("")
Sleep 400
cnt4 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("清空关键字回到 3 条", cnt4 = "3", "count=" cnt4)

; 点击第一行应回调 onOpen
ListWindow.Win.wv.ExecuteScript("document.querySelector('#list .item').click();1")
Sleep 400
Check("点击回调 onOpen", openId != 0, "id=" openId)

; 点删除按钮应回调 onDelete
ListWindow.Win.wv.ExecuteScript("document.querySelector('#list .item .ops button.del').click();1")
Sleep 400
Check("删除按钮回调", InStr(FileRead(App.LogPath, "UTF-8"), "hook:delete") > 0)

; ---- 窗口置顶：按钮 → 宿主改窗口 → 回消息点亮按钮 -----------------------
hwnd := ListWindow.Win.gui.Hwnd
on0 := ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').classList.contains('on')")
Check("置顶按钮初始是熄的", on0 = "false", on0)
Check("初始窗口不带 WS_EX_TOPMOST", (WinGetExStyle("ahk_id " hwnd) & 0x8) = 0
    , WinGetExStyle("ahk_id " hwnd))

ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').click();1")
Sleep 700
Check("点图钉后窗口真的置顶了", (WinGetExStyle("ahk_id " hwnd) & 0x8) ? 1 : 0
    , WinGetExStyle("ahk_id " hwnd))
on1 := ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').classList.contains('on')")
Check("按钮跟着点亮", on1 = "true", on1)
Check("置顶偏好写进了配置", App.Cfg("window", "listTopmost", 0) ? 1 : 0,
    App.Cfg("window", "listTopmost", "?"))

ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').click();1")
Sleep 700
Check("再点一次取消置顶", (WinGetExStyle("ahk_id " hwnd) & 0x8) = 0
    , WinGetExStyle("ahk_id " hwnd))
on2 := ListWindow.Win.wv.ExecuteScript("document.getElementById('btnPin').classList.contains('on')")
Check("按钮跟着熄掉", on2 = "false", on2)

; ---- 排序：控件在、点了能改宿主状态、列表顺序真的跟着变 -------------------
optN := ListWindow.Win.wv.ExecuteScript(
    "document.querySelectorAll('#sortSel option').length")
Check("排序下拉有 7 个选项", optN = "7", optN)

; 标题升序：买菜(1) < 工作周报(2) < 已收起的(3)（按码位）
ListWindow.Win.wv.ExecuteScript(
    "var s=document.getElementById('sortSel');s.value='title:asc';"
    . "s.dispatchEvent(new Event('change'));1")
Sleep 500
Check("页面改排序 → 宿主记下了", ListWindow.SortKey = "title" && ListWindow.SortDesc = 0
    , ListWindow.SortKey " / " ListWindow.SortDesc)
names := ListWindow.Win.wv.ExecuteScript(
    "Array.from(document.querySelectorAll('#list .item .name')).map(e=>e.textContent).join('|')")
Check("标题升序生效", InStr(names, "买菜") > 0 && InStr(names, "买菜") < InStr(names, "工作周报")
    , names)
Check("排序写进了配置", InStr(App.Cfg("window", "listSort", ""), "title:asc") > 0
    , App.Cfg("window", "listSort", ""))

ListWindow.Win.wv.ExecuteScript(
    "var s=document.getElementById('sortSel');s.value='title:desc';"
    . "s.dispatchEvent(new Event('change'));1")
Sleep 500
Check("标题倒序生效", ListWindow.SortDesc = 1, ListWindow.SortDesc)

; ---- 过滤：条件生效 + 徽标数字 + 清空 -------------------------------------
ListWindow.ApplyFilter("shown", 0)     ; 只看已收起的
Sleep 400
cntF := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("过滤『已收起』只剩 1 条", cntF = "1", cntF)
badge := ListWindow.Win.wv.ExecuteScript("document.getElementById('fCount').textContent")
Check("过滤徽标显示 1", badge = '"1"', badge)
clearShown := ListWindow.Win.wv.ExecuteScript(
    "document.getElementById('btnClearFilter').hidden")
Check("『清空』按钮露出来了", clearShown = "false", clearShown)
Check("过滤条件写进了配置", InStr(App.Cfg("window", "listFilter", ""), "shown=0") > 0
    , App.Cfg("window", "listFilter", ""))

ListWindow.ApplyClearFilter()
Sleep 400
cntF2 := ListWindow.Win.wv.ExecuteScript("document.querySelectorAll('#list .item').length")
Check("清空过滤恢复 3 条", cntF2 = "3", cntF2)
badge2 := ListWindow.Win.wv.ExecuteScript("document.getElementById('fCount').hidden")
Check("徽标跟着藏起来", badge2 = "true", badge2)
/* 光看 hidden 属性不够：.fcount 有 display:inline-grid，类选择器会盖掉浏览器
   默认的 [hidden]{display:none}，属性是 true、屏幕上照样显示一个"0"。
   所以要看计算样式。 */
badgeCss := ListWindow.Win.wv.ExecuteScript(
    "getComputedStyle(document.getElementById('fCount')).display")
Check("徽标真的不占位（计算样式 display=none）", badgeCss = '"none"', badgeCss)
clearCss := ListWindow.Win.wv.ExecuteScript(
    "getComputedStyle(document.getElementById('btnClearFilter')).display")
Check("「清空」也真的不占位", clearCss = '"none"', clearCss)

; ---- 勾选 / 全选 / 批量条 -------------------------------------------------
chkN := ListWindow.Win.wv.ExecuteScript(
    "document.querySelectorAll('#list .item input.rowchk').length")
Check("每行都有复选框", chkN = "3", chkN)

ListWindow.Win.wv.ExecuteScript(
    "document.querySelectorAll('#list .item input.rowchk')[0].click();1")
Sleep 300
sel1 := ListWindow.Win.wv.ExecuteScript("document.getElementById('selN').textContent")
Check("勾一条 → 已选 1", sel1 = '"1"', sel1)
barShown := ListWindow.Win.wv.ExecuteScript("document.getElementById('selbar').hidden")
Check("批量条出现了", barShown = "false", barShown)

ListWindow.Win.wv.ExecuteScript("document.getElementById('chkAll').click();1")
Sleep 300
selAll := ListWindow.Win.wv.ExecuteScript("document.getElementById('selN').textContent")
Check("全选 → 已选 3", selAll = '"3"', selAll)
pinLabel := ListWindow.Win.wv.ExecuteScript("document.getElementById('actPin').textContent")
Check("选中项里有没置顶的 → 按钮显示『置顶』", pinLabel = '"置顶"', pinLabel)

; 批量置顶：页面发 batch，宿主 → 钩子。参数顺序 action, ids, on
batchAction := ""
ListWindow.Win.wv.ExecuteScript("document.getElementById('actPin').click();1")
Sleep 500
Check("批量置顶回调 action", batchAction = "pin", batchAction)
; id 的顺序跟着当前列表顺序走（这时是按标题倒序，所以是 3,2,1）。
; 批量操作的语义和顺序无关，断言只该比集合。
Check("批量置顶带回 3 个 id", SortedIds(batchIds) = "1,2,3", batchIds)
Check("批量置顶 on=1", batchArg = 1, batchArg)

; 清空选择后只剩一张被勾选，删除按钮走的是同一条路（二次确认在真实 App 里）
ListWindow.Win.wv.ExecuteScript("document.getElementById('btnSelClear').click();1")
Sleep 300
sel0 := ListWindow.Win.wv.ExecuteScript("document.getElementById('selN').textContent")
Check("清除选择回到 0", sel0 = '"0"', sel0)
barHidden := ListWindow.Win.wv.ExecuteScript("document.getElementById('selbar').hidden")
Check("批量条收起来", barHidden = "true", barHidden)

; 批量菜单（颜色/透明度/导出）走 batch-menu，宿主弹原生菜单，不进钩子
ListWindow.Win.wv.ExecuteScript(
    "document.querySelectorAll('#list .item input.rowchk')[1].click();1")
Sleep 300
ListWindow.Win.wv.ExecuteScript(
    "document.querySelector('.selacts button[data-act=delete]').click();1")
Sleep 500
Check("批量删除也走 onBatch(delete)", batchAction = "delete", batchAction)
Check("删除只带被勾的那一条", batchIds = "2", batchIds)

ListWindow.Close()
Sleep 300
Check("关闭后 Win=0", !ListWindow.IsOpen())

st.Close()
App.Log("=== 结束：PASS " PassN " / FAIL " FailN)
Sleep 200
ExitApp
