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

function Get-ScoopRoot {
    if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
}

function Reset-ScoopRepos {
    # scoop's core repo + each bucket are git clones of disposable package
    # indexes. On Windows they routinely show every manifest as "modified" from
    # CRLF<->LF renormalization, which makes `scoop update`'s `git pull` abort:
    # "Your local changes to the following files would be overwritten by merge".
    # Hard-resetting to the committed state is always safe here. No-op without git.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $root = Get-ScoopRoot
    $repos = @()
    $core = Join-Path $root 'apps\scoop\current'
    if (Test-Path (Join-Path $core '.git')) { $repos += $core }
    $bucketsDir = Join-Path $root 'buckets'
    if (Test-Path $bucketsDir) {
        foreach ($b in (Get-ChildItem $bucketsDir -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path (Join-Path $b.FullName '.git')) { $repos += $b.FullName }
        }
    }
    foreach ($r in $repos) {
        Info "  reset --hard $(Split-Path $r -Leaf)"
        git -C $r reset --hard HEAD 2>$null
    }
}

function Invoke-Scoop {
    # Run scoop; if it exits non-zero -- commonly a bucket `git pull` aborting on
    # phantom CRLF changes (see Reset-ScoopRepos) -- reset scoop's git repos and
    # retry once. Buckets are disposable indexes, so the reset never loses work.
    param([Parameter(ValueFromRemainingArguments)][string[]]$ScoopArgs)
    scoop @ScoopArgs
    if ($LASTEXITCODE -ne 0) {
        Info "scoop $($ScoopArgs -join ' ') failed (exit $LASTEXITCODE) -- resetting scoop repos and retrying once"
        Reset-ScoopRepos
        scoop @ScoopArgs
    }
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

# 1b. Git first + stop CRLF churn in scoop's buckets. Git for Windows defaults to
#     core.autocrlf=true, which rewrites scoop's LF manifests to CRLF; the whole
#     `main`/`extras` bucket then shows as modified and the next `scoop update`
#     (a git pull) aborts: "Your local changes to the following files would be
#     overwritten by merge". Install git, set autocrlf=input (only if unset/true,
#     so a deliberate choice is never overridden), and hard-reset the bucket
#     clones to clear any drift already on disk.
#     See pitfalls/scoop-local-changes-overwritten-by-merge.md.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Info 'Installing git'
    Invoke-Scoop install git
}
if (Get-Command git -ErrorAction SilentlyContinue) {
    $autocrlf = git config --global core.autocrlf 2>$null
    if ([string]::IsNullOrWhiteSpace($autocrlf) -or $autocrlf -eq 'true') {
        Info "git core.autocrlf was '$autocrlf' -> setting 'input' (prevents scoop bucket CRLF churn)"
        git config --global core.autocrlf input
    }
    Reset-ScoopRepos
}

# 2. Remaining baseline tools via scoop (git installed above).
Info 'Installing 7zip, PowerShell 7, chezmoi, uv'
Invoke-Scoop install 7zip
foreach ($t in 'pwsh', 'chezmoi', 'uv') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Invoke-Scoop install $t }
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
