#Requires -Version 7
# enable-wsl-ubuntu.ps1 — register a WSL2 Ubuntu distro unattended (no OOBE) and
# bootstrap the cross-platform dotfiles (github.com/daviddwlee84/dotfiles) inside it.
#
# Single source of truth, run in two contexts:
#   - .chezmoiscripts/run_onchange_after_46_wsl_ubuntu.ps1.tmpl embeds this via
#     {{ include }} during `chezmoi apply` when installWslUbuntu is on; that
#     wrapper renders a prelude setting $Wsl* from chezmoi data first, so we
#     never call `chezmoi` mid-apply.
#   - `just enable-wsl-ubuntu` runs it standalone (also the retry path); the
#     $Wsl* values are then read from the persisted config via `chezmoi data`.
#
# Requires the WSL2 platform (installWsl) installed AND rebooted first.
# Registering a distro on a ready platform does NOT need admin, so we do not
# self-elevate; if a step returns an elevation error we point at
# `just enable-wsl-ubuntu` from an admin pwsh. Never aborts the apply (invariant #2).
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # BOM-free stdin to wsl/bash
$env:WSL_UTF8 = '1'                                         # wsl.exe emits UTF-8, not UTF-16

$Distro = 'Ubuntu-24.04'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# Frozen answers: set by the wrapper prelude during apply; read from the
# persisted chezmoi config when run standalone via `just` (no concurrent apply).
if (-not $WslUser) {
    try {
        $d = & chezmoi data --format json 2>$null | ConvertFrom-Json
        $WslUser   = $d.wslUsername
        $WslName   = $d.name
        $WslEmail  = $d.email
        $WslMirror = "$($d.useChineseMirror)".ToLower()
        $WslMode   = $d.wslUbuntuBootstrap
    } catch { Write-Verbose "chezmoi data unavailable; relying on prelude/defaults: $_" }
}
if (-not $WslMode)   { $WslMode = 'headless' }
if (-not $WslMirror) { $WslMirror = 'false' }

# Sanitize to a valid Linux login name (strip domain, lowercase, [a-z0-9_-]).
$user = ((("$WslUser" -replace '.*\\', '') -replace '[^A-Za-z0-9_-]', '')).ToLower()
if (-not $user) { $user = 'dev' }

function Test-WslPlatform {
    try { & wsl.exe --status *> $null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}
function Test-DistroRegistered {
    try { $list = & wsl.exe -l -q 2>$null } catch { return $false }
    return (($list -join "`n") -match [regex]::Escape($Distro))
}
function Test-DotfilesInstalled {
    try { & wsl.exe -d $Distro -u $user -- bash -lc 'test -d "$HOME/.local/share/chezmoi"' *> $null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}

try {
    if (-not (Test-WslPlatform)) {
        Write-Warning "WSL2 platform not ready. Enable installWsl and REBOOT first, then run 'just enable-wsl-ubuntu'."
        return
    }

    $registered = Test-DistroRegistered
    if ($registered -and (Test-DotfilesInstalled)) {
        Info "$Distro already set up with dotfiles — nothing to do."
        return
    }

    if (-not $registered) {
        Info "Registering $Distro (no launch, no OOBE)"
        & wsl.exe --install -d $Distro --no-launch
        if ($LASTEXITCODE -ne 0) {
            $hint = if (Test-Admin) { '' } else { " If this failed with an elevation error, run 'just enable-wsl-ubuntu' from an admin pwsh." }
            Write-Warning ("wsl --install -d $Distro failed (exit $LASTEXITCODE).$hint")
            return
        }

        # Create the user as root — bypasses the interactive OOBE. Pipe a bash
        # script via stdin (bash -s) to avoid PowerShell->wsl->bash quote hell.
        Info "Creating user '$user' (passwordless sudo, WSL auto-login)"
        $rootScript = @"
set -e
u='$user'
id "`$u" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm "`$u"
passwd -l "`$u" >/dev/null 2>&1 || true
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "`$u" > "/etc/sudoers.d/90-`$u"
chmod 0440 "/etc/sudoers.d/90-`$u"
printf '[user]\ndefault=%s\n' "`$u" > /etc/wsl.conf
"@ -replace "`r`n", "`n"
        $rootScript | & wsl.exe -d $Distro -u root -- bash -s
        if ($LASTEXITCODE -ne 0) { Write-Warning "user setup in $Distro failed (exit $LASTEXITCODE)."; return }

        & wsl.exe --terminate $Distro *> $null   # apply /etc/wsl.conf default user
    }

    if ($WslMode -ne 'headless') {
        Info "$Distro ready. Bootstrap mode '$WslMode' — open it and install dotfiles yourself:"
        Write-Host "    wsl -d $Distro" -ForegroundColor Yellow
        Write-Host '    sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply daviddwlee84' -ForegroundColor Yellow
        return
    }

    # Headless: run the frozen, non-interactive dotfiles bootstrap as the user.
    Info "Bootstrapping cross-platform dotfiles in $Distro (headless)"
    $boot = @"
set -e
command -v curl >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
sh -c "`$(curl -fsLS get.chezmoi.io)" -- -b "`$HOME/.local/bin" \
  init --apply "https://github.com/daviddwlee84/dotfiles.git" --promptDefaults \
  --promptString "What is your full name=$WslName" \
  --promptString "What is your email address=$WslEmail" \
  --promptChoice "Which profile=ubuntu_server" \
  --promptBool "Are you in China (behind GFW) and need to use mirrors=$WslMirror"
"@ -replace "`r`n", "`n"
    $boot | & wsl.exe -d $Distro -u $user -- bash -s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "dotfiles bootstrap in $Distro failed (exit $LASTEXITCODE). Retry: just enable-wsl-ubuntu"
        return
    }
    Info "WSL Ubuntu ready — open it with: wsl -d $Distro"
} catch {
    Write-Warning "WSL Ubuntu setup failed (non-fatal): $_"
}
