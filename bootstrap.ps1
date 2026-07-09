#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap a fresh Windows machine with these dotfiles.

.DESCRIPTION
    Installs scoop (user-scoped, no admin), then git + PowerShell 7 + chezmoi +
    uv, then runs `chezmoi init --apply` against this repo. Safe to re-run.

.EXAMPLE
    # From a fresh Windows PowerShell / pwsh session:
    irm https://raw.githubusercontent.com/daviddwlee84/windows-dotfiles/main/bootstrap.ps1 | iex

.EXAMPLE
    # Local testing against a checked-out copy:
    ./bootstrap.ps1 -Source .
#>
[CmdletBinding()]
param(
    # Remote repo (default) — chezmoi shorthand or full URL.
    [string]$Repo = 'daviddwlee84/windows-dotfiles',
    [string]$Branch = 'main',
    # Local source dir; when set, overrides -Repo (for testing an unpushed tree).
    [string]$Source
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "==> $m" -ForegroundColor Green }

Info 'Windows dotfiles bootstrap'

# 0. Allow local scripts for the current user.
if ((Get-ExecutionPolicy -Scope CurrentUser) -notin 'RemoteSigned', 'Unrestricted', 'Bypass') {
    Info 'Setting execution policy: RemoteSigned (CurrentUser)'
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
}

# 1. scoop — user-scoped package manager, no admin required.
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Info 'Installing scoop'
    Invoke-RestMethod get.scoop.sh | Invoke-Expression
}

# 2. Baseline tools via scoop.
Info 'Installing git, PowerShell 7, chezmoi, uv'
scoop install git 7zip
foreach ($t in 'pwsh', 'chezmoi', 'uv') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { scoop install $t }
}

# 3. Re-exec under PowerShell 7 if we started in Windows PowerShell 5.1, so
#    chezmoi's [interpreters.ps1] = pwsh lines up with the running shell.
if ($PSVersionTable.PSVersion.Major -lt 7 -and (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Info 'Re-launching under PowerShell 7'
    $argsList = @('-NoLogo', '-File', $PSCommandPath, '-Repo', $Repo, '-Branch', $Branch)
    if ($Source) { $argsList += @('-Source', $Source) }
    & pwsh @argsList
    return
}

# 4. chezmoi init --apply
if ($Source) {
    Info "chezmoi init --apply --source $Source"
    chezmoi init --apply --source $Source
} else {
    Info "chezmoi init --apply --branch $Branch $Repo"
    chezmoi init --apply --branch $Branch $Repo
}

Ok 'Done. Open a new pwsh session to load the managed profile.'
