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
# LOAD-BEARING: every success test below is `$LASTEXITCODE -eq 0`, which requires a
# non-zero NATIVE exit NOT to throw. pwsh currently defaults this to $false, but pin
# it — if it were ever $true, `& herdr` would throw on failure, the try/catch would
# swallow it, and every diagnostic (including the stale-server warning) would go
# silent. `-NoProfile` means no profile can set it for us.
$PSNativeCommandUseErrorActionPreference = $false

# herdr emits UTF-8; without this a pane read full of box-drawing characters
# comes back mojibake under -NoProfile (the repo's UTF-8 console setup lives in
# the profile, which we deliberately skip).
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch { $null = $_ }

function Test-HerdrPresent {
    if (Get-Command herdr -ErrorAction SilentlyContinue) { return $true }
    # Held: every caller exits immediately after this, and the pane closes with it.
    Write-Host 'herdr not found on PATH' -ForegroundColor Red
    Write-Host 'The keybind helpers run under -NoProfile, so they see only the' -ForegroundColor Yellow
    Write-Host 'persistent PATH. Check: (Get-Command herdr).Source' -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    $false
}

# herdr's CLI and the running server speak a VERSIONED protocol. When they differ
# (the CLI was updated while a server kept running, or a pane inherited an older
# CLI on its PATH) every pane command fails with:
#   {"error":{"code":"protocol_mismatch","message":"client protocol 17 is newer
#    than server protocol 16; restart the Herdr server ..."}}
# Without this check the scripts swallow that and report a generic "failed to
# read pane <id>", which hides the real (trivial) fix. See
# pitfalls/herdr-keybind-failed-to-read-pane-protocol-mismatch.md
#
# ⚠ LAST-RESORT matcher. herdr's structured error MESSAGE echoes back arguments we
# passed ("pane <id> not found"), so a caller-supplied pane id containing the marker
# word would false-positive here. Prefer Get-HerdrErrorCode; only fall back to this
# when stderr is NOT structured JSON (the unreachable-socket case, which emits a
# plain `Error: Os { code: 2, ... }` line and carries no user text).
function Test-HerdrProtocolMismatch {
    param([string] $Text)
    if (-not $Text) { return $false }
    ($Text -match 'protocol_mismatch') -or
    ($Text -match 'client protocol \d+ is (newer|older) than server protocol \d+')
}

# herdr reports failures as one JSON object per stderr line:
#   {"error":{"code":"protocol_mismatch","message":"..."},"id":"cli:pane:read"}
# Return error.code, or '' when stderr is not structured JSON. Reading the CODE is
# the only safe test: codes are a closed vocabulary, messages contain our arguments.
function Get-HerdrErrorCode {
    param([string] $Text)
    if (-not $Text) { return '' }
    foreach ($line in ($Text -split "`n")) {
        if (-not $line.Trim()) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($o -and $o.PSObject.Properties['error'] -and $o.error) { return [string]$o.error.code }
    }
    ''
}

