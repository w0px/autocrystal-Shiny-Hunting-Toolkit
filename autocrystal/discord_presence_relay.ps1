param(
    # autocrystal's own Discord Application ID - baked in so every
    # person who downloads this shows up as "Playing autocrystal" on
    # THEIR OWN Discord profile automatically. This is public (same as
    # the Client ID behind any "Login with Discord" button on a
    # website) - no per-user Discord Developer account or setup is
    # needed on their end at all. Only override this if you're running
    # your own fork under your own application.
    [string]$ClientId = "1530703157204881578",

    # Button shown on the Rich Presence card. Set both to "" to omit
    # the button entirely.
    [string]$ButtonLabel = "View on GitHub",
    [string]$ButtonUrl = "https://github.com/w0px/autocrystal-Shiny-Hunting-Toolkit",

    # A Rich Presence Asset Key uploaded once (by the developer, in the
    # Discord Developer Portal under Rich Presence > Art Assets) - shown
    # for every user, always. There is deliberately no per-user dynamic
    # "last shiny" image: that would need this application's Client
    # Secret baked into every copy of this script, which would leak it
    # to anyone who downloads autocrystal. The tooltip text over this
    # image (large_text, below) still varies per user/session even
    # though the image itself doesn't.
    [string]$FallbackImage = "launcher_art",

    # Local port this relay listens on for stats from the Lua bot -
    # must match PRESENCE_RELAY_URL in modules/data/presence.lua
    # (defaults to the same 5001 there).
    [int]$ListenPort = 5001,

    # When set (launcher.lua passes "EmuHawk"), the relay quits by itself
    # once no process with this name is running anymore - so closing
    # BizHawk doesn't leave a hidden relay behind, holding the port with
    # whatever version of this script was current when it started. Left
    # empty when run by hand (start_presence_relay.bat).
    [string]$ExitWhenProcessGone = "",

    # The launcher's settings file (gui_settings.lua) - this relay quits
    # once it says "relaysdisabled=1" (Advanced Settings' switch for not
    # running the relays at all).
    [string]$SettingsFile = (Join-Path $PSScriptRoot "modules\data\gui_settings.txt"),

    # Where to also write everything this window shows - launcher.lua
    # passes one, since it starts the relay hidden. Rotated to "<name>.old"
    # past $MaxLogBytes, so it never grows without bound.
    [string]$LogFile = "",
    [long]$MaxLogBytes = 1MB
)

function Write-Log([string]$Message) {
    Write-Host $Message
    if (-not $LogFile -or -not $Message) { return }
    try {
        Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message) -Encoding UTF8
        if ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
    } catch {
        # A log problem must never take the relay down with it.
    }
}

Add-Type -AssemblyName System.Web

# ===================================================================
#  Discord IPC (Rich Presence) client
#
#  This talks directly to your local Discord desktop app over its
#  named-pipe IPC socket - the same mechanism the official discord-rpc
#  library and every game with a "Playing X" status uses. It is
#  UNRELATED to discord_relay.ps1 (which posts webhook messages to a
#  channel) - run both at once for both systems to work.
#
#  Protocol summary (documented behavior of Discord's local RPC IPC):
#  each message is [4-byte little-endian opcode][4-byte little-endian
#  JSON length][UTF-8 JSON]. Opcode 0 = handshake (sent once, client ->
#  server, {"v":1,"client_id":"..."}). Opcode 1 = a normal request/
#  response frame (used for both the READY event we get back and every
#  SET_ACTIVITY call we send).
#
#  IMPORTANT: this connects to whichever Discord account is logged into
#  the desktop app on THIS machine - that's what makes "no per-user
#  setup" true. Every person who runs this relay (with the same
#  ClientId above) gets the activity posted to their OWN account,
#  automatically, the same way Rich Presence works for any game.
# ===================================================================

$OP_HANDSHAKE = 0
$OP_FRAME = 1

function Write-IpcFrame {
    param($Stream, [int]$Opcode, [string]$Json)
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $header = New-Object byte[] 8
    [System.BitConverter]::GetBytes([int32]$Opcode).CopyTo($header, 0)
    [System.BitConverter]::GetBytes([int32]$jsonBytes.Length).CopyTo($header, 4)
    $Stream.Write($header, 0, 8)
    $Stream.Write($jsonBytes, 0, $jsonBytes.Length)
    $Stream.Flush()
}

# Reads exactly one frame, using ReadAsync + a wall-clock timeout so a
# silent/hung pipe can't block this relay forever (plain synchronous
# Stream.Read on a NamedPipeClientStream has no built-in timeout).
function Read-IpcFrame {
    param($Stream, [int]$TimeoutMs = 5000)

    $header = Read-ExactBytes -Stream $Stream -Count 8 -TimeoutMs $TimeoutMs
    $opcode = [System.BitConverter]::ToInt32($header, 0)
    $length = [System.BitConverter]::ToInt32($header, 4)
    $body = Read-ExactBytes -Stream $Stream -Count $length -TimeoutMs $TimeoutMs
    $json = [System.Text.Encoding]::UTF8.GetString($body)
    return @{ Opcode = $opcode; Json = $json }
}

