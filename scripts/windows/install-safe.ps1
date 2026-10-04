# Windows safe installer for Claude Science API Bridge.
# Mirrors scripts/install-safe.sh: venv, config, OAuth token, daemon patches,
# Startup-folder auto-start, and a health check.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\install-safe.ps1
#   powershell ... -File install-safe.ps1 -NoStartup -NoModelPatch
#
# Optional switches:
#   -NoStartup     Do not register the Startup-folder auto-start shortcut.
#   -NoAuthPatch   Skip the daemon auth binary patch.
#   -NoModelPatch  Skip the daemon model menu patch.
#   -Python PATH   Use a specific python.exe as the bootstrap interpreter.
#   -EnvFile PATH  Load KEY=VALUE overrides from this file
#                  (default: .env.tmp or .env in the project root, if present).

param(
    [switch]$NoStartup,
    [switch]$NoAuthPatch,
    [switch]$NoModelPatch,
    [string]$Python = "",
    [string]$EnvFile = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\common.ps1"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$projectDir = Get-ProjectDir
$venvPython = Get-VenvPython

# --- Load optional .env file (fills only variables not already set) -------
if (-not $EnvFile) {
    foreach ($name in @(".env.tmp", ".env")) {
        $candidate = Join-Path $projectDir $name
        if (Test-Path $candidate) { $EnvFile = $candidate; break }
    }
}
if ($EnvFile -and (Test-Path $EnvFile)) {
    Write-Host "Loading env overrides from: $EnvFile"
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\r?$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()
            # Strip bash-style trailing line continuations and outer quotes,
            # e.g.  KEY="value" \   or   KEY='[{"id": ...}]'
            $value = $value -replace '\s*\\$', ''
            $value = $value.Trim()
            if ($value.Length -ge 2) {
                if ($value.StartsWith('"') -and $value.EndsWith('"')) {
                    $value = $value.Substring(1, $value.Length - 2)
                } elseif ($value.StartsWith("'") -and $value.EndsWith("'")) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }
            if (-not (Get-Item -Path "Env:$key" -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Env:$key" -Value $value
            }
        }
    }
}

# --- Resolve bootstrap Python and venv ------------------------------------
if ($Python) {
    $bootstrapPython = $Python
} else {
    $bootstrapPython = Find-Python
}
if (-not $bootstrapPython) {
    Write-Host "python3 not found. Install Python 3.9+ from python.org first."
    exit 1
}
Write-Host "Using bootstrap Python: $bootstrapPython"

if (Test-Path $venvPython) {
    $runtimePython = $venvPython
} else {
    Write-Host "Creating virtual environment..."
    & $bootstrapPython -m venv (Join-Path $projectDir ".venv")
    if (Test-Path $venvPython) {
        $runtimePython = $venvPython
    } else {
        Write-Host "Warning: could not create venv. Falling back to bootstrap Python."
        $runtimePython = $bootstrapPython
    }
}
Write-Host "Using runtime Python: $runtimePython"

