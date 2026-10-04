# Refresh the OAuth token, reapply daemon patches (needed after Claude Science
# updates replace the exe), and restart Claude Science through the local proxy.
# Windows port of scripts/start-claude-science.sh.

param(
    [switch]$NoAuthPatch,
    [switch]$NoModelPatch
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$projectDir = Get-ProjectDir
$venvPython = Get-VenvPython
if (-not (Test-Path $venvPython)) { $venvPython = Find-Python }
if (-not $venvPython) {
    Write-Host "No Python runtime found. Run install-safe.ps1 first."
    exit 1
}

$csInfo = Get-ClaudeScienceInfo
if (-not $csInfo) {
    Write-Host "Claude Science installation not found under $Script:ClaudeScienceDir."
    exit 1
}

# 1. Make sure the proxy is up.
& (Join-Path $PSScriptRoot "start-proxy.ps1")
if ($LASTEXITCODE -ne 0) { exit 1 }

# 2. Refresh the fake OAuth token.
$encryptionKey = Join-Path $Script:ClaudeScienceUserDir "encryption.key"
if (Test-Path $encryptionKey) {
    & $venvPython (Join-Path $projectDir "setup-token.py") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: OAuth token refresh failed."
    }
}

# 3. Stop the app so the exe is patchable, then (re)apply patches.
#    The patch scripts are idempotent; after a Claude Science update they
#    detect the fresh binary and re-patch automatically.
if (Stop-ClaudeScience) {
    Write-Host "Stopped the running Claude Science."
}
if (-not $NoAuthPatch) {
    & $venvPython (Join-Path $PSScriptRoot "patch_daemon_auth.py") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: auth patch failed; Claude Science may still show logged-out."
    }
}
if (-not $NoModelPatch) {
    & $venvPython (Join-Path $PSScriptRoot "patch_daemon_models.py") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: model menu patch failed; Claude Science may show Claude model names."
    }
}

# 4. Start Claude Science with ANTHROPIC_BASE_URL pointing at the proxy.
$proxyUrl = Get-ProxyBaseUrl
$env:ANTHROPIC_BASE_URL = $proxyUrl
Start-Process -FilePath $csInfo.Exe -WorkingDirectory $csInfo.InstallDir

Write-Host "Started Claude Science with ANTHROPIC_BASE_URL=$(Get-MaskedProxyUrl $proxyUrl)"
