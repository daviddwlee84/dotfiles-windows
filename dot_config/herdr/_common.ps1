# ~/.config/herdr/_common.ps1
# Source: dot_config/herdr/_common.ps1 (managed by chezmoi)
#
# Shared helpers for the herdr keybind scripts (run-command / new-tab-at-space-root /
# url-pick / path-pick / pane-copy / review-mark). Dot-sourced by each of them.
#
# These run inside a herdr `[[keys.command]]` pane or popup, spawned as
# `pwsh -NoProfile -File <script> …` — so there is NO profile, NO repo aliases and
# NO $PROFILE-set encoding. Everything they need has to come from here or the
# environment herdr injects ($HERDR_ACTIVE_PANE_ID / $HERDR_ACTIVE_PANE_CWD /
# $HERDR_SOCKET_PATH).
#
# The unix originals shell out to `jq` and to this repo's cross-platform `x`
# helper (`x copy` / `x open`). Neither exists on Windows: JSON is parsed with
# ConvertFrom-Json, the clipboard is Set-Clipboard, and opening a URL is
# Start-Process (the Windows shell handler). `jq` IS installed here, but calling
# it would only add a process per lookup.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# herdr emits UTF-8; without this a pane read full of box-drawing characters
# comes back mojibake under -NoProfile (the repo's UTF-8 console setup lives in
# the profile, which we deliberately skip).
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch { $null = $_ }

function Test-HerdrPresent {
    if (Get-Command herdr -ErrorAction SilentlyContinue) { return $true }
    Write-Host 'herdr not found on PATH' -ForegroundColor Red
    $false
}

# Run a herdr subcommand and parse its JSON. Returns $null on any failure so
# callers can fall through instead of throwing inside a pane that is about to close.
function Invoke-HerdrJson {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)
    try {
        $raw = & herdr @Argument 2>$null
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

# Resolve the pane to act on: explicit id -> $HERDR_ACTIVE_PANE_ID (what a keybind
# injects) -> $HERDR_PANE_ID (ambient, set inside a pane) -> `herdr pane current`.
function Resolve-HerdrPane {
    param([string] $PaneId)
    foreach ($candidate in $PaneId, $env:HERDR_ACTIVE_PANE_ID, $env:HERDR_PANE_ID) {
        if ($candidate) { return $candidate }
    }
    $j = Invoke-HerdrJson pane current
    if ($j) { return $j.result.pane.pane_id }
    $null
}

# Resolve a working directory: explicit -> $HERDR_ACTIVE_PANE_CWD (injected by the
# keybind) -> the pane's live foreground cwd -> the process cwd. Preferring the env
# var means this keeps working even when the CLI is protocol-mismatched with a
# stale server.
function Resolve-HerdrCwd {
    param([string] $Cwd, [string] $PaneId)
    if ($Cwd -and (Test-Path -LiteralPath $Cwd)) { return $Cwd }
    if ($env:HERDR_ACTIVE_PANE_CWD -and (Test-Path -LiteralPath $env:HERDR_ACTIVE_PANE_CWD)) {
        return $env:HERDR_ACTIVE_PANE_CWD
    }
    if ($PaneId) {
        $j = Invoke-HerdrJson pane get $PaneId
        if ($j) {
            foreach ($c in $j.result.pane.foreground_cwd, $j.result.pane.cwd) {
                if ($c -and (Test-Path -LiteralPath $c)) { return $c }
            }
        }
    }
    (Get-Location).Path
}

# Read a pane's terminal text. $Source is visible | recent | recent-unwrapped.
function Get-HerdrPaneText {
    param([string] $PaneId, [string] $Source = 'visible')
    try {
        $out = & herdr pane read $PaneId --source $Source --format text 2>$null
        if ($out -is [array]) { return ($out -join "`n") }
        return [string]$out
    } catch { return $null }
}

# Copy to the Windows clipboard. Set-Clipboard is the native equivalent of the
# unix side's `x copy`; clip.exe is the fallback for a host where the
# Microsoft.PowerShell.Management clipboard cmdlets are unavailable.
function Set-HerdrClipboard {
    param([string] $Text)
    try {
        Set-Clipboard -Value $Text -ErrorAction Stop
        return $true
    } catch {
        if (Get-Command clip.exe -ErrorAction SilentlyContinue) {
            $Text | clip.exe
            return $true
        }
        Write-Host "could not reach the clipboard: $_" -ForegroundColor Red
        return $false
    }
}

# A herdr command pane closes the moment this script exits, so an error the user
# never sees is an error that never happened. Hold briefly.
function Show-HerdrNotice {
    param([string] $Message, [double] $Seconds = 1.5)
    Write-Host $Message -ForegroundColor Yellow
    Start-Sleep -Seconds $Seconds
}
