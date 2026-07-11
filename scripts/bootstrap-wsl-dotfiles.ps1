#Requires -Version 7
# bootstrap-wsl-dotfiles.ps1 — run the cross-platform dotfiles bootstrap
# (github.com/daviddwlee84/dotfiles) inside an EXISTING WSL distro, headless.
#
# Convenience wrapper behind `just wsl-dotfiles`. Unlike `enable-wsl-ubuntu`, it
# does NOT register a distro or create a user — it only runs the chezmoi
# bootstrap in a distro that already exists. Use it to:
#   - finish the install after `enable-wsl-ubuntu`'s in-distro step failed on the
#     network (idempotent — chezmoi init is safe to re-run), or
#   - install the dotfiles into a WSL distro you set up yourself.
#
# The frozen answers come from the persisted chezmoi config (`chezmoi data`), and
# the bootstrap is piped via `bash -s` on stdin — so `$(...)`, `$HOME` and quotes
# are expanded by the Linux shell, never mangled by PowerShell / wsl (see the
# pitfall doc). Behind a proxy / GFW: connect a VPN first (WSL routes through the
# Windows network). NB: the bootstrap here is kept in sync with the headless
# block of scripts/enable-wsl-ubuntu.ps1.
param(
    [string]$Distro = 'Ubuntu-24.04',
    [string]$WslUser   # default: the distro's own default user
)

$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # BOM-free stdin to wsl/bash
$env:WSL_UTF8 = '1'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }

# Frozen answers from the persisted chezmoi config.
$Name = ''; $Email = ''; $Mirror = 'false'
try {
    $d = & chezmoi data --format json 2>$null | ConvertFrom-Json
    $Name   = $d.name
    $Email  = $d.email
    $Mirror = "$($d.useChineseMirror)".ToLower()
    if (-not $WslUser) { $WslUser = $d.wslUsername }
} catch { Write-Verbose "chezmoi data unavailable; using defaults: $_" }
if (-not $Mirror) { $Mirror = 'false' }

# -u <user> only if we have one (else use the distro's default user).
$wslArgs = @('-d', $Distro)
if ($WslUser) {
    $u = ((("$WslUser" -replace '.*\\', '') -replace '[^A-Za-z0-9_-]', '')).ToLower()
    if ($u) { $wslArgs += @('-u', $u) }
}

$boot = @"
command -v curl >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
i=1
while [ "`$i" -le 3 ]; do
  script="`$(curl -fsSL --retry 5 --retry-connrefused --retry-all-errors https://get.chezmoi.io)"
  if [ -n "`$script" ] && printf '%s' "`$script" | sh -s -- -b "`$HOME/.local/bin" \
       init --apply "https://github.com/daviddwlee84/dotfiles.git" --promptDefaults \
       --promptString "What is your full name=$Name" \
       --promptString "What is your email address=$Email" \
       --promptChoice "Which profile=ubuntu_server" \
       --promptBool "Are you in China (behind GFW) and need to use mirrors=$Mirror"; then
    exit 0
  fi
  echo "chezmoi bootstrap attempt `$i failed (likely a proxy/GFW reset); retrying in 5s..." >&2
  i=`$((i + 1)); sleep 5
done
exit 1
"@ -replace "`r`n", "`n"

try {
    Info "Bootstrapping cross-platform dotfiles in $Distro (headless)"
    $boot | & wsl.exe @wslArgs -- bash -s
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "dotfiles bootstrap in $Distro failed (exit $LASTEXITCODE) — usually a proxy/GFW reset fetching chezmoi/the repo from GitHub (curl 56). Connect a VPN (WSL uses the Windows network) and re-run: just wsl-dotfiles"
        return
    }
    Info "Done — open it with: wsl -d $Distro"
} catch {
    Write-Warning "WSL dotfiles bootstrap failed (non-fatal): $_"
}
