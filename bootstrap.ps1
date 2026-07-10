#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap a fresh Windows machine with these dotfiles.

.DESCRIPTION
    Installs scoop (user-scoped; auto-passes -RunAsAdmin if the shell is
    elevated), then git + PowerShell 7 + chezmoi + uv, then runs `chezmoi init --apply` against this repo. Safe to re-run.
    Works from Windows PowerShell 5.1 or pwsh 7 — chezmoi runs the repo's .ps1
    scripts via pwsh regardless (see [interpreters.ps1] in .chezmoi.toml.tmpl).

    Behind the GFW: keep a VPN on for this step. scoop downloads git/pwsh/etc.
    from GitHub releases, which the `useChineseMirror` option does NOT cover
    (that only redirects pip/npm/cargo/go/node at runtime).

.EXAMPLE
    # From a fresh Windows PowerShell / pwsh session:
    irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex

.EXAMPLE
    # Local testing against a checked-out copy:
    ./bootstrap.ps1 -Source .
#>
[CmdletBinding()]
param(
    # Remote repo (default) — chezmoi shorthand or full URL.
    [string]$Repo = 'daviddwlee84/dotfiles-windows',
    [string]$Branch = 'main',
    # Local source dir; when set, overrides -Repo (for testing an unpushed tree).
    [string]$Source
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "==> $m" -ForegroundColor Green }
function Test-Admin {
    # $true when this session is elevated. Works on Windows PowerShell 5.1 and pwsh 7.
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

Info 'Windows dotfiles bootstrap'

# 0. Allow local scripts for the current user.
if ((Get-ExecutionPolicy -Scope CurrentUser) -notin 'RemoteSigned', 'Unrestricted', 'Bypass') {
    Info 'Setting execution policy: RemoteSigned (CurrentUser)'
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
}

# 1. scoop — user-scoped package manager. No admin required, but some dev boxes
#    always open the shell elevated; the installer refuses an admin console
#    ("Running the installer as administrator is disabled by default") unless
#    -RunAsAdmin is passed. Detect elevation and forward the flag so bootstrap
#    doesn't die on the first step. (scoop still installs per-user into ~/scoop.)
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    $installer = [scriptblock]::Create((Invoke-RestMethod get.scoop.sh))
    if (Test-Admin) {
        Info 'Installing scoop (elevated console: passing -RunAsAdmin)'
        & $installer -RunAsAdmin
    } else {
        Info 'Installing scoop'
        & $installer
    }
}

# 2. Baseline tools via scoop.
Info 'Installing git, PowerShell 7, chezmoi, uv'
scoop install git 7zip
foreach ($t in 'pwsh', 'chezmoi', 'uv') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { scoop install $t }
}

# 3. Refresh PATH from the registry so the just-installed scoop shims (chezmoi,
#    pwsh, uv, git) are resolvable in THIS session — scoop updates the persisted
#    User PATH, not the current process environment.
$env:PATH = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
    throw 'chezmoi not found on PATH after install — open a new terminal and re-run bootstrap.'
}

# 4. chezmoi init/update. No need to re-launch under pwsh 7: chezmoi invokes the
#    repo's .ps1 run-scripts with pwsh itself (per [interpreters.ps1]).
#
#    Re-run behaviour: `chezmoi init` clones on a fresh box but does NOT git-pull
#    an already-cloned source, so a second bootstrap would not see new commits.
#    When a source repo already exists we therefore `chezmoi update` (git pull +
#    apply) so re-running the one-liner always pulls the latest. run_onchange
#    package/config scripts still only re-fire when their rendered content
#    actually changes -- that is by design (see docs/setup.md).
if ($Source) {
    Info "chezmoi init --apply --source $Source"
    chezmoi init --apply --source $Source
} else {
    $srcExists = $false
    try {
        $sp = chezmoi source-path 2>$null
        if ($sp -and (Test-Path (Join-Path $sp '.git'))) { $srcExists = $true }
    } catch { }
    if ($srcExists) {
        Info 'chezmoi update (git pull + apply — picks up new commits)'
        chezmoi update --init
    } else {
        Info "chezmoi init --apply --branch $Branch $Repo"
        chezmoi init --apply --branch $Branch $Repo
    }
}

Ok 'Done. Open a new pwsh session to load the managed profile.'
