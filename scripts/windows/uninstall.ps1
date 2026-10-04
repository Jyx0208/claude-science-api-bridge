# Uninstall the Windows Claude Science API Bridge setup:
# stop the proxy, remove the Startup shortcut, restore the patched
# claude-science.exe from backups. config.json / tokens / logs are kept
# unless -PurgeConfig is given.

param(
    [switch]$KeepPatch,
    [switch]$PurgeConfig
)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\common.ps1"

# 1. Stop the proxy.
& (Join-Path $PSScriptRoot "stop-proxy.ps1")

# 2. Remove the Startup shortcut.
$shortcut = Get-StartupShortcutPath
if (Test-Path $shortcut) {
    Remove-Item $shortcut -Force
    Write-Host "Removed Startup shortcut: $shortcut"
} else {
    Write-Host "No Startup shortcut found."
}

# 3. Restore the original claude-science.exe (undo both patches).
$csInfo = Get-ClaudeScienceInfo
if ($csInfo -and -not $KeepPatch) {
    if (Stop-ClaudeScience) {
        Write-Host "Stopped the running Claude Science before restoring."
    }
    # .byok-auth-original is the pristine exe; .byok-model-original still
    # contains the auth patch (it is taken after the auth patch ran), so
    # restore the auth backup first.
    $restored = $false
    foreach ($suffix in @(".byok-auth-original", ".byok-model-original")) {
        $backup = "$($csInfo.Exe)$suffix"
        if (Test-Path $backup) {
            Copy-Item $backup $csInfo.Exe -Force
            Write-Host "Restored $csInfo.Exe from $backup"
            $restored = $true
            break
        }
    }
    if (-not $restored) {
        Write-Host "No patch backup found; exe left unchanged."
    }
} elseif ($csInfo -and $KeepPatch) {
    Write-Host "Patch kept (-KeepPatch); exe left unchanged."
}

# 4. Optional config purge.
if ($PurgeConfig) {
    $projectDir = Get-ProjectDir
    foreach ($name in @("config.json", ".daemon-model-patch.json")) {
        $path = Join-Path $projectDir $name
        if (Test-Path $path) {
            Remove-Item $path -Force
            Write-Host "Removed $path"
        }
    }
    Write-Host "Note: OAuth tokens under $Script:ClaudeScienceUserDir\.oauth-tokens and logs were left in place."
} else {
    Write-Host "Left config.json, API keys, tokens, and logs in place."
}
