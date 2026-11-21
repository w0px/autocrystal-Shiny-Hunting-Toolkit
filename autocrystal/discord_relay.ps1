param(
    # Normally left empty: the webhook comes from the launcher's Discord
    # Settings (saved in $SettingsFile) and is re-read for every message,
    # so pasting a new one there takes effect right away, no restart. Pass
    # one here only to override that (e.g. testing by hand).
    [string]$DiscordWebhookUrl = "",

    # The launcher's settings file (gui_settings.lua) - the webhook URL
    # ("discordwebhook=") and the Advanced Settings switch that turns the
    # relays off ("relaysdisabled=1", which makes this relay quit).
    [string]$SettingsFile = (Join-Path $PSScriptRoot "modules\data\gui_settings.txt"),

    # Must match DISCORD_RELAY_URL in the hunting modules (5000 there too).
    [int]$ListenPort = 5000,

    # When set (launcher.lua passes "EmuHawk"), the relay quits by itself
    # once no process with this name is running anymore - so closing
    # BizHawk doesn't leave a hidden relay behind, holding the port with
    # whatever version of this script was current when it started. Left
    # empty when run by hand (start_relay.bat), so it can still be started
    # before BizHawk.
    [string]$ExitWhenProcessGone = "",

    # Where to also write everything this window shows - launcher.lua
    # passes one, since it starts the relay hidden. Rotated to "<name>.old"
    # past $MaxLogBytes, so it never grows without bound.
    [string]$LogFile = "",
    [long]$MaxLogBytes = 1MB,

    # The playthrough launcher's channels (the user, 2026-11-12: a shiny /
    # perfect DV channel, later a 24h log one): POST /send?ch=<name>&key=<id>
    # goes to the webhook saved as "<prefix><name>" (play_discord_shiny),
    # and the message it makes is remembered under <id>, so
    # POST /edit?ch=<name>&key=<id> can change it afterwards (the shiny
    # message says "Catching it..." and gets its result when the battle's
    # over). POST / is the hunting launcher's, as before.
    [string]$WebhookKeyPrefix = "play_discord_",

    # The offline test only: a stand-in for Discord on this PC
    # (http://127.0.0.1:<port>/api/webhooks/<id>/<token>), used for every
    # channel. Anything else here is refused.
    [string]$TestWebhookUrl = "",

    # The playthrough's messages as files (data/discord_spool.lua - the user,
    # 2026-11-20: "stutters are a nogo"; a web call held the emulator until
    # Discord answered): discord_<time>_<n>_<send|edit>_<channel>_<key>.json
    # in this folder, sent in name order like a /send or /edit, then
    # deleted. One Discord failed is tried again later (30 s, doubling, up to
    # 10 min apart; a key's later files wait for it), given up after a day
    # (renamed .failed). "": off.
    [string]$SpoolDir = "",

    # Self-healing for a run of years (the user, 2026-11-20): every couple of
    # seconds "<unix time> <pid> <version>" goes into this file, so the
    # launcher sees a relay that died, hung or is an old version and starts a
    # new one. "": none.
    [string]$HeartbeatFile = "",
    # Take the port over from another copy of this relay on it (an old version
    # or a hung one): that one is stopped first - only a powershell running
    # this same script on this same port.
    [switch]$Takeover
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

# One "key=value" setting from the launcher's settings file, or "" if it
# isn't there (or the file can't be read right now - the launcher may be
# writing it at this exact moment; the next read will get it).
function Get-LauncherSetting([string]$key) {
    if (-not $SettingsFile -or -not (Test-Path -LiteralPath $SettingsFile)) { return "" }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($SettingsFile)) {
            if ($line.StartsWith("$key=")) { return $line.Substring($key.Length + 1).Trim() }
        }
    } catch {}
    return ""
}

function Get-WebhookUrl {
    if ($DiscordWebhookUrl) { return $DiscordWebhookUrl }
    return Get-LauncherSetting "discordwebhook"
}

# Only ever forward to a real Discord webhook - so this relay can't be
# used to send data anywhere else, whatever ends up in the settings.
$WebhookPattern = '^https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+$'

