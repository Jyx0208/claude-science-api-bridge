# Read-only diagnostics for the Windows Claude Science API Bridge setup.
# Windows port of scripts/doctor.sh. Never prints API keys.

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\common.ps1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$projectDir = Get-ProjectDir

Write-Section "System"
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("OS: {0} (build {1})" -f $os.Caption, $os.BuildNumber)
Write-Host "User: $env:USERNAME"
Write-Host "Project: $projectDir"

Write-Section "Python"
$venvPython = Get-VenvPython
if (Test-Path $venvPython) {
    Write-Host "venv python: $venvPython"
    & $venvPython --version
} else {
    Write-Host "venv python: missing (run install-safe.ps1)"
}
$sysPython = Find-Python
if ($sysPython) { Write-Host "system python: $sysPython" }
else { Write-Host "system python: missing" }

Write-Section "Claude Science"
$csInfo = Get-ClaudeScienceInfo
if ($csInfo) {
    Write-Host "Exe: $($csInfo.Exe)"
    Write-Host "Version: $($csInfo.Version)"
} else {
    Write-Host "Installation not found under $Script:ClaudeScienceDir"
}
$csProc = Get-Process -Name "claude-science" -ErrorAction SilentlyContinue
if ($csProc) {
    Write-Host "Running: yes ($($csProc.Count) process(es))"
} else {
    Write-Host "Running: no"
}

$port = Get-ProxyConfigValue "proxy_port"
if (-not $port) { $port = "9876" }
if ($csInfo -and $venvPython -and (Test-Path $venvPython)) {
    $env:DOCTOR_EXE = $csInfo.Exe
    $env:DOCTOR_PORT = "$port"
    & $venvPython -c "import os; d=open(os.environ['DOCTOR_EXE'],'rb').read(); p=os.environ['DOCTOR_PORT']; print('unpatched api.anthropic.com refs:', d.count(b'https://api.anthropic.com')); print('unpatched claude.ai refs:', d.count(b'https://claude.ai')); print('patched proxy refs:', d.count(('http://127.00.00.001:'+p).encode()) + d.count(('http://127.1:'+p).encode()))"
    $authBackup = "$($csInfo.Exe).byok-auth-original"
    $modelBackup = "$($csInfo.Exe).byok-model-original"
    Write-Host "auth backup: $(if (Test-Path $authBackup) { 'yes' } else { 'no' })"
    Write-Host "model backup: $(if (Test-Path $modelBackup) { 'yes' } else { 'no' })"
}

Write-Section "User Environment"
Write-Host "ANTHROPIC_BASE_URL (this session): $env:ANTHROPIC_BASE_URL"
$shortcut = Get-StartupShortcutPath
Write-Host "Startup shortcut: $(if (Test-Path $shortcut) { $shortcut } else { 'not registered' })"

Write-Section "Proxy Service"
$baseUrl = Get-ProxyBaseUrl
$health = Test-ProxyHealth -BaseUrl $baseUrl -TimeoutSec 3
if ($health) {
    Write-Host "Health: ok ($(Get-MaskedProxyUrl $baseUrl)/health)"
} else {
    Write-Host "Health: not responding at $(Get-MaskedProxyUrl $baseUrl)/health"
}
$pidFile = Get-ProxyPidFile
if (Test-Path $pidFile) {
    Write-Host "PID file: $(Get-Content $pidFile -ErrorAction SilentlyContinue)"
}
foreach ($checkPort in @($port, "9877", "443")) {
    try {
        $listeners = Get-NetTCPConnection -LocalPort $checkPort -State Listen -ErrorAction SilentlyContinue
        if ($listeners) {
            $owners = ($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ","
            Write-Host "port ${checkPort}: LISTEN (pid $owners)"
        }
    } catch { }
}

Write-Section "Files"
foreach ($rel in @("proxy.py", "setup-token.py", "config.json", "config.example.json")) {
    $path = Join-Path $projectDir $rel
    $state = if (Test-Path $path) { "ok  " } else { "miss" }
    Write-Host "$state $path"
}
$encKey = Join-Path $Script:ClaudeScienceUserDir "encryption.key"
$state = if (Test-Path $encKey) { "ok  " } else { "miss" }
Write-Host "$state $encKey"
$tokenDir = Join-Path $Script:ClaudeScienceUserDir ".oauth-tokens"
$tokens = @(Get-ChildItem $tokenDir -Filter "*.enc" -ErrorAction SilentlyContinue)
Write-Host "oauth tokens: $($tokens.Count) file(s)"

Write-Section "Config Summary"
$configFile = Join-Path $projectDir "config.json"
if (Test-Path $configFile) {
    try {
        $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
        Write-Host "default_backend=$($cfg.default_backend)"
        Write-Host "force_model=$($cfg.force_model)"
        Write-Host "model_list_mode=$($cfg.model_list_mode)"
        Write-Host "model_aliases=$(@($cfg.model_aliases).Count)"
        Write-Host "custom_upstream_mode=$($cfg.custom_upstream_mode)"
        Write-Host "custom_base_url=$($cfg.custom_base_url)"
        Write-Host "proxy_auth_mode=$($cfg.proxy_auth_mode)"
        Write-Host "custom_api_key=$(if ($cfg.custom_api_key) { 'yes' } else { 'no' })"
        Write-Host "deepseek_api_key=$(if ($cfg.deepseek_api_key) { 'yes' } else { 'no' })"
        Write-Host "openai_api_key=$(if ($cfg.openai_api_key) { 'yes' } else { 'no' })"
        Write-Host "reasoning_content_policy=$($cfg.reasoning_content_policy)"
    } catch {
        Write-Host "config.json not parseable"
    }
} else {
    Write-Host "config.json missing"
}

Write-Section "HTTP Checks"
try {
    $recent = Invoke-RestMethod -Uri "$baseUrl/api/recent-requests" -TimeoutSec 3
    $json = $recent | ConvertTo-Json -Depth 6 -Compress
    if ($json.Length -gt 2000) { $json = $json.Substring(0, 2000) }
    Write-Host $json
} catch {
    Write-Host "recent-requests: not reachable"
}

Write-Section "Recent Logs"
foreach ($name in @("proxy.log", "proxy-error.log")) {
    $logPath = Join-Path $Script:ClaudeScienceUserDir "logs\$name"
    if (Test-Path $logPath) {
        Write-Host "--- $name (last 20 lines) ---"
        Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
    }
}
