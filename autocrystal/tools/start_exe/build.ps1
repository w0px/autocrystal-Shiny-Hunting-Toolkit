param(
    # Where start.exe goes - the top-level folder (the one holding
    # autocrystal\ and BizHawk\) by default. This script lives in
    # autocrystal\tools\start_exe\.
    [string]$OutExe = (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) "start.exe")
)

# Builds start.exe from Start.cs with the C# compiler that ships with
# Windows' .NET Framework 4.x (nothing to install), with launcher_art.png
# as its icon.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$botDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
$art = Join-Path $botDir "data\launcher_art.png"
if (-not (Test-Path -LiteralPath $art)) { $art = $null }
$icoPath = Join-Path $PSScriptRoot "start.ico"

# An .ico holding one PNG-compressed image per size (supported since
# Windows Vista). The artwork isn't square, so it's centered on a
# transparent square; upscaled sizes use nearest-neighbor so the pixel art
# stays crisp instead of blurring.
function New-IcoFromPng([string]$pngPath, [string]$icoOut) {
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $source = [System.Drawing.Image]::FromFile($pngPath)
    $images = foreach ($size in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $scale = [Math]::Min($size / $source.Width, $size / $source.Height)
        $g.InterpolationMode = if ($scale -ge 1) { "NearestNeighbor" } else { "HighQualityBicubic" }
        $g.PixelOffsetMode = "Half"
        $w = [int][Math]::Round($source.Width * $scale); $h = [int][Math]::Round($source.Height * $scale)
        $g.DrawImage($source, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        , @($size, $ms.ToArray())
    }
    $source.Dispose()

    $out = New-Object System.IO.MemoryStream
    $wr = New-Object System.IO.BinaryWriter $out
    $wr.Write([uint16]0); $wr.Write([uint16]1); $wr.Write([uint16]$images.Count) # ICONDIR
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {                                                    # ICONDIRENTRY
        $size = $img[0]; $data = $img[1]
        $wr.Write([byte]($size % 256)); $wr.Write([byte]($size % 256))              # 256 is stored as 0
        $wr.Write([byte]0); $wr.Write([byte]0)
        $wr.Write([uint16]1); $wr.Write([uint16]32)
        $wr.Write([uint32]$data.Length); $wr.Write([uint32]$offset)
        $offset += $data.Length
    }
    foreach ($img in $images) { $wr.Write([byte[]]$img[1]) }
    $wr.Flush()
    [System.IO.File]::WriteAllBytes($icoOut, $out.ToArray())
}

$iconArg = @()
if ($art) {
    New-IcoFromPng $art $icoPath
    $iconArg = @("/win32icon:$icoPath")
} else {
    Write-Warning "launcher_art.png not found - building start.exe without an icon."
}

& $csc /nologo /target:winexe /optimize+ "/out:$OutExe" @iconArg (Join-Path $PSScriptRoot "Start.cs")
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)" }
"Built $OutExe"
