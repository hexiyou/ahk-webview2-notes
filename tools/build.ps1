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
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

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
Write-Host ""
Write-Host "完成：$outDir"
Write-Host "  QuickNote.exe  $exeSize KB"
Write-Host "  整包          $size MB"
Write-Host ""
Write-Host "提示：想让数据跟着程序走（便携模式），在 dist\ 里放一个空的 portable.txt 再启动。"
