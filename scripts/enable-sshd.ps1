#Requires -Version 7
# enable-sshd.ps1 — install + enable the Microsoft OpenSSH Server (sshd).
#
# Single source of truth, run in two contexts:
#   - .chezmoiscripts/run_onchange_after_40_openssh_server.ps1.tmpl embeds this via
#     {{ include }} and runs it during `chezmoi apply` when the installSshServer
#     toggle is on;
#   - `just enable-sshd` runs it directly from an elevated pwsh (the fallback when
#     `chezmoi apply` wasn't elevated).
#
# Everything here needs admin (Windows capability, service, firewall, HKLM shell),
# so we detect elevation and print guidance instead of failing when non-elevated.
#
# WARNING: this opens an inbound listener on TCP 22 and enables a system service.
# On a corporate/managed machine, confirm it's allowed by policy first.
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

if (-not (Test-Admin)) {
    Write-Warning 'OpenSSH server: needs an elevated shell. Run `just enable-sshd` from an admin pwsh, or re-run `chezmoi apply` elevated.'
    return
}

try {
    # 1. Install the OpenSSH.Server Windows capability if not already present.
    $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    if (-not $cap) {
        Write-Warning 'OpenSSH.Server capability not offered by this Windows image — install it manually (winget Microsoft.OpenSSH.Beta) then re-run.'
        return
    }
    if ($cap.State -ne 'Installed') {
        Info "Add-WindowsCapability $($cap.Name)"
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    } else {
        Info 'OpenSSH.Server capability already installed'
    }

    # 2. Service: automatic startup + running.
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
    Start-Service -Name sshd -ErrorAction SilentlyContinue
    Info "sshd: $((Get-Service sshd).Status), start type Automatic"

    # 3. Firewall: allow inbound TCP 22. The capability usually adds this rule;
    #    recreate it if it's missing.
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        Info 'New-NetFirewallRule OpenSSH-Server-In-TCP (inbound TCP 22)'
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }

    # 4. Default shell -> pwsh, so `ssh` sessions land in PowerShell 7, not cmd.exe.
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($pwsh) {
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwsh `
            -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
        Info "sshd DefaultShell -> $pwsh"
    }

    Info 'OpenSSH server ready. From another host: ssh <user>@<this-machine-name>'
} catch {
    Write-Warning "OpenSSH server setup failed (non-fatal): $_"
}