# Just the webhook's ID, never the token after it - the token is what
# lets anyone post to the channel, and logs end up in screenshots.
function Get-WebhookId([string]$url) {
    $parts = $url.TrimEnd('/').Split('/')
    if ($parts.Count -ge 2) { return $parts[-2] }
    return "?"
}

Add-Type -AssemblyName System.Net.Http

# Images an embed can show without a public URL (e.g. the Egg module's egg
# picture): the Lua side puts "attachment://<file name>" where an image URL
# would go, and that file from data\sprites gets uploaded along with the
# message - Discord's own way of showing an attached image inside an embed.
# Only plain file names straight from that one folder are ever read, so a
# message can't make this relay send anything else from this PC - plus the
# Pokemon sprites made for Discord's corner (modules/data/discord_sprite.lua):
# "shiny_101.gif" is data\sprites\animated_discord\shiny\101.gif.
$AttachmentDir = Join-Path $PSScriptRoot "data\sprites"

# The files a payload refers to that exist. Any that don't get their
# thumbnail dropped from the JSON instead - Discord would refuse the whole
# message over a missing attachment, and the text matters more.
function Resolve-Attachments([string]$json) {
    $files = @()
    foreach ($m in [regex]::Matches($json, 'attachment://([A-Za-z0-9_-]+\.(png|gif))')) {
        $name = $m.Groups[1].Value
        if ($files | Where-Object { $_.Name -eq $name }) { continue }
        if ($name -match '^(normal|shiny)_(\d{1,3})\.gif$') {
            $path = Join-Path $AttachmentDir ("animated_discord\{0}\{1}.gif" -f $Matches[1], $Matches[2])
        } elseif ($name -match '^big(normal|shiny)_(\d{1,3})\.gif$') {
            # (the shiny channel's big centred sprite - tools/scale_sprites.ps1)
            $path = Join-Path $AttachmentDir ("animated_discord_big\{0}\{1}.gif" -f $Matches[1], $Matches[2])
        } else {
            $path = Join-Path $AttachmentDir $name
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $files += [pscustomobject]@{ Name = $name; Path = $path }
        } else {
            Write-Log "Attachment $name isn't in $AttachmentDir - sending without that picture."
            $thumb = '"(thumbnail|image)"\s*:\s*\{\s*"url"\s*:\s*"attachment://' + [regex]::Escape($name) + '"\s*\}'
            if ($json -match ($thumb + '\s*,')) { $json = $json -replace ($thumb + '\s*,'), '' }
            else { $json = $json -replace ('\s*,\s*' + $thumb), '' }
        }
    }
    return [pscustomobject]@{ Json = $json; Files = $files }
}

# multipart/form-data: the JSON as "payload_json", then each file as
# files[0], files[1], ... under its own name (what attachment:// matches).
function Send-WithAttachments([string]$uri, [string]$json, $files) {
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $form = [System.Net.Http.MultipartFormDataContent]::new()
        $form.Add([System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json"), "payload_json")
        for ($i = 0; $i -lt $files.Count; $i++) {
            $part = [System.Net.Http.ByteArrayContent]::new([System.IO.File]::ReadAllBytes($files[$i].Path))
            $type = if ($files[$i].Name -like "*.gif") { "image/gif" } else { "image/png" }
            $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($type)
            $form.Add($part, "files[$i]", $files[$i].Name)
        }
        $response = $client.PostAsync($uri, $form).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP {0}: {1}" -f [int]$response.StatusCode, $response.Content.ReadAsStringAsync().GetAwaiter().GetResult())
        }
    } finally {
        $client.Dispose()
    }
}

# ------------------------------------------------ the playthrough's channels
# (/send and /edit - see $WebhookKeyPrefix)

# A channel's webhook: the test stand-in, else "<prefix><channel>" from the settings.
$TestPattern = '^http://127\.0\.0\.1:\d+/api/webhooks/\d+/[\w-]+$'
function Get-ChannelWebhook([string]$channel) {
    if ($TestWebhookUrl) { return $TestWebhookUrl }
    # ("main": the hunting launcher's own webhook - its queued messages,
    # data/discord_queue.lua)
    if ($channel -eq "main") { return Get-WebhookUrl }
    return Get-LauncherSetting ($WebhookKeyPrefix + $channel)
}

