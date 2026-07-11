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
# self-relaunch elevated (one UAC prompt, like scoop's) rather than failing —
# and always end with a "restart required" notice, since the WSL2 kernel /
# hypervisor features aren't live until the machine reboots. Never aborts the
# apply (hard invariant #2).
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

$reboot = 'WSL: a RESTART is required before Docker Desktop can use the WSL2 backend. Reboot, then start Docker Desktop.'

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
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("wsl --install exited {0} — run 'just enable-wsl' to retry." -f $LASTEXITCODE)
        }
        Write-Warning $reboot
        # Only pause when we are the elevated child window we spawned below, so
        # its output stays readable. When an apply is already elevated (no
        # -Elevated), don't pause — Read-Host would block the NonInteractive run.
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
    Write-Warning $reboot
} catch {
    Write-Warning "WSL setup failed (non-fatal): $_"
}
