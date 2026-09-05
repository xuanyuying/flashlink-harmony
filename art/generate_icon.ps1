# FlashLink 闪连 App 图标生成脚本
# 设计: 倾斜闪电 + 尾部融合两道平行弧形Wi-Fi信号, 纯色鸿蒙蓝(#007AFF)背景, 扁平矢量风
# 注: GDI+ DrawArc 在笔宽 >= ~39px 时会退化成整圆, 故弧形改用多边形条带手工绘制
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$root    = 'D:\DevEcoStudioProjectsdate\DevEcoStudioProjects\FlashLink'
$artDir  = Join-Path $root 'art'
New-Item -ItemType Directory -Force -Path $artDir | Out-Null

$blue = [System.Drawing.Color]::FromArgb(255, 0, 122, 255)   # 鸿蒙蓝 #007AFF
$white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)

# ================= 设计参数 (以 1024 画布, 中心 512,512 为基准) =================
$S      = 1.22     # 整体缩放系数
$Tilt   = -6       # 额外倾斜角(度, 顺时针为正)
$CX = 512.0; $CY = 512.0

# 闪电多边形 (6 顶点, 顶部头部 -> 底部尖端, 自然左倾)
$boltDesign = @(
  [System.Drawing.PointF]::new(625, 275),
  [System.Drawing.PointF]::new(430, 505),
  [System.Drawing.PointF]::new(512, 505),
  [System.Drawing.PointF]::new(448, 735),
  [System.Drawing.PointF]::new(658, 505),
  [System.Drawing.PointF]::new(574, 505)
)

# 弧形 Wi-Fi 信号: 两道平行 ∩ 弧, 中心 (448,800), 内径100 外径165, 弧度 200..340 (经过顶部 270)
$arcsDesign = @(
  @{ X = 448.0; Y = 800.0; R = 165.0; W = 34.0 },
  @{ X = 448.0; Y = 800.0; R = 100.0; W = 34.0 }
)
$angStart = 200.0   # 弧起始角(度)
$angSweep = 140.0   # 弧扫过角度(度)

# ---------- 预处理: 缩放 + 倾斜 + 计算居中平移 ----------
function RotatePoint([System.Drawing.PointF]$p, [double]$angleDeg) {
  $rad = $angleDeg * [math]::PI / 180.0
  $dx = $p.X - $CX; $dy = $p.Y - $CY
  $cos = [math]::Cos($rad); $sin = [math]::Sin($rad)
  return [System.Drawing.PointF]::new($CX + $dx * $cos - $dy * $sin, $CY + $dx * $sin + $dy * $cos)
}

$bolt = @()
foreach ($p in $boltDesign) {
  $sx = $CX + ($p.X - $CX) * $S
  $sy = $CY + ($p.Y - $CY) * $S
  $rp = RotatePoint ([System.Drawing.PointF]::new($sx, $sy)) $Tilt
  $bolt += $rp
}

$arcs = @()
foreach ($a in $arcsDesign) {
  $sx = $CX + ($a.X - $CX) * $S
  $sy = $CY + ($a.Y - $CY) * $S
  $rp = RotatePoint ([System.Drawing.PointF]::new($sx, $sy)) $Tilt
  $arcs += @{ X = $rp.X; Y = $rp.Y; R = $a.R * $S; W = $a.W * $S }
}

# 包围盒
$xmin = [double]::MaxValue; $xmax = [double]::MinValue
$ymin = [double]::MaxValue; $ymax = [double]::MinValue
foreach ($p in $bolt) {
  if ($p.X -lt $xmin) { $xmin = $p.X }; if ($p.X -gt $xmax) { $xmax = $p.X }
  if ($p.Y -lt $ymin) { $ymin = $p.Y }; if ($p.Y -gt $ymax) { $ymax = $p.Y }
}
foreach ($a in $arcs) {
  $cx = $a.X; $cy = $a.Y; $r = $a.R
  # 弧度 200..340: 端点 x = cx +/- 0.9397r, y = cy - 0.342r; 顶部 y = cy - r
  $xmin = [math]::Min($xmin, $cx - 0.9397 * $r); $xmax = [math]::Max($xmax, $cx + 0.9397 * $r)
  $ymin = [math]::Min($ymin, $cy - $r);         $ymax = [math]::Max($ymax, $cy - 0.342 * $r)
}
$tx = 512.0 - ($xmin + $xmax) / 2.0
$ty = 512.0 - ($ymin + $ymax) / 2.0
Write-Host ("bbox: x[{0:N1},{1:N1}] y[{2:N1},{3:N1}]  translate({4:N1},{5:N1})" -f $xmin,$xmax,$ymin,$ymax,$tx,$ty)

