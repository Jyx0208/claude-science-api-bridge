# Start the Claude Science API Bridge proxy in the background (hidden window).
# Mirrors the Linux fallback service: PID file + logs under ~/.claude-science.

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

$projectDir = Get-ProjectDir
$venvPython = Get-VenvPython
if (-not (Test-Path $venvPython)) { $venvPython = Find-Python }
if (-not $venvPython) {
    Write-Host "No Python runtime found. Run install-safe.ps1 first."
    exit 1
}

$host_ = Get-ProxyConfigValue "proxy_host"
if (-not $host_) { $host_ = if ($env:PROXY_HOST) { $env:PROXY_HOST } else { "127.0.0.1" } }
$port = Get-ProxyConfigValue "proxy_port"
if (-not $port) { $port = if ($env:PROXY_PORT) { $env:PROXY_PORT } else { "9876" } }
$baseUrl = Get-ProxyBaseUrl -HostOverride $host_ -PortOverride $port

# Already healthy? Nothing to do.
if (Test-ProxyHealth -BaseUrl $baseUrl -TimeoutSec 3) {
    Write-Host "Proxy is already running at $(Get-MaskedProxyUrl $baseUrl)"
    exit 0
}

# Stale PID file?
$pidFile = Get-ProxyPidFile
if (Test-Path $pidFile) {
    $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Proxy process $($oldPid) exists but health check failed; waiting for it to come up..."
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                if (Test-ProxyHealth -BaseUrl $baseUrl -TimeoutSec 3) {
                    Write-Host "Proxy is running at $(Get-MaskedProxyUrl $baseUrl)"
                    exit 0
                }
            }
            Write-Host "Proxy process is running but not healthy. Check $Script:ClaudeScienceUserDir\logs\proxy-error.log"
            exit 1
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

$logDir = Join-Path $Script:ClaudeScienceUserDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdoutLog = Join-Path $logDir "proxy.log"
$stderrLog = Join-Path $logDir "proxy-error.log"

$env:PROXY_HOST = $host_
$env:PROXY_PORT = "$port"

# Hidden-window console python: keeps valid std handles so print/logging work,
# while staying invisible on the desktop.
$proc = Start-Process -FilePath $venvPython `
    -ArgumentList ('"' + (Join-Path $projectDir "proxy.py") + '"') `
    -WorkingDirectory $projectDir -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
Set-Content -Path $pidFile -Value $proc.Id

$deadline = (Get-Date).AddSeconds(30)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-ProxyHealth -BaseUrl $baseUrl -TimeoutSec 3) { $healthy = $true; break }
    $stillAlive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $stillAlive) { break }
}
if ($healthy) {
    # The venv python.exe is a launcher that re-execs the base interpreter,
    # so the real listener PID can differ from $proc.Id. Record the listener.
    try {
        $listenerPid = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique | Select-Object -First 1
        if ($listenerPid) { Set-Content -Path $pidFile -Value $listenerPid }
    } catch { }
    Write-Host "Proxy started (PID $(Get-Content $pidFile)) at $(Get-MaskedProxyUrl $baseUrl)"
    Write-Host "Logs: $stdoutLog"
    exit 0
}
Write-Host "Proxy failed to become healthy. Check $stderrLog"
exit 1
