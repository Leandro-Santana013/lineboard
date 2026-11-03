param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$mobileRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = [Drawing.Image]::FromFile((Join-Path $mobileRoot 'assets\brand\lines-boardshop.jpg'))
function Save-BrandIcon([string]$Path, [int]$Size, [double]$Scale = 1) {
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Black)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $extent = [int][Math]::Round($Size * $Scale)
        $offset = [int][Math]::Round(($Size - $extent) / 2)
        $graphics.DrawImage($source, $offset, $offset, $extent, $extent)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
try {
    $res = Join-Path $mobileRoot 'android\app\src\main\res'
    $densities = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
    foreach ($density in $densities.Keys) {
        Save-BrandIcon (Join-Path $res "mipmap-$density\ic_launcher.png") $densities[$density]
    }
    # Keep the full supplied mark inside the adaptive launcher's central safe area.
    Save-BrandIcon (Join-Path $res 'drawable-nodpi\ic_launcher_foreground.png') 432 (76.0 / 108)
    $ios = Join-Path $mobileRoot 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
    $manifest = Get-Content -LiteralPath (Join-Path $ios 'Contents.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.images) {
        $size = [double]($entry.size -split 'x')[0]
        $scale = [double]($entry.scale -replace 'x', '')
        Save-BrandIcon (Join-Path $ios $entry.filename) ([int]($size * $scale))
    }
} finally {
    $source.Dispose()
}
