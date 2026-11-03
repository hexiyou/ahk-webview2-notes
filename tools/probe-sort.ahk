#Requires AutoHotkey v2.0
; 警告不要弹模态框：本目录的脚本常在无人值守下跑，一个框就能把整轮测试挂死。
; 只把"变量没赋值"（= 漏了某个 #Include）放到 stdout，其余类型丢给调试器。
#Warn VarUnset, StdOut
#Warn LocalSameAsGlobal, OutputDebug
#Warn Unreachable, OutputDebug
#ErrorStdOut UTF-8
; ============================================================================
;  probe-sort.ahk —— 列表顺序必须"稳定"
;
;  用户报的问题：列表里有好几张便签时，点开其中一张，顺序就乱跳。
;  根因是列表按 updated_at DESC 排，而"打开/编辑/改显示状态"都会把 updated_at
;  刷新，于是被点的那张就窜到最前面。
;
;  这里直接对数据层断言：无论怎么编辑/打开，All() 的顺序都不能变；
;  只有"置顶"允许改变顺序（置顶本来就是要排前面）。
; ============================================================================

#Include ..\lib\sqlite.ahk
#Include ..\lib\store.ahk

logPath := A_ScriptDir "\..\data\_sort.log"
if FileExist(logPath)
    FileDelete logPath

PASS := 0
FAIL := 0

W(s) => FileAppend(s "`n", logPath, "UTF-8-RAW")

Chk(name, got, want) {
    global PASS, FAIL
    if (got = want) {
        PASS++
        W("PASS  " name "  = " got)
    } else {
        FAIL++
        W("FAIL  " name "  got=" got " want=" want)
    }
}

; 把 id 列表拼成 "4,3,2,1" 方便比较
Ids(rows) {
    s := ""
    for i, n in rows
        s .= (i > 1 ? "," : "") n.id
    return s
}

dbp := A_ScriptDir "\..\data\_sort.db"
for f in [dbp, dbp "-wal", dbp "-shm"]
    if FileExist(f)
        FileDelete f

st := Store(dbp)

; 建 4 张，created_at 拉开（Create 只会给"现在"，所以建完直接改）
made := []
loop 4
    made.Push(st.Create(Map("title", "便签" A_Index, "body_text", "内容" A_Index)))
for i, id in made
    st.db.Run("UPDATE notes SET created_at=? WHERE id=?", 1000 * i, id)
W("建了 4 张：" Ids(st.All()))

; 新建的在前
Chk("初始顺序（新建的在前）", Ids(st.All()), "4,3,2,1")

; ---- 模拟"打开 / 编辑 / 改显示状态"，顺序必须不动 -------------------------
before := Ids(st.All())
st.SaveBody(2, "便签2（改过）", "<p>改</p>", "改", "改", "rich")   ; 编辑正文
st.SetHidden(2, 0)                                             ; 打开时复位 hidden
st.Touch(2)                                                    ; 打开时提到最近用过
st.Touch(3)
Sleep 1100                                                     ; 让 updated_at 真的变了
st.SaveBody(3, "便签3（又改）", "<p>再改</p>", "再改", "再改", "rich")
upd2 := st.db.Scalar("SELECT updated_at FROM notes WHERE id=2")
Chk("updated_at 确实被刷新过（测试才有意义）", upd2 > 1000 ? 1 : 0, 1)
Chk("编辑/打开之后顺序不变", Ids(st.All()), before)

; ---- 搜索结果的顺序同样要稳定 ---------------------------------------------
Chk("SearchAll 空词 顺序不变", Ids(st.SearchAll("")), before)
Chk("SearchAll 命中全部 顺序不变", Ids(st.SearchAll("便签")), before)

; ---- 置顶可以改变顺序（这是用户主动的） -----------------------------------
st.SetPinned(1, 1)
Chk("置顶后排最前", Ids(st.All()), "1,4,3,2")
Chk("置顶后搜索也排最前", Ids(st.SearchAll("便签")), "1,4,3,2")
st.SetPinned(1, 0)
Chk("取消置顶后恢复", Ids(st.All()), before)

; ---- 收起的（hidden=1）不能混进 Visible，但 All 里要在 ---------------------
st.SetHidden(4, 1)
Chk("Visible 排除已收起", Ids(st.Visible()), "3,2,1")
Chk("All 仍含已收起", Ids(st.All()), before)
st.SetHidden(4, 0)