# The messages made by /send, by their key: key -> Discord's message id.
# Only this run's (a restarted relay sends a new message instead of an edit);
# the oldest go past $KeepSent.
$Sent = @{}
$SentOrder = New-Object System.Collections.Generic.List[string]
$KeepSent = 50

# ------------------------------------------------ the spool (see $SpoolDir)
$SpoolRetry = @{}      # file name -> when it may be tried again
$SpoolTries = @{}      # file name -> failed tries
$SpoolMaxAge = 86400
function Process-Spool {
    if (-not $SpoolDir -or -not (Test-Path -LiteralPath $SpoolDir)) { return }
    $files = @(Get-ChildItem -LiteralPath $SpoolDir -Filter "discord_*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { return }
    $blocked = @{}
    foreach ($file in $files) {
        $now = Get-Date
        if ($file.Name -notmatch '^discord_\d+_\d+_(send|edit)_([a-z]{1,16})_([A-Za-z0-9_-]{1,40})\.json$') {
            Write-Log "Spool: $($file.Name) isn't a message file - moved aside (.bad)."
            Move-Item -LiteralPath $file.FullName -Destination ($file.FullName + ".bad") -Force -ErrorAction SilentlyContinue
            continue
        }
        $action, $channel, $key = $Matches[1], $Matches[2], $Matches[3]
        if ($blocked[$key]) { continue }
        if ($SpoolRetry.ContainsKey($file.Name) -and $now -lt $SpoolRetry[$file.Name]) { $blocked[$key] = $true; continue }
        if (($now - $file.LastWriteTime).TotalSeconds -gt $SpoolMaxAge) {
            Write-Log "Spool: gave up on $($file.Name) after a day of tries (renamed .failed)."
            Move-Item -LiteralPath $file.FullName -Destination ($file.FullName + ".failed") -Force -ErrorAction SilentlyContinue
            $SpoolRetry.Remove($file.Name); $SpoolTries.Remove($file.Name)
            continue
        }
        $json = $null
        try { $json = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) } catch { $blocked[$key] = $true; continue }
        $answer = Handle-Channel $action $channel $key $json
        if ($answer -eq "failed") {
            $n = 1 + [int]$SpoolTries[$file.Name]
            $SpoolTries[$file.Name] = $n
            $wait = [int][Math]::Min(600, 30 * [Math]::Pow(2, $n - 1))
            $SpoolRetry[$file.Name] = $now.AddSeconds($wait)
            $blocked[$key] = $true
            Write-Log "Spool: $($file.Name) failed - trying again in $wait s."
        } else {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $SpoolRetry.Remove($file.Name); $SpoolTries.Remove($file.Name)
            Write-Log "Spool: $($file.Name) - $answer."
        }
    }
}

# A request to Discord: POST (a new message) or PATCH (an edit) with the
# JSON and its files. Returns Discord's reply (the message, as JSON).
# With files: they're listed as the message's attachments, which for an
# edit REPLACES the old ones (else the old picture would stay on as a loose
# file under the new one).
function Invoke-Discord([string]$method, [string]$uri, [string]$json, $files) {
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($method), $uri)
        if ($files.Count -gt 0) {
            if ($json -notmatch '"attachments"\s*:') {
                $list = @()
                for ($i = 0; $i -lt $files.Count; $i++) { $list += ('{{"id":{0},"filename":"{1}"}}' -f $i, $files[$i].Name) }
                $json = $json.TrimEnd()
                $json = $json.Substring(0, $json.Length - 1) + ',"attachments":[' + ($list -join ",") + ']}'
            }
            $form = [System.Net.Http.MultipartFormDataContent]::new()
            $form.Add([System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json"), "payload_json")
            for ($i = 0; $i -lt $files.Count; $i++) {
                $part = [System.Net.Http.ByteArrayContent]::new([System.IO.File]::ReadAllBytes($files[$i].Path))
                $type = if ($files[$i].Name -like "*.gif") { "image/gif" } else { "image/png" }
                $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($type)
                $form.Add($part, "files[$i]", $files[$i].Name)
            }
            $req.Content = $form
        } else {
            $req.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
        }
        $response = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw ("HTTP {0}: {1}" -f [int]$response.StatusCode, $text) }
        return $text
    } finally {
        $client.Dispose()
    }
}