# --- Install dependencies (retry with Tsinghua mirror for CN networks) ----
& $runtimePython -m pip install --upgrade pip --quiet
if ($LASTEXITCODE -ne 0) { Write-Host "Warning: pip self-upgrade failed." }
& $runtimePython -m pip install -r (Join-Path $projectDir "requirements.txt")
if ($LASTEXITCODE -ne 0) {
    Write-Host "pip install failed; retrying with the Tsinghua mirror..."
    & $runtimePython -m pip install -r (Join-Path $projectDir "requirements.txt") `
        -i https://pypi.tuna.tsinghua.edu.cn/simple
    if ($LASTEXITCODE -ne 0) {
        Write-Host "pip install failed even with the mirror. Check the network and retry."
        exit 1
    }
}

# --- config.json -----------------------------------------------------------
$configFile = Join-Path $projectDir "config.json"
if (-not (Test-Path $configFile)) {
    Copy-Item (Join-Path $projectDir "config.example.json") $configFile
    Write-Host "Created config.json from config.example.json"
}
& $runtimePython (Join-Path $PSScriptRoot "apply_env_config.py") --config $configFile
if ($LASTEXITCODE -ne 0) { exit 1 }

# --- Resolve proxy port (must stay 4 digits for the binary patch) ---------
$proxyPort = Get-ProxyConfigValue "proxy_port"
if (-not $proxyPort) { $proxyPort = if ($env:PROXY_PORT) { $env:PROXY_PORT } else { "9876" } }
$proxyHost = Get-ProxyConfigValue "proxy_host"
if (-not $proxyHost) { $proxyHost = "127.0.0.1" }
if ("$proxyPort".Length -ne 4) {
    Write-Host "PROXY_PORT must be four digits for the byte-length-preserving patch (got $proxyPort)."
    exit 1
}

# --- Fake OAuth token -------------------------------------------------------
$encryptionKey = Join-Path $Script:ClaudeScienceUserDir "encryption.key"
if (Test-Path $encryptionKey) {
    & $runtimePython (Join-Path $projectDir "setup-token.py") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: OAuth token generation failed."
    } else {
        Write-Host "OAuth token generated."
    }
} else {
    Write-Host "Warning: $encryptionKey does not exist yet."
    Write-Host "Open Claude Science once so it creates local state, then rerun this script."
}

# --- Daemon patches (Claude Science must not be running) -------------------
$csInfo = Get-ClaudeScienceInfo
if (-not $csInfo) {
    Write-Host "Claude Science installation not found; skipping daemon patches."
} else {
    Write-Host "Claude Science found: $($csInfo.Exe) (version $($csInfo.Version))"
    if (Stop-ClaudeScience) {
        Write-Host "Stopped the running Claude Science before patching."
    }
    if (-not $NoAuthPatch) {
        & $runtimePython (Join-Path $PSScriptRoot "patch_daemon_auth.py") --port $proxyPort
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: Claude Science auth patch was not applied."
        }
    } else {
        Write-Host "Auth patch skipped (-NoAuthPatch)."
    }
    if (-not $NoModelPatch) {
        & $runtimePython (Join-Path $PSScriptRoot "patch_daemon_models.py")
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: Claude Science model menu patch was not applied."
        }
    } else {
        Write-Host "Model menu patch skipped (-NoModelPatch)."
    }
}

# --- Startup auto-start shortcut -------------------------------------------
$startupAction = "registered"
if ($NoStartup) {
    $startupAction = "skipped (-NoStartup)"
} else {
    $shortcutPath = Get-StartupShortcutPath
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot "start-proxy.ps1") + '"'
        $shortcut.WorkingDirectory = $projectDir
        $shortcut.Description = "Claude Science API Bridge local proxy"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        Write-Host "Startup shortcut created: $shortcutPath"
    } catch {
        $startupAction = "failed: $($_.Exception.Message)"
        Write-Host "Warning: could not create the Startup shortcut."
    }
}

# --- Start the proxy --------------------------------------------------------
& (Join-Path $PSScriptRoot "start-proxy.ps1")
if ($LASTEXITCODE -ne 0) { exit 1 }

# --- Health check -----------------------------------------------------------
Start-Sleep -Seconds 2
$baseUrl = Get-ProxyBaseUrl -HostOverride $proxyHost -PortOverride $proxyPort
$health = Test-ProxyHealth -BaseUrl $baseUrl -TimeoutSec 10
if (-not $health) {
    Write-Host "Health check failed at $baseUrl/health; see logs at $Script:ClaudeScienceUserDir\logs\proxy-error.log"
    exit 1
}

Write-Host ""
Write-Host "Safe install complete. Startup auto-start: $startupAction"
Write-Host "Dashboard: http://$proxyHost`:$proxyPort/dashboard"
if ($csInfo) {
    Write-Host "Start Claude Science with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\start-claude-science.ps1`""
} else {
    Write-Host "Use with compatible clients: set ANTHROPIC_BASE_URL=$(Get-MaskedProxyUrl $baseUrl)"
}
