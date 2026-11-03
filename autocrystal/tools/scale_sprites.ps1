# scale_sprites.ps1
# Makes the bigger animated sprites the launcher's Last Encounter card
# shows (gui_module.lua), from the ones download_sprites.ps1 fetched:
#   data\sprites\animated\{normal,shiny}\<dex>.gif        56x56
#   -> data\sprites\animated_card\{normal,shiny}\<dex>.gif  86x86 (43/28 = ~1.54x)
# ...and the ones on Discord messages (modules/data/discord_sprite.lua):
#   -> data\sprites\animated_discord\{normal,shiny}\<dex>.gif - the empty
#      border trimmed off, then scaled until the longer side is 72px, a bit
#      under the 80px Discord shows in an embed's corner at most (1.29x for
#      a Pokemon that fills the whole 56px, ~1.8x for most).
# Scaled nearest-neighbor, so the pixel art stays sharp - a picturebox can
# only scale a GIF smoothly, which blurs it. At 43/28, 15 of every 28
# source pixels become 2px wide and the other 13 1px. The
# animation, timing and transparency are kept as they are.
# download_sprites.ps1 runs this by itself at the end; safe to re-run, it
# only makes the ones that are missing or at a different size.

param(
    [string]$SpriteDir = (Join-Path $PSScriptRoot "..\data\sprites"),
    # The scale, as a fraction: 43/28 = ~1.54x (56px -> 86px; it was 13/8,
    # 91px, until the card was made 5% smaller next to the launcher art).
    # Keep gui_module.lua's SPRITE_SCALE / CARD_GIF_SIZE in step with it.
    [int]$Numerator = 43,
    [int]$Denominator = 28,
    # The Discord set's longer side - a bit under the 80px Discord shows in
    # an embed's corner at most (80 looked slightly too big there).
    [int]$DiscordSize = 72
)

