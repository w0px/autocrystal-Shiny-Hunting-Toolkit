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
# message can't make this relay send anything else from this PC.
$AttachmentDir = Join-Path $PSScriptRoot "data\sprites"

# The files a payload refers to that exist. Any that don't get their
# thumbnail dropped from the JSON instead - Discord would refuse the whole
# message over a missing attachment, and the text matters more.
function Resolve-Attachments([string]$json) {
    $files = @()
    foreach ($m in [regex]::Matches($json, 'attachment://([A-Za-z0-9_-]+\.(png|gif))')) {
        $name = $m.Groups[1].Value
        if ($files | Where-Object { $_.Name -eq $name }) { continue }
        $path = Join-Path $AttachmentDir $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $files += [pscustomobject]@{ Name = $name; Path = $path }
        } else {
            Write-Log "Attachment $name isn't in $AttachmentDir - sending without that picture."
            $thumb = '"thumbnail"\s*:\s*\{\s*"url"\s*:\s*"attachment://' + [regex]::Escape($name) + '"\s*\}'
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

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
$listener.Start()

Write-Log "Discord relay running on http://127.0.0.1:$ListenPort/ (only reachable from this PC)."
Write-Log "Leave this window open while using the shiny-hunting bot."
$startupWebhook = Get-WebhookUrl
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
    while (-not $pending.AsyncWaitHandle.WaitOne(2000)) {
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