# /send or /edit: returns what to answer the bot ("sent", "edited", or why not).
function Handle-Channel([string]$action, [string]$channel, [string]$key, [string]$json) {
    if ($channel -notmatch '^[a-z]{1,16}$' -or $key -notmatch '^[A-Za-z0-9_-]{1,40}$') { return "refused: bad channel or key" }
    $webhook = Get-ChannelWebhook $channel
    if (-not $webhook) { return "off: no webhook for the $channel channel" }
    $ok = if ($TestWebhookUrl) { $webhook -match $TestPattern } else { $webhook -match $WebhookPattern }
    if (-not $ok) { return "refused: the $channel channel's webhook isn't a Discord webhook URL" }
    # (a /send with a key this relay already sent: done - a retry after a
    # time-out never posts the same message twice; the daily log, 2026-11-20)
    if ($action -eq "send" -and $Sent[$key]) { Write-Log ("Already sent the {0} message {1}." -f $channel, $key); return "sent" }
    $attachments = Resolve-Attachments $json
    $id = $Sent[$key]
    try {
        if ($action -eq "edit" -and $id) {
            # (${webhook} in braces: see the long note on ?wait=true below)
            [void](Invoke-Discord "PATCH" "${webhook}/messages/${id}" $attachments.Json $attachments.Files)
            Write-Log ("Edited the {0} message {1} ({2})." -f $channel, $key, $id)
            return "edited"
        }
        if ($action -eq "edit") {
            # (this relay never sent it - started since: a new message, without the ping again)
            $attachments.Json = $attachments.Json -replace '^\s*\{\s*"content"\s*:\s*"(\\.|[^"\\])*"\s*,', '{'
        }
        $reply = Invoke-Discord "POST" "${webhook}?wait=true" $attachments.Json $attachments.Files
        $newId = $null
        try { $newId = ($reply | ConvertFrom-Json).id } catch {}
        if ($newId) {
            if (-not $Sent.ContainsKey($key)) { $SentOrder.Add($key) }
            $Sent[$key] = [string]$newId
            while ($SentOrder.Count -gt $KeepSent) { $Sent.Remove($SentOrder[0]); $SentOrder.RemoveAt(0) }
        }
        Write-Log ("Sent the {0} message {1} ({2})." -f $channel, $key, $newId)
        return "sent"
    } catch {
        Write-Log "Failed to send the $channel message ${key}: $_"
        # (a new message whose answer was lost - a time-out, a dropped
        # connection, a 5xx: Discord may have posted it; never sent again, or
        # a shiny's ping could come twice. An edit is safe to try again.)
        $e = $_.Exception; $unsure = $false
        while ($e) { if ($e -is [System.Threading.Tasks.TaskCanceledException] -or $e -is [System.IO.IOException]) { $unsure = $true }; $e = $e.InnerException }
        if (-not ($action -eq "edit" -and $id) -and ($unsure -or "$_" -match 'HTTP 5\d\d')) {
            return "unknown: it may have gone out - not sent again"
        }
        return "failed"
    }
}


