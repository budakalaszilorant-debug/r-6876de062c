# Original vector artwork; no external image/font assets. Rebuild the opaque iOS icon.
Add-Type -AssemblyName System.Drawing
$iconDir = Join-Path $PSScriptRoot '../ios-app/SubaruCompanion/Assets.xcassets/AppIcon.appiconset'
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null
$bitmap = [System.Drawing.Bitmap]::new(1024, 1024)
$canvas = [System.Drawing.Graphics]::FromImage($bitmap)
$canvas.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$canvas.Clear([System.Drawing.Color]::FromArgb(14, 20, 29))
$blue = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(74, 153, 255), 64)
$blue.StartCap = $blue.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$blue.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$roof = [System.Drawing.Point[]]@([System.Drawing.Point]::new(230,400), [System.Drawing.Point]::new(512,205), [System.Drawing.Point]::new(794,400))
$canvas.DrawLines($blue, $roof)
$white = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(239,245,255), 75)
$white.StartCap = $white.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$canvas.DrawArc($white, 325, 360, 375, 375, 5, 300)
$canvas.DrawLine($white, 700, 548, 540, 548)
$road = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(74,153,255), 20)
$canvas.DrawLine($road, 435, 817, 589, 817)
$canvas.DrawLine($road, 470, 876, 554, 876)
$bitmap.Save((Join-Path $iconDir 'AppIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$road.Dispose(); $white.Dispose(); $blue.Dispose(); $canvas.Dispose(); $bitmap.Dispose()
'{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' | Set-Content -Encoding utf8 (Join-Path $iconDir 'Contents.json')