function Read-ExactBytes {
    param($Stream, [int]$Count, [int]$TimeoutMs)
    $buffer = New-Object byte[] $Count
    $offset = 0
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($offset -lt $Count) {
        $remainingMs = [Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
        $task = $Stream.ReadAsync($buffer, $offset, $Count - $offset)
        if (-not $task.Wait([int]$remainingMs)) {
            throw "Timed out waiting for Discord IPC (is Discord running and logged in?)"
        }
        $n = $task.Result
        if ($n -eq 0) { throw "Discord IPC pipe closed unexpectedly" }
        $offset += $n
    }
    return $buffer
}

# Tries discord-ipc-0 through discord-ipc-9 - Discord can bind to a
# different index if multiple clients (stable/PTB/canary) or a
# sandboxed install are present.
function Connect-DiscordIpc {
    param([string]$ClientId)

    for ($i = 0; $i -le 9; $i++) {
        $pipeName = "discord-ipc-$i"
        try {
            $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $pipe.Connect(300)

            $handshake = '{"v":1,"client_id":"' + $ClientId + '"}'
            Write-IpcFrame -Stream $pipe -Opcode $OP_HANDSHAKE -Json $handshake
            $response = Read-IpcFrame -Stream $pipe -TimeoutMs 3000

            $parsed = $response.Json | ConvertFrom-Json
            if ($parsed.evt -eq "READY") {
                Write-Log "Connected to Discord over $pipeName as $($parsed.data.user.username)"
                return $pipe
            } else {
                Write-Log "Unexpected handshake response on $pipeName - trying next pipe. ($($response.Json))"
                $pipe.Dispose()
            }
        } catch {
            if ($pipe) { try { $pipe.Dispose() } catch {} }
        }
    }
    return $null
}

# ===================================================================
#  SET_ACTIVITY
# ===================================================================

function Set-DiscordActivity {
    param($Pipe, $Stats)

    # Built via ConvertFromUtf32 rather than a literal emoji character in
    # this file - avoids any risk of Windows PowerShell 5.1 mis-decoding
    # a literal Unicode character depending on how the .ps1 is saved/read.
    $sparkle = [System.Char]::ConvertFromUtf32(0x2728)
    if ($Stats.shinies) {
        $details = "$($Stats.encounters_display) ($($Stats.shinies) $sparkle) | $($Stats.rate_per_hour)/h | $($Stats.fps)fps"
    } else {
        $details = "$($Stats.encounters_display) encounters | $($Stats.rate_per_hour)/h | $($Stats.fps)fps"
    }

    # The image itself is always the one fixed FallbackImage asset (see
    # the param block above for why there's no per-user dynamic image) -
    # but the tooltip text over it still reflects each user's own last
    # shiny, so it's not totally static/anonymous.
    $largeText = if ($Stats.image_text) { $Stats.image_text } else { "autocrystal" }

    $assets = @{ large_text = $largeText }
    if ($FallbackImage) { $assets.large_image = $FallbackImage }

    $activity = @{
        state = $Stats.state
        details = $details
        timestamps = @{ start = [int64]$Stats.session_start }
        assets = $assets
        instance = $false
    }

    if ($ButtonLabel -and $ButtonUrl) {
        $activity.buttons = @(@{ label = $ButtonLabel; url = $ButtonUrl })
    }

    # Named $activityArgs, NOT $args - $args is a PowerShell automatic
    # variable (extra unbound function parameters); reusing that name
    # for our own data would shadow it and is asking for subtle bugs.
    $activityArgs = @{
        pid = $PID
        activity = $activity
    }

    $frame = @{
        cmd = "SET_ACTIVITY"
        args = $activityArgs
        nonce = [guid]::NewGuid().ToString()
    } | ConvertTo-Json -Depth 10 -Compress

    Write-IpcFrame -Stream $Pipe -Opcode $OP_FRAME -Json $frame
    # Drain the response so it doesn't build up / interfere with the
    # next frame - we don't need its contents, just that we read it.
    Read-IpcFrame -Stream $Pipe -TimeoutMs 3000 | Out-Null
}

# ===================================================================
#  Main: local HTTP listener (same shape as discord_relay.ps1) feeding
#  a Discord IPC connection that reconnects automatically if lost.
# ===================================================================

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
$listener.Start()

Write-Log "Discord Rich Presence relay running on http://127.0.0.1:$ListenPort/"
Write-Log "Leave this window open alongside BizHawk (and discord_relay.ps1, if you use both)."
Write-Log "Connecting to Discord..."

# While Discord is unreachable, only retry connecting this often. Each
# attempt probes up to 10 pipes with a 300ms timeout apiece - about 3s
# when Discord isn't running at all - so retrying on every single stats
# update spent most of each one just failing to connect.
$ReconnectIntervalSeconds = 60
$nextConnectAttempt = Get-Date

$discordPipe = Connect-DiscordIpc -ClientId $ClientId
if (-not $discordPipe) {
    Write-Log "Couldn't connect to Discord yet - make sure the Discord desktop app is open and you're logged in."
    Write-Log "Will retry every $ReconnectIntervalSeconds seconds while stats come in."
    $nextConnectAttempt = (Get-Date).AddSeconds($ReconnectIntervalSeconds)
}
Write-Log ""

function Test-RelaysDisabled {
    if (-not $SettingsFile -or -not (Test-Path -LiteralPath $SettingsFile)) { return $false }
    try { return [bool]([System.IO.File]::ReadAllLines($SettingsFile) -contains "relaysdisabled=1") } catch { return $false }
}

# Next request, or $null when it's time to quit: -ExitWhenProcessGone's
# process has exited, or the relays were turned off in the launcher's
# Advanced Settings. Polls instead of blocking in GetContext() so those
# checks get to run.
function Wait-ForRequest {
    $pending = $listener.BeginGetContext($null, $null)
    while (-not $pending.AsyncWaitHandle.WaitOne(2000)) {
        if ($ExitWhenProcessGone -and -not (Get-Process -Name $ExitWhenProcessGone -ErrorAction SilentlyContinue)) {
            $script:exitReason = "$ExitWhenProcessGone has closed"
            return $null
        }
        if (Test-RelaysDisabled) {
            $script:exitReason = "the relays were turned off in Advanced Settings"
            return $null
        }
    }
    return $listener.EndGetContext($pending)
}

while ($listener.IsListening) {
    $context = Wait-ForRequest
    if (-not $context) {
        Write-Log "Stopping the relay - $exitReason."
        if ($discordPipe) { try { $discordPipe.Dispose() } catch {} }
        $listener.Stop()
        break
    }
    $request = $context.Request

    $reader = New-Object System.IO.StreamReader($request.InputStream)
    $body = $reader.ReadToEnd()
    $reader.Close()

    # Reply to BizHawk right away, BEFORE any Discord work. comm.httpPost
    # blocks the emulator until this response arrives, so replying only
    # after talking to Discord froze the bot for however long that took -
    # around 3s on every update whenever Discord wasn't open. Nothing is
    # sent back to the bot anyway, so there's no reason to make it wait.
    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("ok")
    $context.Response.ContentLength64 = $responseBytes.Length
    $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
    $context.Response.OutputStream.Close()

    # Same "payload=<urlencoded JSON>" wrapping BizHawk's comm.httpPost
    # always uses - see discord_relay.ps1's identical handling.
    if ($body -match '^payload=(.*)$') {
        $jsonPayload = [System.Web.HttpUtility]::UrlDecode($Matches[1])
    } else {
        $jsonPayload = [System.Web.HttpUtility]::UrlDecode($body)
    }

    $stats = $null
    try {
        $stats = $jsonPayload | ConvertFrom-Json
    } catch {
        Write-Log "Ignoring malformed stats payload: $_"
    }

    if ($stats) {
        try {
            if (-not $discordPipe -or -not $discordPipe.IsConnected) {
                if ($discordPipe) { try { $discordPipe.Dispose() } catch {} }
                $discordPipe = $null
                if ((Get-Date) -ge $nextConnectAttempt) {
                    $discordPipe = Connect-DiscordIpc -ClientId $ClientId
                    if (-not $discordPipe) {
                        $nextConnectAttempt = (Get-Date).AddSeconds($ReconnectIntervalSeconds)
                    }
                }
            }

            if ($discordPipe) {
                Set-DiscordActivity -Pipe $discordPipe -Stats $stats
                Write-Log "Updated presence: $($stats.state) | $($stats.encounters_display) encounters, $($stats.shinies) shinies, $($stats.rate_per_hour)/h, $($stats.fps)fps"
            } else {
                Write-Log "Skipped presence update - Discord not connected."
            }
        } catch {
            Write-Log "Failed to update Discord presence (will reconnect on the next update): $_"
            # A broken pipe on the next attempt will trigger a reconnect
            # above - don't crash the relay over one bad update. The
            # reconnect isn't throttled here: Discord was reachable a
            # moment ago, so it's likely to come right back.
            if ($discordPipe) { try { $discordPipe.Dispose() } catch {} }
            $discordPipe = $null
        }
    }
}
