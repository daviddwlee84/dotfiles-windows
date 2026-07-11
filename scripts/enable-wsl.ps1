#Requires -Version 7
# enable-wsl.ps1 — install WSL2, the Docker Desktop backend.
#
# Single source of truth, run in two contexts:
#   - .chezmoiscripts/run_onchange_after_45_wsl.ps1.tmpl embeds this via
#     {{ include }} and runs it during `chezmoi apply` when the installWsl
#     toggle is on;
#   - `just enable-wsl` runs it directly (also the retry path if the apply's
#     UAC prompt was declined — run_onchange is content-hash gated, so it won't
#     re-fire on its own).
#
# `wsl --install` needs admin AND a reboot. When not already elevated we
# self-relaunch elevated (one UAC prompt, like scoop's) rather than failing.
# If the WSL app can't be downloaded (proxy / corporate firewall / GFW resets
# the connection), we fall back to enabling the WSL2 platform features OFFLINE
# via DISM and point at the kernel MSI. Never aborts the apply (invariant #2).
param([switch]$Elevated)

$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# wsl.exe is always on PATH as a stub even when the WSL feature is off, so judge
# presence by exit code, not Get-Command. Either --status or --version exiting 0
# means the WSL2 platform is already installed (a distro is not required — Docker
# creates its own docker-desktop distro).
function Test-WslInstalled {
    foreach ($probe in @('--status', '--version')) {
        try { & wsl.exe $probe *> $null } catch { continue }
        if ($LASTEXITCODE -eq 0) { return $true }
    }
    return $false
}

# Offline fallback: enable the WSL2 platform Windows features via DISM (no
# download). Returns $true if both end up enabled (exit 0, or 3010 = reboot
# required). Used when `wsl --install` can't download the app (proxy/GFW reset).
function Enable-WslFeatures {
    $ok = $true
    foreach ($feat in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
        Info "dism /online /enable-feature $feat"
        & dism.exe /online /enable-feature /featurename:$feat /all /norestart *> $null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { $ok = $false }
    }
    return $ok
}

$reboot = 'WSL: a RESTART is required before Docker Desktop can use the WSL2 backend. Reboot, then start Docker Desktop.'
$KernelMsi = 'https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi'

try {
    if (Test-WslInstalled) {
        Info 'WSL already installed — nothing to do.'
        return
    }

    if (Test-Admin) {
        # --no-distribution installs only the WSL2 platform (no Ubuntu). Older
        # builds reject the flag; fall back to a plain install (default distro).
        Info 'Installing WSL2 (wsl --install --no-distribution)'
        & wsl.exe --install --no-distribution
        if ($LASTEXITCODE -ne 0) {
            Info 'retrying without --no-distribution (older WSL build)'
            & wsl.exe --install
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Warning $reboot
            if ($Elevated) { $null = Read-Host 'Press Enter to close this window' }
            return
        }

        # `wsl --install` couldn't complete. The usual cause is the WSL app
        # download being reset mid-transfer by a proxy / corporate firewall / GFW
        # ("connection reset"). Retrying the same download won't help, so fall
        # back to enabling the WSL2 platform features OFFLINE via DISM (no
        # download); a reboot + a small kernel MSI (or `wsl --update` behind a
        # proxy) then finishes it.
        Info 'wsl --install did not complete (often a proxy/GFW download reset) — enabling WSL2 platform features offline via DISM'
        if (Enable-WslFeatures) {
            Write-Warning 'WSL app download failed (network / proxy / GFW connection reset). Enabled the WSL2 platform features offline via DISM instead.'
            Write-Warning 'Next: REBOOT, then get the WSL2 kernel one of these ways —'
            Write-Warning "  - with a VPN/proxy connected:  wsl --update   (or just re-run 'just enable-wsl')"
            Write-Warning "  - or install the kernel MSI by hand:  $KernelMsi"
            Write-Warning '  then run  wsl --set-default-version 2  and start Docker Desktop.'
        } else {
            Write-Warning "wsl --install failed AND the offline DISM feature-enable failed. Check network/policy, then run 'just enable-wsl' from an admin pwsh (ideally with a VPN/proxy connected)."
        }
        # Pause only in the elevated child window we spawned, so its guidance
        # stays readable; an already-elevated apply is -NonInteractive.
        if ($Elevated) { $null = Read-Host 'Press Enter to close this window' }
        return
    }

    # Not elevated: self-relaunch this same script elevated (one UAC prompt).
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    if (-not $self) {
        Write-Warning "WSL needs admin. Run 'just enable-wsl' from the chezmoi source dir and approve the UAC prompt (or run 'wsl --install' in an elevated pwsh). A reboot is required afterward."
        return
    }
    Info 'WSL needs admin — requesting elevation (approve the UAC prompt).'
    try {
        Start-Process pwsh -Verb RunAs -Wait `
            -ArgumentList '-NoProfile', '-NoLogo', '-File', $self, '-Elevated'
    } catch {
        Write-Warning "WSL install: elevation was declined or cancelled. Run 'just enable-wsl' and approve the UAC prompt (or run 'wsl --install' in an elevated pwsh). A reboot is required afterward."
        return
    }
    Write-Warning 'WSL setup ran in the elevated window — follow the reboot / next-step guidance it printed there.'
} catch {
    Write-Warning "WSL setup failed (non-fatal): $_"
}
