# Shared helpers for the Windows scripts. PowerShell 5.1 compatible, ASCII only.
# Dot-source this file: . "$PSScriptRoot\common.ps1"

$Script:ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Script:ClaudeScienceDir = Join-Path $env:LOCALAPPDATA "Programs\ClaudeScience"
$Script:ClaudeScienceUserDir = Join-Path $HOME ".claude-science"
$Script:StartupShortcutName = "Claude Science API Bridge.lnk"

function Get-ProjectDir {
    return $Script:ProjectDir
}

function Get-VenvPython {
    return (Join-Path $Script:ProjectDir ".venv\Scripts\python.exe")
}

function Find-Python {
    # Returns the path of a usable Python 3 interpreter.
    # Order: $env:PYTHON, py -3, python, python3.
    $candidates = @()
    if ($env:PYTHON) { $candidates += $env:PYTHON }
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $probe = & py -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe) { $candidates += ($probe | Select-Object -First 1) }
    }
    foreach ($name in @("python", "python3")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $candidates += $cmd.Source }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try {
            $version = & $candidate -c "import sys; print(sys.version_info >= (3, 9))" 2>$null
            if ($LASTEXITCODE -eq 0 -and $version -match "True") {
                return $candidate
            }
        } catch {
            continue
        }
    }
    return $null
}

function Get-ClaudeScienceInfo {
    # Returns a hashtable with InstallDir, Exe, Version (from install.json), or $null.
    $installJson = Join-Path $Script:ClaudeScienceDir "install.json"
    $info = @{}
    if (Test-Path $installJson) {
        try {
            $json = Get-Content $installJson -Raw | ConvertFrom-Json
            if ($json.install_dir) { $info.InstallDir = $json.install_dir }
            if ($json.version) { $info.Version = $json.version }
        } catch {
        }
    }
    $installDir = $info.InstallDir
    if (-not $installDir) { $installDir = $Script:ClaudeScienceDir }
    $exe = Join-Path $installDir "claude-science.exe"
    if (Test-Path $exe) {
        $info.InstallDir = $installDir
        $info.Exe = $exe
        return $info
    }
    return $null
}

function Stop-ClaudeScience {
    # Kill any running Claude Science processes so the exe is not locked.
    $procs = Get-Process -Name "claude-science" -ErrorAction SilentlyContinue
    if (-not $procs) { return $false }
    foreach ($proc in $procs) {
        try { & taskkill /PID $proc.Id /F /T 2>$null | Out-Null } catch { }
    }
    Start-Sleep -Seconds 2
    return $true
}

function Get-ProxyConfigValue {
    param([string]$Key)
    $configFile = Join-Path $Script:ProjectDir "config.json"
    if (-not (Test-Path $configFile)) { return $null }
    try {
        $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
        return $cfg.$Key
    } catch {
        return $null
    }
}

function Get-ProxyBaseUrl {
    # Base URL including the path-secret when proxy_auth_mode is required.
    param([string]$HostOverride, [string]$PortOverride)
    $host_ = $HostOverride
    if (-not $host_) { $host_ = Get-ProxyConfigValue "proxy_host" }
    if (-not $host_) { $host_ = "127.0.0.1" }
    $port = $PortOverride
    if (-not $port) { $port = Get-ProxyConfigValue "proxy_port" }
    if (-not $port) { $port = if ($env:PROXY_PORT) { $env:PROXY_PORT } else { "9876" } }
    $url = "http://$($host_):$port"
    $token = Get-ProxyConfigValue "proxy_auth_token"
    $mode = Get-ProxyConfigValue "proxy_auth_mode"
    if ($token -and $mode -eq "required") { $url = "$url/$token" }
    return $url
}

function Get-MaskedProxyUrl {
    param([string]$Url)
    if ($Url -match "^(https?://[^/]+/).+$") {
        return ($Matches[1] + "****")
    }
    return $Url
}

function Test-ProxyHealth {
    param([string]$BaseUrl, [int]$TimeoutSec = 5)
    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec $TimeoutSec
        return $resp
    } catch {
        return $null
    }
}

function Get-ProxyPidFile {
    return (Join-Path $Script:ClaudeScienceUserDir "proxy.pid")
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath("Startup")
    return (Join-Path $startupDir $Script:StartupShortcutName)
}

function Write-Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "== $Name =="
}
