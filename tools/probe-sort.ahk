#Requires AutoHotkey v2.0
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

; ---- 收尾 ----------------------------------------------------------------
st.Close()
for f in [dbp, dbp "-wal", dbp "-shm"]
    if FileExist(f)
        try FileDelete f

W("")
W("=== 汇总 PASS " PASS "  FAIL " FAIL " ===")
ExitApp FAIL ? 1 : 0
