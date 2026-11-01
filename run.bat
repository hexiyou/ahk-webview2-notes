@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem ===========================================================================
rem  run.bat —— 以脚本模式运行（开发调试用）
rem
rem  为什么不直接用编译好的 exe：exe 出错时没有控制台、也没有 AHK 的语法错误
rem  提示框，只能看到"程序闪一下就没了"。脚本模式会把编译错误、运行时错误
rem  直接打在这个窗口里。
rem
rem  注意：关掉这个窗口就等于退出程序。日常使用请用 dist\QuickNote.exe。
rem ===========================================================================

set "AHK=%~dp0runtime\AutoHotkey64.exe"
if not exist "%AHK%" set "AHK=AutoHotkey64.exe"

echo [QuickNote] 脚本模式启动（这个窗口关掉 = 退出程序）
echo [QuickNote] 改完 .ahk 或 ui 下的文件，关掉重开就生效
echo.

"%AHK%" /ErrorStdOut "%~dp0note.ahk" %*
set "CODE=%ERRORLEVEL%"

if not "%CODE%"=="0" (
  echo.
  echo [QuickNote] 退出码 %CODE% —— 上面就是原因，别急着编译
  pause
)
