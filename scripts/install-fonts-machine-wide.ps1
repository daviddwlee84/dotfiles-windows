#Requires -Version 7
# install-fonts-machine-wide.ps1 — install the Hack Nerd Fonts machine-wide via
# scoop global (needs admin).
#
# Fixes Alacritty on Windows not finding a Nerd Font that scoop installed per-user:
# Alacritty enumerates only the machine-wide (HKLM) font collection, so a scoop
# `nerd-fonts` install (registered per-user in HKCU) is invisible to it — while
# Windows Terminal and WezTerm see per-user fonts fine. `scoop install -g` installs
# a global copy that registers machine-wide.
#
# Run via `just install-fonts-machine-wide` from an ELEVATED pwsh.
$ErrorActionPreference = 'Continue'

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

if (-not (Test-Admin)) {
    Write-Warning 'Machine-wide font install needs an elevated shell. Run `just install-fonts-machine-wide` from an admin pwsh.'
    return
}
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Warning 'scoop not found on PATH.'
    return
}

scoop bucket add nerd-fonts *> $null
Write-Host '==> scoop install -g Hack-NF-Mono Hack-NF (machine-wide)' -ForegroundColor Cyan
scoop install -g Hack-NF-Mono Hack-NF
Write-Host '==> Done. Restart Alacritty to pick up the machine-wide font.' -ForegroundColor Green