# ---------- 绘制 ----------
# 手工绘制弧形条带(多边形条 + 圆形端帽), 避免 GDI+ DrawArc 厚笔宽退化成整圆的缺陷
function Draw-ArcStrip([System.Drawing.Graphics]$g, [double]$cx, [double]$cy, [double]$r, [double]$w, [double]$a0, [double]$sweep) {
  $n = 64
  $outer = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
  $inner = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
  for ($i = 0; $i -le $n; $i++) {
    $a = ($a0 + $sweep * $i / $n) * [math]::PI / 180.0
    $ca = [math]::Cos($a); $sa = [math]::Sin($a)
    $px = $cx + $r * $ca; $py = $cy + $r * $sa
    $h = $w / 2.0
    $outer.Add([System.Drawing.PointF]::new($px + $ca * $h, $py + $sa * $h))
    $inner.Add([System.Drawing.PointF]::new($px - $ca * $h, $py - $sa * $h))
  }
  $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
  $pts.AddRange($outer)
  for ($i = $n; $i -ge 0; $i--) { $pts.Add($inner[$i]) }
  $g.FillPolygon([System.Drawing.Brushes]::White, $pts.ToArray())
  # 圆形端帽 (圆头)
  $a0r = $a0 * [math]::PI / 180.0
  $a1r = ($a0 + $sweep) * [math]::PI / 180.0
  $e0 = [System.Drawing.PointF]::new($cx + $r * [math]::Cos($a0r), $cy + $r * [math]::Sin($a0r))
  $e1 = [System.Drawing.PointF]::new($cx + $r * [math]::Cos($a1r), $cy + $r * [math]::Sin($a1r))
  $g.FillEllipse([System.Drawing.Brushes]::White, $e0.X - $w / 2, $e0.Y - $w / 2, $w, $w)
  $g.FillEllipse([System.Drawing.Brushes]::White, $e1.X - $w / 2, $e1.Y - $w / 2, $w, $w)
}

function Draw-Symbol([System.Drawing.Graphics]$g, [int]$size) {
  $s = $size / 1024.0
  $devX = { param($x) ((($x + $tx) - 512.0) * $s) + ($size / 2.0) }
  $devY = { param($y) ((($y + $ty) - 512.0) * $s) + ($size / 2.0) }
  # 闪电
  $pts = @()
  foreach ($p in $bolt) { $pts += [System.Drawing.PointF]::new((& $devX $p.X), (& $devY $p.Y)) }
  $g.FillPolygon([System.Drawing.Brushes]::White, $pts)
  # 弧形 Wi-Fi
  foreach ($a in $arcs) {
    $cxd = & $devX $a.X; $cyd = & $devY $a.Y
    Draw-ArcStrip $g $cxd $cyd ($a.R * $s) ($a.W * $s) $angStart $angSweep
  }
}

function New-Canvas([int]$size, [System.Drawing.Color]$bg) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear($bg)
  return @{ Bmp = $bmp; G = $g }
}

# 1) 前景图层 (透明底, 白色符号) 1024
$fg = New-Canvas 1024 ([System.Drawing.Color]::Transparent)
Draw-Symbol $fg.G 1024
$fgPath = Join-Path $artDir 'flashlink-icon-foreground-1024.png'
$fg.Bmp.Save($fgPath, [System.Drawing.Imaging.ImageFormat]::Png)
$fg.G.Dispose(); $fg.Bmp.Dispose()

# 2) 完整预览 (纯色蓝底 + 符号) 1024
$pv = New-Canvas 1024 $blue
Draw-Symbol $pv.G 1024
$pvPath = Join-Path $artDir 'flashlink-icon-preview-1024.png'
$pv.Bmp.Save($pvPath, [System.Drawing.Imaging.ImageFormat]::Png)
$pv.G.Dispose(); $pv.Bmp.Dispose()

# 3) 4K 主图 4096
$big = New-Canvas 4096 $blue
Draw-Symbol $big.G 4096
$bigPath = Join-Path $artDir 'flashlink-icon-4k.png'
$big.Bmp.Save($bigPath, [System.Drawing.Imaging.ImageFormat]::Png)
$big.G.Dispose(); $big.Bmp.Dispose()

# 4) 背景图层 (纯色 #007AFF) 1024
$bg = New-Canvas 1024 $blue
$bgPath = Join-Path $artDir 'flashlink-icon-background-1024.png'
$bg.Bmp.Save($bgPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bg.G.Dispose(); $bg.Bmp.Dispose()

# 5) startIcon 144 (纯色蓝底 + 符号)
$st = New-Canvas 144 $blue
Draw-Symbol $st.G 144
$stPath = Join-Path $artDir 'flashlink-startIcon-144.png'
$st.Bmp.Save($stPath, [System.Drawing.Imaging.ImageFormat]::Png)
$st.G.Dispose(); $st.Bmp.Dispose()

Write-Host "DONE"
Write-Host $fgPath
Write-Host $pvPath
Write-Host $bigPath
Write-Host $bgPath
Write-Host $stPath