# Explain once. A command pane closes the instant the script exits, so hold.
$script:HerdrStaleServerWarned = $false
function Show-HerdrStaleServer {
    if (-not $script:HerdrStaleServerWarned) {
        $script:HerdrStaleServerWarned = $true
        Write-Host 'herdr: CLI and server protocol versions differ.' -ForegroundColor Red
        Write-Host 'Cause: `herdr update` replaced the CLI while a server kept running, OR this' -ForegroundColor Yellow
        Write-Host '       pane inherited an older herdr on its PATH than the running server.' -ForegroundColor Yellow
        Write-Host 'Fix:   quit herdr and relaunch it (restarting the server EXITS pane processes),' -ForegroundColor Yellow
        Write-Host '       then check: herdr --version, and (Get-Command herdr).Source' -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
    $true
}

function Assert-HerdrServerFresh {
    param([string] $Text)
    if (Test-HerdrProtocolMismatch $Text) { return (Show-HerdrStaleServer) }
    $false
}

# Classify a FAILED herdr call and warn when the cause is a protocol mismatch.
# Returns the structured error code ('' when neither stream was structured JSON).
#
# $OutText is the FAILED call's stdout. Measured today it is always EMPTY (herdr puts
# the error object on stderr), but it is inspected as a fallback so a future herdr
# that reports on stdout still gets diagnosed. This cannot reintroduce the pane-content
# false positive: it runs ONLY when the command failed, and a failed call returns no
# payload — the success path never reaches here.
function Resolve-HerdrFailure {
    param([string] $ErrText, [string] $OutText)
    $code = Get-HerdrErrorCode $ErrText
    if (-not $code) { $code = Get-HerdrErrorCode $OutText }
    if ($code) {
        if ($code -eq 'protocol_mismatch') { $null = Show-HerdrStaleServer }
        return $code
    }
    # Neither stream is structured JSON => pure diagnostics (e.g. the unreachable-socket
    # `Error: Os { code: 2, ... }` line). No user text to confuse, so the regex is safe.
    if (Assert-HerdrServerFresh $ErrText) { return '' }
    $null = Assert-HerdrServerFresh $OutText
    ''
}

# Split a captured `2>&1` stream into (payload, diagnostics). ErrorRecords are
# diagnostics; everything else is the command's real output. Verified on pwsh 7.6.3:
# under 2>&1 each stderr LINE arrives as one ErrorRecord and stdout lines stay String.
function Split-HerdrStream {
    param([object[]] $Raw)
    $err = @($Raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $out = @($Raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    [pscustomobject]@{
        Out = ($out | ForEach-Object { [string]$_ }) -join "`n"
        Err = ($err | ForEach-Object { [string]$_ }) -join "`n"
    }
}

# Run a herdr subcommand and parse its JSON. Returns $null on any failure so
# callers can fall through instead of throwing inside a pane that is about to close.
#
# MEASURED CONTRACT (herdr 0.7.5-preview): on failure stdout is EMPTY and the
# {"error":{...}} object is on STDERR with exit 1; on success stderr is empty. So the
# error object is parsed from stderr — parsing it from stdout was dead code.
function Invoke-HerdrJson {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)
    try {
        $raw = @(& herdr @Argument 2>&1)
        $ok = ($LASTEXITCODE -eq 0)
        $s = Split-HerdrStream $raw
        if (-not $ok) { $null = Resolve-HerdrFailure $s.Err $s.Out; return $null }
        # Success: stderr is empty by contract, and stdout is the payload — which
        # carries arbitrary user text (pane titles, cwds) and is NEVER scanned.
        if (-not $raw) { return $null }
        try { return ($s.Out | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
    } catch { return $null }
}

# Resolve the pane to act on: explicit id -> $HERDR_ACTIVE_PANE_ID (what a keybind
# injects) -> $HERDR_PANE_ID (ambient, set inside a pane) -> `herdr pane current`.
# WINDOWS QUIRK: herdr does NOT expand $VAR inside a [[keys.command]] string on the
# Windows preview, so a keybind written as `... "$HERDR_ACTIVE_PANE_ID"` hands us the
# LITERAL text "$HERDR_ACTIVE_PANE_ID". Skip any unexpanded $-placeholder so we fall
# through to the env var herdr DID inject. See backlog/herdr-windows-port-verification.md #3.
function Resolve-HerdrPane {
    param([string] $PaneId)
    foreach ($candidate in $PaneId, $env:HERDR_ACTIVE_PANE_ID, $env:HERDR_PANE_ID) {
        if ($candidate -and $candidate -notlike '$*') { return $candidate }
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
    if ($Cwd -and $Cwd -notlike '$*' -and (Test-Path -LiteralPath $Cwd)) { return $Cwd }
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
# Returns $null ONLY on a real failure; '' is a legitimate result (a blank pane).
#
# ⚠ The returned text is the pane's CONTENT — arbitrary user data. It is never
# scanned for herdr error markers: a pane showing the word "protocol_mismatch"
# (e.g. someone debugging herdr) previously tripped a bogus "server is STALE".
function Get-HerdrPaneText {
    param([string] $PaneId, [string] $Source = 'visible')
    try {
        $raw = @(& herdr pane read $PaneId --source $Source --format text 2>&1)
        $ok = ($LASTEXITCODE -eq 0)
        $s = Split-HerdrStream $raw
        if (-not $ok) { $null = Resolve-HerdrFailure $s.Err $s.Out; return $null }
        # Success => return the payload as-is. Do NOT test `-not $raw` here: an empty
        # pane (or a single blank line) is falsy, and returning $null for it would be
        # reported by callers as "failed to read pane". They check `$null -eq $content`
        # precisely so '' falls through to "no URLs found" / "no paths found".
        return $s.Out
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
        $primary = $_
        if (Get-Command clip.exe -ErrorAction SilentlyContinue) {
            $Text | clip.exe
            # clip.exe's exit code is the only signal it gives — don't assume success.
            if ($LASTEXITCODE -eq 0) { return $true }
            Show-HerdrNotice "clipboard: clip.exe failed (exit $LASTEXITCODE)" 3
            return $false
        }
        # Held: the copy keybinds exit right after this and the pane closes with them.
        Show-HerdrNotice "could not reach the clipboard: $primary" 3
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
