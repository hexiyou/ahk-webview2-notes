#!/usr/bin/env bash
# 跑一批自检，输出每条的核心结论行。DATA 用独立目录，绝不碰用户库。
# 用法：bash tools/_run-st.sh [标签...]
set -u
cd "$(dirname "$0")/.." || exit 1
AHK="runtime/AutoHotkey64.exe"
DATA="$(pwd)/data/_st"
LOG="$DATA/app.log"
mkdir -p "$DATA"

run_one() {
  local tag="$1" logpref="$2" args="$3"
  : > "$LOG"
  # shellcheck disable=SC2086
  "$AHK" note.ahk --data-dir "$DATA" $args >/dev/null 2>&1
  # 退出码要单独看：进程在收尾阶段崩（0xC0000005 / 0xC000041D）时，
  # 自检结论行照样是"通过"，只有退出码会露出来。
  local rc=$?
  local fails passes concl
  fails=$(grep -c '^.*  FAIL ' "$LOG" 2>/dev/null || true)
  passes=$(grep -c '^.*  PASS ' "$LOG" 2>/dev/null || true)
  concl=$(grep -o 'SELFTEST [A-Z]* 结论：.*' "$LOG" 2>/dev/null | tail -1)
  if [ -z "$concl" ]; then
    concl=$(grep -o 'SELFTEST.*结论.*' "$LOG" 2>/dev/null | tail -1)
  fi
  local rctxt="rc=$rc"
  case "$rc" in
    0)              rctxt="rc=0" ;;
    3221225477)     rctxt="rc=0xC0000005 访问违例" ;;
    3221225597)     rctxt="rc=0xC000041D 用户回调致命异常" ;;
  esac
  printf '%-22s PASS=%-4s FAIL=%-3s %-28s %s\n' "$tag" "${passes:-0}" "${fails:-0}" "$rctxt" "${concl:-(无结论行)}"
  if [ "${fails:-0}" != "0" ]; then
    grep 'FAIL ' "$LOG" | sed 's/^/    /'
  fi
}

for t in "$@"; do
  case "$t" in
    rich)      run_one rich      rich      "--selftest-rich" ;;
    edit)      run_one edit      edit      "--selftest-edit" ;;
    codelang)  run_one codelang  codelang  "--selftest-codelang" ;;
    codecopy)  run_one codecopy  codecopy  "--selftest-codecopy" ;;
    note)      run_one note      note      "--selftest-note" ;;
    import)    run_one import    import    "--selftest-import" ;;
    export)    run_one export    export    "--selftest-export" ;;
    list)      run_one list      list      "--selftest-list" ;;
    del)       run_one del       del       "--selftest-del" ;;
    image)     run_one image     image     "--selftest-image" ;;
    batch)     run_one batch     batch     "--selftest-batch" ;;
    font)      run_one font      font      "--selftest-font" ;;
    hotkey)    run_one hotkey    hotkey    "--selftest-hotkey" ;;
    opacity)   run_one opacity   opacity   "--selftest-opacity" ;;
    showall)   run_one showall   showall   "--selftest-showall" ;;
    menu)      run_one menu      menu      "--selftest-menu" ;;
    settings)  run_one settings  settings  "--selftest-settings" ;;
    pdf)       run_one pdf       pdf       "--selftest-pdf" ;;
    docx)      run_one docx      docx      "--selftest-docx" ;;
    todo)      run_one todo      todo      "--selftest-todo" ;;
    remind)    run_one remind    remind    "--selftest-remind" ;;
    notify)    run_one notify    notify    "--selftest-notify" ;;
    todoio)    run_one todoio    todoio    "--selftest-todoio" ;;
    *) echo "未知标签：$t" ;;
  esac
done