# A GIF's canvas width, from its header.
function Get-GifWidth([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    try { $b = New-Object byte[] 8; [void]$fs.Read($b, 0, 8); return $b[6] + 256 * $b[7] } finally { $fs.Close() }
}

# The longer side of a GIF's canvas.
function Get-GifSide([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    try { $b = New-Object byte[] 10; [void]$fs.Read($b, 0, 10); return [Math]::Max($b[6] + 256 * $b[7], $b[8] + 256 * $b[9]) } finally { $fs.Close() }
}

$ErrorActionPreference = "Stop"

# GDI+ can read animated GIFs but not write them, so this re-encodes the
# file itself: every block is copied as-is except the frames, whose
# pixels are LZW-decoded, resampled and LZW-encoded again.
if (-not ("GifScale" -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot "gif_codec.cs") }

$made = 0; $had = 0; $failed = New-Object System.Collections.Generic.List[string]
foreach ($set in "normal", "shiny") {
    $from = Join-Path $SpriteDir "animated\$set"
    if (-not (Test-Path -LiteralPath $from)) { continue }
    $to = Join-Path $SpriteDir "animated_card\$set"
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($gif in Get-ChildItem -LiteralPath $from -Filter "*.gif" -File) {
        $target = Join-Path $to $gif.Name
        if (Test-Path -LiteralPath $target) {
            # Kept if it's already at this scale; remade if it's from another.
            $want = [int][Math]::Ceiling((Get-GifWidth $gif.FullName) * $Numerator / $Denominator)
            if ((Get-GifWidth $target) -eq $want) { $had++; continue }
        }
        try {
            [System.IO.File]::WriteAllBytes("$target.part", [GifScale]::Scale([System.IO.File]::ReadAllBytes($gif.FullName), $Numerator, $Denominator))
            Move-Item -Force -LiteralPath "$target.part" -Destination $target
            $made++
        } catch {
            $failed.Add("$set/$($gif.Name)")
            if (Test-Path -LiteralPath "$target.part") { Remove-Item -Force -LiteralPath "$target.part" }
        }
    }
}
Write-Host ("Last Encounter card sprites: made {0}, already had {1}, failed {2}." -f $made, $had, $failed.Count)
if ($failed.Count -gt 0) { Write-Host ("Failed: " + ($failed -join ", ")) }

$made = 0; $had = 0; $failed = New-Object System.Collections.Generic.List[string]
foreach ($set in "normal", "shiny") {
    $from = Join-Path $SpriteDir "animated\$set"
    if (-not (Test-Path -LiteralPath $from)) { continue }
    $to = Join-Path $SpriteDir "animated_discord\$set"
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($gif in Get-ChildItem -LiteralPath $from -Filter "*.gif" -File) {
        $target = Join-Path $to $gif.Name
        if ((Test-Path -LiteralPath $target) -and (Get-GifSide $target) -eq $DiscordSize) { $had++; continue }
        try {
            [System.IO.File]::WriteAllBytes("$target.part", [GifScale]::Trimmed([System.IO.File]::ReadAllBytes($gif.FullName), $DiscordSize))
            Move-Item -Force -LiteralPath "$target.part" -Destination $target
            $made++
        } catch {
            $failed.Add("$set/$($gif.Name)")
            if (Test-Path -LiteralPath "$target.part") { Remove-Item -Force -LiteralPath "$target.part" }
        }
    }
}
Write-Host ("Discord sprites: made {0}, already had {1}, failed {2}." -f $made, $had, $failed.Count)
if ($failed.Count -gt 0) { Write-Host ("Failed: " + ($failed -join ", ")) }

# ...and dark mode's still sprites (gui_module.lua's M.still_sprite()):
#   -> data\sprites\still\{normal,shiny}\<dex>.png - the animated sprite's
#      first frame, transparent around the Pokemon (the downloaded PNGs are
#      on white), cut to the PNG's own size: a 48px sprite sits 8px in from
#      the 56px frame's left and top, a 40px one 8px from the left and 16px
#      from the top (its feet on the bottom row).
Add-Type -AssemblyName System.Drawing
$made = 0; $had = 0; $failed = New-Object System.Collections.Generic.List[string]
foreach ($set in "normal", "shiny") {
    $from = Join-Path $SpriteDir "animated\$set"
    if (-not (Test-Path -LiteralPath $from)) { continue }
    $to = Join-Path $SpriteDir "still\$set"
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($gif in Get-ChildItem -LiteralPath $from -Filter "*.gif" -File) {
        $target = Join-Path $to ($gif.BaseName + ".png")
        if (Test-Path -LiteralPath $target) { $had++; continue }
        $image = $null; $bitmap = $null; $graphics = $null
        try {
            $image = [System.Drawing.Image]::FromFile($gif.FullName)
            $w = $image.Width; $h = $image.Height
            $png = Join-Path $SpriteDir "$set\$($gif.BaseName).png"
            if (Test-Path -LiteralPath $png) {
                $sized = [System.Drawing.Image]::FromFile($png)
                try { $w = $sized.Width; $h = $sized.Height } finally { $sized.Dispose() }
            }
            $x = [Math]::Min(8, $image.Width - $w); $y = $image.Height - $h
            $bitmap = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
            $graphics.DrawImage($image, (New-Object System.Drawing.Rectangle 0, 0, $w, $h), $x, $y, $w, $h, [System.Drawing.GraphicsUnit]::Pixel)
            $bitmap.Save("$target.part", [System.Drawing.Imaging.ImageFormat]::Png)
            $graphics.Dispose(); $graphics = $null; $bitmap.Dispose(); $bitmap = $null
            Move-Item -Force -LiteralPath "$target.part" -Destination $target
            $made++
        } catch {
            $failed.Add("$set/$($gif.Name)")
            if (Test-Path -LiteralPath "$target.part") { Remove-Item -Force -LiteralPath "$target.part" }
        } finally {
            if ($graphics) { $graphics.Dispose() }
            if ($bitmap) { $bitmap.Dispose() }
            if ($image) { $image.Dispose() }
        }
    }
}
Write-Host ("Dark mode still sprites: made {0}, already had {1}, failed {2}." -f $made, $had, $failed.Count)
if ($failed.Count -gt 0) { Write-Host ("Failed: " + ($failed -join ", ")) }
