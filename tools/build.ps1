# 打包：把 note.ahk 编译成 exe，并把运行时资源摆到 dist\
# 用法：pwsh -File tools/build.ps1
#   需要 Ahk2Exe（环境变量 AHK2EXE 指过去，或用下面的默认路径）
param(
    [string]$Ahk2Exe = $env:AHK2EXE,
    [string]$Out = 'dist'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not $Ahk2Exe) {
    $candidates = @(
        "$env:TEMP\ahk2exe-probe\exe2\Ahk2Exe.exe",
        "$env:ProgramFiles\AutoHotkey\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\Compiler\Ahk2Exe.exe"
    )
    $Ahk2Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Ahk2Exe -or -not (Test-Path $Ahk2Exe)) {
    throw "找不到 Ahk2Exe.exe。设个环境变量 AHK2EXE 指向它，或改脚本里的默认路径。"
}

$outDir = Join-Path $root $Out
$base = Join-Path $root 'runtime\AutoHotkey64.exe'
$exe = Join-Path $outDir 'QuickNote.exe'

# ---- 编译前：先让 AHK 把脚本加载一遍 -------------------------------------
# 编译版没有语法错误框，编出来才发现问题就晚了。note.ahk 支持 --check：
# 走完 #Include 和加载期检查后立刻退出，不建窗口、不碰数据库。
Write-Host "语法检查（note.ahk --check）…"
# 注意：AHK 是 GUI 子系统程序，PowerShell 用 & 调它不会等、也拿不到 $LASTEXITCODE，
# 必须 Start-Process -Wait 才能读到退出码
$chkErr = Join-Path $env:TEMP 'quicknote-check.txt'
if (Test-Path $chkErr) { Remove-Item $chkErr -Force }
$chkProc = Start-Process -FilePath $base -Wait -PassThru -NoNewWindow `
    -ArgumentList @('/ErrorStdOut', (Join-Path $root 'note.ahk'), '--check') `
    -RedirectStandardError $chkErr
if ($chkProc.ExitCode -ne 0) {
    $msg = if (Test-Path $chkErr) { Get-Content $chkErr -Raw } else { '' }
    throw "语法检查未通过（退出码 $($chkProc.ExitCode)）：`n$msg"
}
Write-Host "  通过"

if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

$exe = Join-Path $outDir 'QuickNote.exe'
$base = Join-Path $root 'runtime\AutoHotkey64.exe'
$exe = Join-Path $outDir 'QuickNote.exe'
$base = Join-Path $root 'runtime\AutoHotkey64.exe'
Write-Host "编译 note.ahk -> $exe"
$p = Start-Process -FilePath $Ahk2Exe -Wait -PassThru -NoNewWindow -ArgumentList @(
    '/in', (Join-Path $root 'note.ahk'),
    '/out', $exe,
    '/icon', (Join-Path $root 'assets\note.ico'),
    '/base', $base
)
if ($p.ExitCode -ne 0 -or -not (Test-Path $exe)) {
    throw "编译失败，退出码 $($p.ExitCode)"
}

# 资源：ui 页面、WebView2 loader、兜底 SQLite 库、图标
Copy-Item (Join-Path $root 'ui') (Join-Path $outDir 'ui') -Recurse
foreach ($junk in @('vendor')) {
    $p2 = Join-Path $outDir "ui\$junk"
    if (Test-Path $p2) { Remove-Item $p2 -Recurse -Force }
}
New-Item -ItemType Directory -Path (Join-Path $outDir 'lib') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outDir 'assets') -Force | Out-Null
Copy-Item (Join-Path $root 'lib\WebView2Loader.dll') (Join-Path $outDir 'lib') -Force
if (Test-Path (Join-Path $root 'lib\sqlite3.dll')) {
    Copy-Item (Join-Path $root 'lib\sqlite3.dll') (Join-Path $outDir 'lib') -Force
}
Copy-Item (Join-Path $root 'assets\note.ico') (Join-Path $outDir 'assets') -Force

$size = [math]::Round(((Get-ChildItem $outDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 2)
$exeSize = [math]::Round((Get-Item $exe).Length / 1KB)

# ---- 冒烟测试：真启动一次，确认它活着并且真的把便签装起来了 ----------------
# 编译版崩起来一声不吭，所以这一关不能省。用 portable.txt 把数据隔离到
# dist\data，跑完清掉，免得污染用户自己的 %APPDATA%。
if (Get-Process -Name 'QuickNote' -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Warning "已有 QuickNote 实例在运行，跳过冒烟测试（单实例互斥会让新进程直接退出）"
} else {
    Write-Host ""
    Write-Host "冒烟测试：启动 exe 观察 6 秒…"
    $portable = Join-Path $outDir 'portable.txt'
    Set-Content -Path $portable -Value '' -NoNewline -Encoding ascii
    $proc = Start-Process -FilePath $exe -PassThru
    Start-Sleep -Seconds 6
    $alive = -not $proc.HasExited
    $logPath = Join-Path $outDir 'data\app.log'
    $booted = (Test-Path $logPath) -and ((Get-Content $logPath -Raw) -match 'Boot 返回')
    $crash = Join-Path $outDir 'crash.log'
    if ($alive) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

    $fail = @()
    if (-not $alive) { $fail += '进程启动后 6 秒内退出了' }
    if (-not $booted) { $fail += 'app.log 里没有 "Boot 返回"（窗口可能没建起来）' }
    if (Test-Path $crash) { $fail += "产生了 crash.log：`n" + (Get-Content $crash -Raw) }

    Remove-Item $portable -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $outDir 'data') -Recurse -Force -ErrorAction SilentlyContinue
    if ($fail.Count) { throw ("冒烟测试失败：`n  - " + ($fail -join "`n  - ")) }
    Write-Host "  通过（进程存活，日志显示便签已装载）"
}

Write-Host ""
Write-Host "完成：$outDir"
Write-Host "  QuickNote.exe  $exeSize KB"
Write-Host "  整包          $size MB"
Write-Host ""
Write-Host "提示：想让数据跟着程序走（便携模式），在 dist\ 里放一个空的 portable.txt 再启动。"
