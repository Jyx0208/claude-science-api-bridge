# End-to-end verification of the local proxy: health, models, messages,
# recent requests, and optionally a real image request.
# Windows port of scripts/verify-proxy.sh.

param(
    [switch]$VerifyImage
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$baseUrl = Get-ProxyBaseUrl
Write-Host "Verifying proxy at $(Get-MaskedProxyUrl $baseUrl)"

# 1. health
Write-Host "1. health"
$health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 5
if ($health.status -ne "ok") {
    Write-Host "Health check returned unexpected status: $($health.status)"
    exit 1
}
$configured = $health.deepseek_configured -or $health.openai_configured -or $health.custom_configured
if (-not $configured) {
    Write-Host "No backend API key is configured. Configure config.json or the dashboard first."
    exit 1
}
Write-Host "status=ok backends configured"

# 2. models
Write-Host "2. models"
$models = Invoke-RestMethod -Uri "$baseUrl/v1/models" -TimeoutSec 5
if (-not $models.data -or @($models.data).Count -eq 0) {
    Write-Host "Model list is empty."
    exit 1
}
Write-Host "models=$(@($models.data).Count)"

# 3. messages
Write-Host "3. messages"
$body = @{
    model = "claude-sonnet-4-5"
    max_tokens = 32
    messages = @(@{ role = "user"; content = "Reply with OK." })
} | ConvertTo-Json -Depth 5
try {
    $message = Invoke-RestMethod -Uri "$baseUrl/v1/messages" -Method Post `
        -ContentType "application/json" -Body $body -TimeoutSec 60
} catch {
    Write-Host "Message request failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    exit 1
}
if ($message.type -eq "error" -or $message.error) {
    Write-Host "Message request returned an error:"
    $message | ConvertTo-Json -Depth 6 | Write-Host
    exit 1
}
if ($message.type -ne "message") {
    Write-Host "Unexpected response type: $($message.type)"
    exit 1
}
Write-Host "message_id=$($message.id) stop_reason=$($message.stop_reason)"

# 4. recent requests
Write-Host "4. recent requests"
$recent = Invoke-RestMethod -Uri "$baseUrl/api/recent-requests" -TimeoutSec 5
$success = @($recent.requests | Where-Object {
    ($_.backend -in @("deepseek", "openai", "custom")) -and ($_.status -eq "success")
})
if ($success.Count -eq 0) {
    Write-Host "No successful backend request found in recent requests."
    exit 1
}
Write-Host "successful_backend_requests=$($success.Count)"

# 5. optional image message
if ($VerifyImage) {
    Write-Host "5. image message"
    $pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsKZeS0BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEDgsqnc8OJg6Ln3AAAAAElFTkSuQmCC"
    $imageBody = @{
        model = "claude-opus-4-8"
        max_tokens = 32
        messages = @(@{
            role = "user"
            content = @(
                @{ type = "text"; text = "Look at the image. If the dominant color is red, reply exactly: red. Otherwise reply exactly: no." }
                @{ type = "image"; source = @{ type = "base64"; media_type = "image/png"; data = $pngB64 } }
            )
        })
    } | ConvertTo-Json -Depth 8
    try {
        $imageMessage = Invoke-RestMethod -Uri "$baseUrl/v1/messages" -Method Post `
            -ContentType "application/json" -Body $imageBody -TimeoutSec 90
    } catch {
        Write-Host "Image request failed: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
        exit 1
    }
    $text = (@($imageMessage.content) | Where-Object { $_.text } | ForEach-Object { $_.text }) -join " "
    if ($text -notmatch "(?i)\bred\b") {
        Write-Host "Image verification did not confirm red. Response: $text"
        exit 1
    }
    Write-Host "image_response=$($text.Substring(0, [Math]::Min(120, $text.Length)))"
}

Write-Host "proxy verification passed"
