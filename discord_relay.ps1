param(
    [string]$DiscordWebhookUrl = "YOURWEBHOOKHERE"
)

Add-Type -AssemblyName System.Web

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:5000/")
$listener.Start()

Write-Host "Discord relay running on http://127.0.0.1:5000/"
Write-Host "Leave this window open while using the shiny-hunting bot."
Write-Host "Forwarding to: $DiscordWebhookUrl"
Write-Host ""

while ($listener.IsListening) {
    $context = $listener.GetContext()
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

    Write-Host "Received: $jsonPayload"

    try {
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
        # NOTE: must use ${DiscordWebhookUrl} (curly-braced), NOT bare
        # $DiscordWebhookUrl, immediately before a literal "?" or "&" here.
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
        $requestUri = if ($DiscordWebhookUrl -match '\?') { "${DiscordWebhookUrl}&wait=true" } else { "${DiscordWebhookUrl}?wait=true" }
        Invoke-RestMethod -Uri $requestUri -Method Post -Body $utf8Bytes -ContentType "application/json; charset=utf-8" | Out-Null
        Write-Host "Forwarded to Discord successfully."
    } catch {
        Write-Host "Failed to forward to Discord: $_"
    }
    Write-Host ""

    $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("ok")
    $context.Response.ContentLength64 = $responseBytes.Length
    $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
    $context.Response.OutputStream.Close()
}
