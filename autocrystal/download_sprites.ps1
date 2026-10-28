# download_sprites.ps1
# One-time download of the Gen II Crystal sprites the Encounter Stats
# window (modules/stats_window.lua) shows next to each species, plus the
# animated ones the launcher's Last Encounter card plays (gui_module.lua).
#
# Source: the same PokeAPI sprite repo (via jsdelivr's CDN) that the
# Discord shiny/catch embeds already link to - see shiny_sprite_url() /
# regular_sprite_url() in wild.lua. Saves into:
#   data\sprites\normal\<dex>.png            (1-251)
#   data\sprites\shiny\<dex>.png             (1-251)
#   data\sprites\animated\normal\<dex>.gif   (1-251)
#   data\sprites\animated\shiny\<dex>.gif    (1-251)
# Safe to re-run any time: files that already exist are skipped, so a
# second run only fills in whatever failed or is missing.
#
# Started by the "Download sprites..." button in the Encounter Stats
# window, or run it by hand (right-click > Run with PowerShell).

param(
    [string]$BaseUrl = "https://cdn.jsdelivr.net/gh/PokeAPI/sprites@master/sprites/pokemon/versions/generation-ii/crystal",
    # The same files straight from PokeAPI's GitHub repo, for the odd one
    # the CDN refuses (it answers 403 for animated/shiny/179.gif).
    [string]$FallbackBaseUrl = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/versions/generation-ii/crystal",
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
# Invoke-WebRequest's progress bar makes Windows PowerShell 5.1 downloads
# many times slower - turn it off, we print our own progress.
$ProgressPreference = "SilentlyContinue"
# Windows PowerShell 5.1 doesn't always enable TLS 1.2 by default, which
# jsdelivr requires.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$spriteRoot = Join-Path $PSScriptRoot "data\sprites"
# NOTE: ${BaseUrl} (curly-braced) on purpose - see discord_relay.ps1's
# note on PowerShell silently mangling "$var?..." style interpolation.
$sets = @(
    @{ Name = "normal";          Sub = "";                Ext = "png" },
    @{ Name = "shiny";           Sub = "/shiny";          Ext = "png" },
    @{ Name = "animated\normal"; Sub = "/animated";       Ext = "gif" },
    @{ Name = "animated\shiny";  Sub = "/animated/shiny"; Ext = "gif" }
)
# The first bytes every real file of that type starts with - anything
# else (an error page, a cut-off download) gets retried instead of kept.
$signatures = @{
    png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    gif = [byte[]](0x47, 0x49, 0x46, 0x38)  # "GIF8"
}

function Test-ImageFile([string]$path, [string]$ext) {
    $signature = $signatures[$ext]
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
    } catch { return $false }
    if ($bytes.Length -lt $signature.Length) { return $false }
    for ($i = 0; $i -lt $signature.Length; $i++) {
        if ($bytes[$i] -ne $signature[$i]) { return $false }
    }
    return $true
}

$downloaded = 0
$skipped = 0
$failed = New-Object System.Collections.Generic.List[string]

Write-Host "Downloading Crystal sprites into $spriteRoot"
Write-Host ""

foreach ($set in $sets) {
    $dir = Join-Path $spriteRoot $set.Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    for ($dex = 1; $dex -le 251; $dex++) {
        $file = "$dex.$($set.Ext)"
        $target = Join-Path $dir $file
        if ((Test-Path $target) -and (Test-ImageFile $target $set.Ext)) {
            $skipped++
            continue
        }
        $part = "$target.part"
        $ok = $false
        # Three tries from the CDN, then one from GitHub itself.
        for ($attempt = 1; $attempt -le 4 -and -not $ok; $attempt++) {
            $base = if ($attempt -le 3) { $BaseUrl } else { $FallbackBaseUrl }
            $url = "$base$($set.Sub)/$file"
            try {
                Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing -TimeoutSec 30
                if (Test-ImageFile $part $set.Ext) {
                    Move-Item -Force -Path $part -Destination $target
                    $ok = $true
                } else {
                    throw "not a $($set.Ext)"
                }
            } catch {
                if ($attempt -lt 3) { Start-Sleep -Milliseconds (500 * $attempt) }
            }
        }
        if (Test-Path $part) { Remove-Item -Force $part -ErrorAction SilentlyContinue }
        if ($ok) {
            $downloaded++
        } else {
            $failed.Add("$($set.Name)/$dex")
        }
        if ($dex % 50 -eq 0) {
            Write-Host ("  {0}: {1}/251" -f $set.Name, $dex)
        }
    }
    Write-Host ("  {0}: done" -f $set.Name)
}

Write-Host ""
Write-Host ("Done. Downloaded {0}, already had {1}, failed {2}." -f $downloaded, $skipped, $failed.Count)
if ($failed.Count -gt 0) {
    Write-Host ("Failed: " + ($failed -join ", "))
    Write-Host "Run this script again to retry just the missing ones."
}
# The launcher's Last Encounter card shows the animated ones enlarged
# (tools\scale_sprites.ps1) - made here from whatever just got downloaded.
$scaler = Join-Path $PSScriptRoot "tools\scale_sprites.ps1"
if (Test-Path -LiteralPath $scaler) {
    try { & $scaler } catch { Write-Host "Couldn't make the double-size sprites: $_" }
}
Write-Host "Click Refresh in the Encounter Stats window to see the sprites - the launcher's"
Write-Host "Last Encounter card picks up the animated ones by itself."
if (-not $NoPause) {
    Write-Host ""
    Read-Host "Press Enter to close" | Out-Null
}
