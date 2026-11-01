# 生成便签图标：圆角纸片 + 条纹 + 右下折角
# 用法：pwsh -File tools/make-icon.ps1
Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PSScriptRoot '..\assets'
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$outDir = (Resolve-Path $outDir).Path

function New-RoundedPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)

foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = [Math]::Max(1, $s * 0.045)
    $w = $s - $pad * 2
    $r = $s * 0.17

    $path = New-RoundedPath $pad $pad $w $w $r

    # 纸面：暖黄渐变，左上亮、右下略深
    $c1 = [System.Drawing.Color]::FromArgb(255, 255, 240, 170)
    $c2 = [System.Drawing.Color]::FromArgb(255, 250, 206, 92)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF($pad, $pad)),
        (New-Object System.Drawing.PointF(($pad + $w), ($pad + $w))),
        $c1, $c2)
    $g.FillPath($brush, $path)

    # 描边
    $penW = [Math]::Max(1, $s * 0.028)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 150, 110, 20), $penW)
    $g.DrawPath($pen, $path)

    # 三条文字线
    if ($s -ge 16) {
        $lineColor = [System.Drawing.Color]::FromArgb(105, 120, 88, 25)
        $lb = New-Object System.Drawing.SolidBrush($lineColor)
        $lh = [Math]::Max(1.2, $s * 0.075)
        $x1 = $pad + $w * 0.20
        $widths = @(0.60, 0.52, 0.36)
        $y0 = $pad + $w * 0.30
        $gap = $w * 0.17
        for ($i = 0; $i -lt 3; $i++) {
            $lw = $w * $widths[$i]
            $ly = $y0 + $i * $gap
            $lp = New-RoundedPath $x1 $ly $lw $lh ($lh / 2)
            $g.FillPath($lb, $lp)
            $lp.Dispose()
        }
        $lb.Dispose()
    }

    # 右下折角
    if ($s -ge 32) {
        $cs = $w * 0.34
        $cx = $pad + $w
        $cy = $pad + $w
        $fold = New-Object System.Drawing.Drawing2D.GraphicsPath
        $pts = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new([float]($cx - $cs), [float]$cy),
            [System.Drawing.PointF]::new([float]$cx, [float]($cy - $cs)),
            [System.Drawing.PointF]::new([float]$cx, [float]$cy)
        )
        $fold.AddPolygon($pts)
        $foldBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 255, 255, 255))
        $g.SetClip($path)
        $g.FillPath($foldBrush, $fold)
        $g.ResetClip()
        $fold.Dispose()
        $foldBrush.Dispose()
    }

    $file = Join-Path $outDir ("note-{0}.png" -f $s)
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)

    $brush.Dispose(); $pen.Dispose(); $path.Dispose()
    $g.Dispose(); $bmp.Dispose()
    Write-Output "wrote $file"
}