# ---------------------------------------------- self-healing (see $HeartbeatFile)
$RelayVersion = 2
$script:lastBeat = [DateTime]::MinValue
function Write-Heartbeat {
    if (-not $HeartbeatFile) { return }
    if (((Get-Date) - $script:lastBeat).TotalSeconds -lt 2) { return }
    $script:lastBeat = Get-Date
    try { [System.IO.File]::WriteAllText($HeartbeatFile, ("{0} {1} {2}" -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $PID, $RelayVersion)) } catch {}
}
function Invoke-Takeover {
    if (-not $Takeover) { return }
    $me = Split-Path -Leaf $PSCommandPath
    $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$me*" -and
            ($_.CommandLine -match "-ListenPort\s+$ListenPort(\s|$)" -or ($ListenPort -eq 5000 -and $_.CommandLine -notmatch "-ListenPort")) })
    # (no -ListenPort on its line: the default port, 5000 - how the launcher
    # has always started it)
    foreach ($o in $others) {
        Write-Log "Taking over port $ListenPort - stopping the relay before me (pid $($o.ProcessId))."
        try { Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop } catch { Write-Log "Couldn't stop pid $($o.ProcessId): $_" }
    }
    if ($others.Count -gt 0) { Start-Sleep -Milliseconds 800 }
}

Invoke-Takeover
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
# (a relay already on the port - BizHawk not restarted: this one ends
# before it says "running", so the launcher never takes it for one that
# reads the spool; review, 2026-11-20)
try { $listener.Start() } catch { Write-Log "Port $ListenPort is taken (another relay is running) - this one ends: $_"; exit 1 }

# ("(spool" on this line: the launcher reads it to know this relay takes files)
Write-Log ("Discord relay running on http://127.0.0.1:$ListenPort/ (only reachable from this PC)" + $(if ($SpoolDir) { " (spool: $SpoolDir)." } else { "." }))
Write-Log "Leave this window open while using the shiny-hunting bot."
$startupWebhook = Get-WebhookUrl
$shinyWebhook = Get-ChannelWebhook "shiny"
if ($TestWebhookUrl) {
    Write-Log "TEST: every channel goes to the stand-in at $TestWebhookUrl."
} elseif ($shinyWebhook) {
    Write-Log "Shiny channel: webhook $(Get-WebhookId $shinyWebhook) (re-read from the launcher's settings for every message)."
}
if ($startupWebhook) {
    Write-Log "Forwarding to Discord webhook $(Get-WebhookId $startupWebhook) - re-read from the launcher's settings for every message."
} else {
    Write-Log "No Discord webhook set yet - paste yours into the launcher's Discord Settings (no restart needed)."
}
Write-Log ""

