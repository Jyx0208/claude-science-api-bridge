# Stop the background Claude Science API Bridge proxy.

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\common.ps1"

$pidFile = Get-ProxyPidFile
$stopped = $false

if (Test-Path $pidFile) {
    $proxyPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($proxyPid) {
        $proc = Get-Process -Id $proxyPid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $proxyPid -Force -ErrorAction SilentlyContinue
            Write-Host "Stopped proxy process $proxyPid."
            $stopped = $true
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# Fallback: kill whatever listens on the proxy port.
$port = Get-ProxyConfigValue "proxy_port"
if (-not $port) { $port = if ($env:PROXY_PORT) { $env:PROXY_PORT } else { "9876" } }
try {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($listenerPid in $listeners) {
        $proc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match "python") {
            Stop-Process -Id $listenerPid -Force
            Write-Host "Stopped python process $listenerPid listening on port $port."
            $stopped = $true
        }
    }
} catch { }

if (-not $stopped) {
    Write-Host "No running proxy found."
    exit 0
}
Start-Sleep -Seconds 1
exit 0
