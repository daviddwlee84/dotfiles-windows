#Requires -Version 7
# run_onchange_after_03_xdg_env.ps1 — persist the XDG base-dir env vars to the
# User environment so ~/.config is authoritative for XDG-aware tools (Neovim,
# lazygit, starship, yazi, atuin, zoxide) even when launched OUTSIDE a pwsh
# session that sourced our profile.
#
# Why this matters on Windows:
#   * 00_env.ps1 sets these in-session, so tools launched from pwsh already use
#     ~/.config. But nvim launched from Explorer / a non-pwsh terminal would
#     fall back to %LOCALAPPDATA%\nvim for config AND a separate data/plugin
#     dir — a confusing "my plugins vanished" split.
#   * Setting XDG_CONFIG_HOME is also the Neovim-documented way to make it read
#     ~/.config/nvim on Windows, and lazygit honours it for config.yml too.
#
# Idempotent + fault-tolerant: only writes a var when it differs; never aborts.
$ErrorActionPreference = 'Continue'

$want = @{
    XDG_CONFIG_HOME = Join-Path $HOME '.config'
    XDG_DATA_HOME   = Join-Path $HOME '.local\share'
    XDG_STATE_HOME  = Join-Path $HOME '.local\state'
    XDG_CACHE_HOME  = Join-Path $HOME '.cache'
}

foreach ($name in $want.Keys) {
    try {
        $current = [System.Environment]::GetEnvironmentVariable($name, 'User')
        if ($current -ne $want[$name]) {
            [System.Environment]::SetEnvironmentVariable($name, $want[$name], 'User')
            Write-Host "==> set User env $name = $($want[$name])" -ForegroundColor Cyan
        }
    } catch {
        Write-Warning "could not set $name (non-fatal): $_"
    }
}
