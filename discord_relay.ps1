param(
    # Fill in your own Discord webhook URL here (Server Settings ->
    # Integrations -> Webhooks -> New Webhook -> Copy URL), or pass it
    # with -DiscordWebhookUrl when launching this script instead of
    # hardcoding it.
    [string]$DiscordWebhookUrl = "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"
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
        Invoke-RestMethod -Uri $DiscordWebhookUrl -Method Post -Body $utf8Bytes -ContentType "application/json; charset=utf-8" | Out-Null
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
