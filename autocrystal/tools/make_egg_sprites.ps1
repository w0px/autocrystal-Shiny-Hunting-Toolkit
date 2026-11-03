# make_egg_sprites.ps1
# Builds the two animated Egg pictures the bot shows from
# data\sprites\normal\egg.gif (any size, the egg anywhere on a transparent
# background, animated or not):
#   data\sprites\egg_card.gif     98x98   - the launcher's Current Encounter card
#   data\sprites\egg_discord.gif  72x72   - attached to the Egg module's
#                                           Discord embeds (discord_relay.ps1)
# Both are cropped to the egg itself (across every frame, so the wobble
# stays inside): on the card it comes out about the size a Pokemon sprite
# would; for Discord it sits on a 72px canvas, the size of the Pokemon
# there (tools/scale_sprites.ps1), but 20% smaller (58px) - the plain egg
# at the full 72px looked too big next to them.
# Scaled smoothly, like before, then written back as a GIF with its own
# palette (tools/gif_codec.cs). Re-run after replacing egg.gif.

param(
    [string]$Source = (Join-Path $PSScriptRoot "..\data\sprites\normal\egg.gif"),
    [string]$OutDir = (Join-Path $PSScriptRoot "..\data\sprites")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
if (-not ("GifScale" -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot "gif_codec.cs") }

# Every frame as a full-size bitmap (GDI+ draws each one with the ones
# before it as the GIF says), plus its delay in 1/100 s.
$img = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source).Path)
$frames = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
$delays = New-Object System.Collections.Generic.List[int]
try {
    $dim = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
    $count = $img.GetFrameCount($dim)
    $delayBytes = $null
    if ($img.PropertyIdList -contains 0x5100) { $delayBytes = $img.GetPropertyItem(0x5100).Value }
    for ($f = 0; $f -lt $count; $f++) {
        [void]$img.SelectActiveFrame($dim, $f)
        $frames.Add((New-Object System.Drawing.Bitmap($img)))
        $delay = 10
        if ($delayBytes -and $delayBytes.Length -ge 4 * ($f + 1)) { $delay = [BitConverter]::ToInt32($delayBytes, 4 * $f) }
        $delays.Add([Math]::Max(2, $delay))
    }
} finally {
    $img.Dispose()
}

try {
    # The egg's bounding box over every frame: every pixel that isn't
    # (almost) transparent.
    $minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = -1; $maxY = -1
    foreach ($frame in $frames) {
        for ($y = 0; $y -lt $frame.Height; $y++) {
            for ($x = 0; $x -lt $frame.Width; $x++) {
                if ($frame.GetPixel($x, $y).A -gt 16) {
                    if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }
    }
    if ($maxX -lt 0) { throw "$Source is fully transparent - nothing to crop." }
    $egg = New-Object System.Drawing.Rectangle $minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)
    $eggSide = [Math]::Max($egg.Width, $egg.Height)

    # The egg scaled so its longer side is $eggSize, centered on a
    # transparent canvas ($canvas x $canvas, or just the egg when 0).
    function Save-Egg([int]$canvas, [int]$eggSize, [string]$path) {
        $scale = $eggSize / $eggSide
        $w = [int][Math]::Round($egg.Width * $scale); $h = [int][Math]::Round($egg.Height * $scale)
        $cw = $canvas; $ch = $canvas
        if ($canvas -eq 0) { $cw = $w; $ch = $h }
        $pixels = New-Object 'System.Collections.Generic.List[int[]]'
        foreach ($frame in $frames) {
            $out = New-Object System.Drawing.Bitmap $cw, $ch, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($out)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                # No smeared-in edge pixels from outside the crop.
                $attrs = New-Object System.Drawing.Imaging.ImageAttributes
                $attrs.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
                $dest = New-Object System.Drawing.Rectangle ([int](($cw - $w) / 2)), ([int](($ch - $h) / 2)), $w, $h
                $g.DrawImage($frame, $dest, $egg.X, $egg.Y, $egg.Width, $egg.Height, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
            } finally { $g.Dispose() }
            $data = $out.LockBits((New-Object System.Drawing.Rectangle 0, 0, $cw, $ch), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $argb = New-Object int[] ($cw * $ch)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $argb, 0, $argb.Length)
            $out.UnlockBits($data)
            $out.Dispose()
            $pixels.Add($argb)
        }
        $gif = [GifWrite]::Animated($cw, $ch, $pixels, $delays.ToArray())
        $name = Split-Path $path -Leaf
        # A file that's already exactly this is left alone - the launcher
        # keeps egg_card.gif open while BizHawk runs.
        if ((Test-Path -LiteralPath $path) -and [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($path), [byte[]]$gif)) {
            Write-Host ("{0}: unchanged" -f $name)
            return
        }
        try {
            [System.IO.File]::WriteAllBytes($path, $gif)
            Write-Host ("{0}: {1}x{2}, egg {3}x{4}, {5} frame(s)" -f $name, $cw, $ch, $w, $h, $frames.Count)
        } catch {
            Write-Host ("{0}: couldn't write it ({1}) - close BizHawk and run this again." -f $name, $_.Exception.Message)
        }
    }

    # Card: about the size of a Crystal sprite on the 98px card. Discord:
    # a 72px canvas like the Pokemon there, the egg 20% smaller on it.
    Save-Egg 98 52 (Join-Path $OutDir "egg_card.gif")
    Save-Egg 72 58 (Join-Path $OutDir "egg_discord.gif")
} finally {
    foreach ($frame in $frames) { $frame.Dispose() }
}