; ============================================================================
;  Store.Query：排序 + 过滤（列表窗口的"排序方式""按条件过滤"全走它）
;
;  这里把时间戳和各种标记都改成已知值，断言就只依赖自己设的东西，
;  不会因为"跑得慢一点"就换一个结果。
; ============================================================================
for i, id in made
    st.db.Run("UPDATE notes SET created_at=?, updated_at=? WHERE id=?"
        , 1000 * i, 5000 - 100 * i, id)
; 标题故意打乱：a=3 b=1 c=4 d=2，这样"按标题"和"按时间"一定不同
titles := Map(1, "b", 2, "d", 3, "a", 4, "c")
for id, t in titles
    st.SetTitle(id, t)

Chk("Query 默认序 = All()", Ids(st.Query()), Ids(st.All()))
Chk("标题正序", Ids(st.Query("", "title", 0)), "3,1,4,2")
Chk("标题倒序", Ids(st.Query("", "title", 1)), "2,4,1,3")
Chk("创建时间正序", Ids(st.Query("", "created", 0)), "1,2,3,4")
Chk("创建时间倒序", Ids(st.Query("", "created", 1)), "4,3,2,1")
Chk("更新时间正序", Ids(st.Query("", "updated", 0)), "4,3,2,1")
Chk("更新时间倒序", Ids(st.Query("", "updated", 1)), "1,2,3,4")
Chk("未知排序名退回默认", Ids(st.Query("", "bogus", 1)), Ids(st.All()))

; 构造过滤条件用得到的状态：
;   id1 置顶 + 快捷键 + 有图 + 有代码
;   id2 什么都没有，只是显示着
;   id3 快捷键 + 有图 + 已收起
;   id4 置顶 + 有代码
st.SetPinned(1, 1)
st.SetPinned(4, 1)
st.SetHotkey(1, "^!1")
st.SetHotkey(3, "^!2")
st.SetHidden(3, 1)
st.db.Run("UPDATE notes SET body_html=? WHERE id=?", '<p>x</p><img src="a.png"><pre>y</pre>', 1)
st.db.Run("UPDATE notes SET body_html=? WHERE id=?", '<p>x</p><img src="b.png">', 3)
st.db.Run("UPDATE notes SET body_html=? WHERE id=?", '<pre>z</pre>', 4)

Chk("过滤：有快捷键", Ids(st.Query("", "default", 1, Map("hotkey", 1))), "1,3")
Chk("过滤：没快捷键", Ids(st.Query("", "default", 1, Map("hotkey", 0))), "4,2")
Chk("过滤：已置顶", Ids(st.Query("", "default", 1, Map("pinned", 1))), "4,1")
Chk("过滤：未置顶", Ids(st.Query("", "default", 1, Map("pinned", 0))), "3,2")
Chk("过滤：已展开", Ids(st.Query("", "default", 1, Map("shown", 1))), "4,1,2")
Chk("过滤：已收起", Ids(st.Query("", "default", 1, Map("shown", 0))), "3")
Chk("过滤：含图片", Ids(st.Query("", "default", 1, Map("image", 1))), "1,3")
Chk("过滤：不含图片", Ids(st.Query("", "default", 1, Map("image", 0))), "4,2")
Chk("过滤：含代码块", Ids(st.Query("", "default", 1, Map("code", 1))), "4,1")
Chk("过滤：不含代码块", Ids(st.Query("", "default", 1, Map("code", 0))), "3,2")
Chk("过滤：多条件 AND（置顶+含图）", Ids(st.Query("", "default", 1, Map("pinned", 1, "image", 1))), "1")
Chk("过滤：-1 视为不限", Ids(st.Query("", "default", 1, Map("pinned", -1))), Ids(st.All()))
; 关键字"内容"只剩 1、4 两张（2、3 的正文在上一段测试里被改成了"改/再改"）
Chk("过滤 + 关键字叠加", Ids(st.Query("内容", "default", 1, Map("shown", 1))), "4,1")
; 含图片的是 1、3；按标题排（a 是 3，b 是 1）
Chk("过滤 + 排序串起来", Ids(st.Query("", "title", 0, Map("image", 1))), "3,1")
Chk("过滤后什么都没有", Ids(st.Query("", "default", 1, Map("shown", 0, "image", 0))), "")

; ---- 收尾 ----------------------------------------------------------------
st.Close()
for f in [dbp, dbp "-wal", dbp "-shm"]
    if FileExist(f)
        try FileDelete f

W("")
W("=== 汇总 PASS " PASS "  FAIL " FAIL " ===")
ExitApp FAIL ? 1 : 0
