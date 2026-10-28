# make_egg_sprites.ps1
# Builds the two Egg pictures the bot shows from data\sprites\normal\egg.png
# (any size, the egg anywhere on a transparent background):
#   data\sprites\egg_card.png     98x98   - the launcher's Last Encounter card
#   data\sprites\egg_discord.png  square  - attached to the Egg module's
#                                           Discord embeds (discord_relay.ps1)
# Both are cropped to the egg itself, so it comes out about the size a
# Pokemon sprite would. Re-run after replacing egg.png.

param(
    [string]$Source = (Join-Path $PSScriptRoot "..\data\sprites\normal\egg.png"),
    [string]$OutDir = (Join-Path $PSScriptRoot "..\data\sprites")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$src = New-Object System.Drawing.Bitmap ((Resolve-Path -LiteralPath $Source).Path)
try {
    # The egg's bounding box: every pixel that isn't (almost) transparent.
    $minX = $src.Width; $minY = $src.Height; $maxX = -1; $maxY = -1
    for ($y = 0; $y -lt $src.Height; $y++) {
        for ($x = 0; $x -lt $src.Width; $x++) {
            if ($src.GetPixel($x, $y).A -gt 16) {
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { throw "$Source is fully transparent - nothing to crop." }
    $egg = New-Object System.Drawing.Rectangle $minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)
    $eggSide = [Math]::Max($egg.Width, $egg.Height)

    # The egg scaled so its longer side is $eggSize, centered on a
    # transparent $canvas x $canvas square.
    function Save-Egg([int]$canvas, [int]$eggSize, [string]$path) {
        $scale = $eggSize / $eggSide
        $w = [int][Math]::Round($egg.Width * $scale); $h = [int][Math]::Round($egg.Height * $scale)
        $out = New-Object System.Drawing.Bitmap $canvas, $canvas, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($out)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            # No smeared-in edge pixels from outside the crop.
            $attrs = New-Object System.Drawing.Imaging.ImageAttributes
            $attrs.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $dest = New-Object System.Drawing.Rectangle ([int](($canvas - $w) / 2)), ([int](($canvas - $h) / 2)), $w, $h
            $g.DrawImage($src, $dest, $egg.X, $egg.Y, $egg.Width, $egg.Height, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
        } finally { $g.Dispose() }
        $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $out.Dispose()
        Write-Host ("{0}: {1}x{1}, egg {2}x{3}" -f (Split-Path $path -Leaf), $canvas, $w, $h)
    }

    # Card: about the size of a Crystal sprite on the 60px card. Discord:
    # as sharp as the source allows (never scaled up), with some room around
    # it like a sprite thumbnail has.
    Save-Egg 98 52 (Join-Path $OutDir "egg_card.png")
    $discordEgg = [Math]::Min($eggSide, 160)
    Save-Egg ([int]($discordEgg * 1.5)) $discordEgg (Join-Path $OutDir "egg_discord.png")
} finally {
    $src.Dispose()
}