# Next request, or $null when it's time to quit: -ExitWhenProcessGone's
# process has exited, or the relays were turned off in the launcher's
# Advanced Settings. Polls instead of blocking in GetContext() so those
# checks get to run.
function Wait-ForRequest {
    $pending = $listener.BeginGetContext($null, $null)
    # (every half second: the spool's files, then the quit checks)
    Write-Heartbeat
    while (-not $pending.AsyncWaitHandle.WaitOne(500)) {
        Write-Heartbeat
        try { Process-Spool } catch { Write-Log "Spool: $_" }
        if ($ExitWhenProcessGone -and -not (Get-Process -Name $ExitWhenProcessGone -ErrorAction SilentlyContinue)) {
            $script:exitReason = "$ExitWhenProcessGone has closed"
            return $null
        }
        if ((Get-LauncherSetting "relaysdisabled") -eq "1") {
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
        $listener.Stop()
        break
    }
    $request = $context.Request

    $reader = New-Object System.IO.StreamReader($request.InputStream)
    $body = $reader.ReadToEnd()
    $reader.Close()

    # BizHawk's comm.httpPost wraps the payload as a URL-encoded form
    # field named "payload", e.g. payload=%7B%22content%22...%7D
    # The decoded value is already the full JSON object our Lua script
    # built, so we forward it as-is rather than re-wrapping it.
    if ($body -match '^payload=(.*)$') {
        $jsonPayload = [System.Web.HttpUtility]::UrlDecode($Matches[1])
    } else {
        $jsonPayload = [System.Web.HttpUtility]::UrlDecode($body)
    }

    Write-Log "Received: $jsonPayload"

    # The playthrough's channels: /send, /edit (see Handle-Channel).
    $path = $request.Url.AbsolutePath.TrimEnd('/')
    if ($path -eq "/send" -or $path -eq "/edit") {
        $answer = "refused: POST only"
        if ($request.HttpMethod -eq "POST") {
            $answer = Handle-Channel $path.Substring(1) ([string]$request.QueryString["ch"]) ([string]$request.QueryString["key"]) $jsonPayload
        }
        Write-Log ""
        $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($answer)
        $context.Response.ContentLength64 = $responseBytes.Length
        $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
        $context.Response.OutputStream.Close()
        continue
    }

    $webhook = Get-WebhookUrl
    if (-not $webhook) {
        Write-Log "Not forwarded - no Discord webhook set. Paste yours into the launcher's Discord Settings."
    } elseif ($webhook -notmatch $WebhookPattern) {
        Write-Log "Not forwarded - the saved webhook isn't a Discord webhook URL (https://discord.com/api/webhooks/...)."
    } else { try {
        # Encode to UTF-8 bytes explicitly before sending, rather than
        # passing the string straight to -Body. PowerShell's automatic
        # string-to-bytes conversion for web request bodies isn't
        # reliably UTF-8 (it can fall back to a codepage like Latin-1
        # that can't represent characters such as the shiny sparkle
        # emoji), which silently turned it into "?" here even though it
        # arrived correctly from the sender.
        $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)

        # wait=true: a real report showed a "caught!" embed rendered
        # ABOVE (i.e. apparently delivered before) its own earlier
        # "found! attempting to catch" embed for the same encounter, even
        # though wild.lua/fishing.lua/headbutt.lua send them from a single
        # Lua thread strictly in order, and comm.httpPost blocks until
        # this relay responds. Root cause traced to Discord's own webhook
        # API: WITHOUT ?wait=true it replies 204 as soon as the POST is
        # merely accepted, before the message is actually created - so two
        # embeds fired moments apart can finish being created on Discord's
        # side out of order even though they were POSTed in order (per
        # Discord's docs: wait=true "waits for server confirmation of
        # message send before response"). Since this relay only handles
        # one request at a time (single-threaded GetContext() loop below)
        # and doesn't reply "ok" to BizHawk until this call returns, adding
        # wait=true here means the SECOND embed's POST to Discord can't
        # even be issued until the first one is confirmed fully created -
        # closing the one remaining gap in the ordering guarantee.
        # NOTE: must use ${webhook} (curly-braced), NOT bare $webhook,
        # immediately before a literal "?" or "&" here.
        # CONFIRMED via direct reproduction in PowerShell 7.4: inside a
        # double-quoted string, "$DiscordWebhookUrl?wait=true" silently
        # evaluates to just "=true" - PowerShell's parser swallows the
        # variable reference AND the "?wait" text together instead of
        # stopping the variable name at "?" and treating the rest as
        # literal (which is what happens correctly with the curly-braced
        # form). That silently turned every single relayed message since
        # this wait=true fix was added into a request to the URI "=true" -
        # which fails to parse (no hostname), so every notification was
        # failing with "Invalid URI: The hostname could not be parsed"
        # with NOTHING actually reaching Discord. Verified fixed by
        # printing/parsing the resulting URI directly - curly braces make
        # PowerShell stop the variable name exactly at the "}" and treat
        # everything after it (the "?wait=true" or "&wait=true") as plain
        # literal text, same as intended originally.
        $requestUri = "${webhook}?wait=true"
        $attachments = Resolve-Attachments $jsonPayload
        if ($attachments.Files.Count -gt 0) {
            Send-WithAttachments $requestUri $attachments.Json $attachments.Files
            Write-Log ("Forwarded to Discord successfully (with {0})." -f (($attachments.Files | ForEach-Object { $_.Name }) -join ", "))
        } else {
            if ($attachments.Json -ne $jsonPayload) { $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($attachments.Json) }
            Invoke-RestMethod -Uri $requestUri -Method Post -Body $utf8Bytes -ContentType "application/json; charset=utf-8" | Out-Null
            Write-Log "Forwarded to Discord successfully."
        }
    } catch {
        Write-Log "Failed to forward to Discord: $_"
    } }
    Write-Log ""

    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("ok")
    $context.Response.ContentLength64 = $responseBytes.Length
    $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
    $context.Response.OutputStream.Close()
}
