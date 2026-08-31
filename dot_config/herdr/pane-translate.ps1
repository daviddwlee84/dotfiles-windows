# ~/.config/herdr/pane-translate.ps1
# Source: dot_config/herdr/pane-translate.ps1 (managed by chezmoi)
#
# Translate a herdr pane's terminal content with the `translate` CLI and show the
# result as a BILINGUAL view — the original lines kept verbatim, each block's
# translation interleaved beneath as `  ↳ …` (`translate -2 --bilingual-mode doc`,
# one context-aware LLM call for the whole capture). PowerShell port of the parent
# repo's dot_config/herdr/executable_pane-translate.sh; the two must stay
# behaviourally identical (see ../../docs/herdr-pane-capture.md in the superproject).
#
# HOW MUCH TO CAPTURE — the whole design question, and the measured answers:
#
#   * An agent pane on the ALTERNATE SCREEN has no scrollback at all. A Claude
#     Code pane reports scroll.max_offset_from_bottom = 0 and `pane read --source
#     recent --lines 1000` returns exactly viewport_rows — identical to --source
#     visible. Rows that leave the alternate screen never enter herdr's host
#     scrollback, so no --lines value can recover them. Hence the default mode is
#     `visible`, which is not a compromise: it tracks whatever you scrolled to
#     INSIDE the app, so "the current page" is exact.
#   * `herdr pane read` caps at 1000 lines with no offset flag, so recent:1000 is
#     the hard ceiling (the same limit pane-copy.ps1 documents).
#   * A 1000-line read is ~62 KB, and translate costs roughly 10 KB ~ 60 s. The
#     REAL cap is a character budget (HERDR_TRANSLATE_MAX_CHARS, default 12000),
#     not a line count; recent:N is only a coarse selector the budget then trims,
#     and every trim is announced in the header.
#
# NOT CUTTING MID-CONTENT is handled twice. Mechanically, a recent:N window has
# its TOP edge snapped down to the nearest block boundary. Semantically — and this
# matters more — the capture is sent with an --instructions string telling the
# model it is a terminal excerpt that may begin or end mid-sentence. A `visible`
# capture is never trimmed at the top: it is exactly what you are looking at.
#
# WINDOWS DIFFERENCES from the unix side:
#   * prefix+t is type = "pane", not "popup" — the Windows preview rejects popup
#     (pitfalls/herdr-plus-action-does-not-support-platform-windows.md is a
#     different trap; the popup one is backlog item #2). A command pane already
#     owns a PTY, so the keybind takes the -Inline path directly.
#   * The keybind passes NO $VAR argument: herdr does not expand them here.
#     Resolve-HerdrPane picks the pane up from $env:HERDR_ACTIVE_PANE_ID instead.
#   * herdr-plus builds from source on Windows (needs go) and has never been
#     exercised on a real Windows host, so the Quick Action entries are a bonus —
#     prefix+t is the path that works without the plugin.
#
# Usage:
#   pane-translate.ps1 [MODE] [PANE_ID] [--to LANG] [--copy|--inline|--dry-run]
#   pane-translate.ps1 __view CAPTURE_FILE LABEL [--to LANG]
#
#   MODE     visible (default) | recent:N   (N clamped to 1..1000)
#
# Env: HERDR_TRANSLATE_MAX_CHARS (12000), HERDR_TRANSLATE_TO, HERDR_RUN_HOLD
#      (fail|always|never).
#
# Consumers: the prefix+t keybind and the translate-pane* herdr-plus Quick Actions.
# See docs/translate.md § "Translate a herdr pane".

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

# Sent to the model with every capture. This — not line arithmetic — is what makes
# a screen that starts or ends mid-sentence translate cleanly.
$Instructions = 'This is a captured terminal screen from a coding-agent TUI. It may begin or end mid-sentence: translate exactly what is present, never complete or summarise it. Keep command names, file paths, flags, identifiers, code, log lines, JSON and box-drawing characters verbatim; translate only prose.'

function Show-Usage {
    # Held: without a pause a bad arg shape looks identical to a dead keybind.
    Show-HerdrNotice 'usage: pane-translate.ps1 [visible|recent:N] [PANE_ID] [--to LANG] [--copy|--inline|--dry-run]' 3
    exit 64
}

# translate ships as a scoop package here (daviddwlee84/translate). Resolve by
# absolute fallback too: a Quick Action runs without an interactive profile, and a
# stale ~\.local\bin\translate.exe from the go-install era shadows the scoop shim.
function Resolve-TranslateBin {
    $cmd = Get-Command translate -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
            (Join-Path $HOME 'scoop\shims\translate.exe'),
            (Join-Path $HOME '.local\bin\translate.exe'),
            (Join-Path $HOME 'go\bin\translate.exe'))) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $null
}

# --- the text filter --------------------------------------------------------
# Native PowerShell rather than the unix side's embedded python3: python is not a
# dependency of this directory on Windows. Keep the two implementations in step.
function Format-HerdrCapture {
    param([string[]] $Lines, [string] $Mode, [int] $Budget)

    $footer = '^\s*(\?\s*for shortcuts|ctrl\s*\+|[Ee]sc to |shift\s*\+\s*tab|[>›❯»]\s|[>›❯»]\s*$)'
    # Keywords that only ever appear in a live input/status fixture, matched
    # anywhere on the line (a vim-mode indicator can precede them).
    $chromeKey = '(⏵⏵|\? for shortcuts|bypass permissions|shift\s*\+\s*tab|--\s*(INSERT|NORMAL|VISUAL)\s*--|esc to interrupt)'
    # A status bar is the other bottom fixture: several separated fields, no prose.
    $status = '^[^\n]*( · | │ )([^\n]*( · | │ )){1,}[^\n]*$'
    # A working spinner row: a glyph, then an elapsed/token counter in parentheses.
    $spinner = '^\s*[✽✻✳✢·*✶]\s.*\(.*\d+\s*(s|m|ms)\b.*\)\s*$'
    $boxTop = '^\s*[╭┌][─═━]'
    $boxBottom = '^\s*[╰└][─═━]'
    $boxSide = '^\s*[│┃|]'
    # A full-width rule, optionally carrying a trailing label.
    $rule = '^\s*[─═━_]{20,}(\s+\S.*)?$'

    $isChrome = {
        param([string] $Line)
        ($Line -cmatch $footer) -or ($Line -match $chromeKey) -or ($Line -cmatch $status) -or
        ($Line -cmatch $spinner) -or ($Line -cmatch $boxBottom) -or ($Line -cmatch $boxSide)
    }

    $ls = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $Lines) { $null = $ls.Add($l) }
    while ($ls.Count -gt 0 -and [string]::IsNullOrWhiteSpace($ls[$ls.Count - 1])) { $ls.RemoveAt($ls.Count - 1) }

    # Two passes over the bottom, repeated until stable: a row-wise walk, then a
    # block-wise cut at a rule. Cutting a status block can expose another footer
    # row that the first walk had stopped above.
    for ($pass = 0; $pass -lt 3; $pass++) {
        $orig = @($ls)
        $i = $orig.Count
        while ($i -gt 0) {
            $ln = $orig[$i - 1]
            if ([string]::IsNullOrWhiteSpace($ln) -or (& $isChrome $ln)) { $i--; continue }
            if ($ln -cmatch $boxTop) { $i--; break }
            break
        }
        # A custom status line is a whole BLOCK of non-prose rows the walk cannot
        # enumerate. What it does have is a reliable anchor: a full-width rule
        # separating it from the transcript. Cut from that rule, but only when it
        # is near the bottom AND something below it is recognisable chrome — so a
        # rule printed mid-transcript is left alone.
        $floor = [Math]::Max(0, $orig.Count - 31)
        for ($r = $orig.Count - 1; $r -ge $floor; $r--) {
            if ($r -ge $i) { continue }
            if ($orig[$r] -cmatch $rule) {
                $below = $false
                for ($k = $r + 1; $k -lt $orig.Count; $k++) { if (& $isChrome $orig[$k]) { $below = $true; break } }
                if ($below) { $i = $r; break }
            }
        }
        $ls = [System.Collections.Generic.List[string]]::new()
        for ($k = 0; $k -lt $i; $k++) { $null = $ls.Add($orig[$k]) }
        while ($ls.Count -gt 0 -and [string]::IsNullOrWhiteSpace($ls[$ls.Count - 1])) { $ls.RemoveAt($ls.Count - 1) }
        if ($ls.Count -eq $orig.Count) { break }
    }

    # Collapsed-transcript markers carry no translatable prose.
    for ($k = 0; $k -lt $ls.Count; $k++) {
        if ($ls[$k] -cmatch '^\s*(…|\.\.\.)\s*\+\d+ lines?\b') { $ls[$k] = "[$([char]0x2026)]" }
    }

    # --- top-edge boundary repair (recent:N only) ---------------------------
    # `visible` is literally what the user is looking at: mark it, never trim it.
    $note = ''
    if ($Mode -ne 'visible' -and $ls.Count -gt 0) {
        $boundary = '^(\s*$|[●⏺⎿•✻>❯$#]\s|[─═━]{10,}|[A-Z0-9][^\n]{0,60}:\s*$)'
        $margin = [Math]::Min(40, [Math]::Max(5, [int]($ls.Count * 15 / 100)))
        $cut = -1
        for ($k = 0; $k -lt [Math]::Min($margin, $ls.Count); $k++) {
            if ($ls[$k] -cmatch $boundary) { $cut = $k; break }
        }
        if ($cut -lt 0) {
            $note = '[… continued from earlier output …]'
        } elseif ($cut -gt 0) {
            $ls.RemoveRange(0, $cut)
            $note = '[… earlier output omitted …]'
        }
    }

    # --- dedent -------------------------------------------------------------
    # Load-bearing. translate's bitext classifies a block as Code once its indent
    # is >= base + 2 relative to the document's base margin, and an agent pane
    # renders its prose behind a uniform left margin — leave it and every
    # paragraph is classified as code and silently left untranslated.
    #
    # The base is the MODAL indent, not the minimum. An agent transcript mixes
    # turn markers at column 0 with prose at column 5; min() would be 0, dedent
    # nothing, and lose the whole page.
    $counts = @{}
    foreach ($l in $ls) {
        if (-not [string]::IsNullOrWhiteSpace($l)) {
            $n = $l.Length - $l.TrimStart(' ').Length
            $counts[$n] = 1 + [int]$counts[$n]
        }
    }
    if ($counts.Count -gt 0) {
        $top = ($counts.Values | Measure-Object -Maximum).Maximum
        $base = ($counts.Keys | Where-Object { $counts[$_] -eq $top } | Measure-Object -Minimum).Minimum
        if ($base -gt 0) {
            for ($k = 0; $k -lt $ls.Count; $k++) {
                $l = $ls[$k]
                if (-not [string]::IsNullOrWhiteSpace($l)) {
                    $ls[$k] = $l.Substring([Math]::Min($base, $l.Length - $l.TrimStart(' ').Length))
                }
            }
        }
    }
    for ($k = 0; $k -lt $ls.Count; $k++) { $ls[$k] = $ls[$k].Replace("`t", '    ').TrimEnd() }

    # --- collapse blank runs ------------------------------------------------
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $ls) {
        if ($l -eq '' -and $out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { continue }
        $null = $out.Add($l)
    }
    while ($out.Count -gt 0 -and $out[0] -eq '') { $out.RemoveAt(0) }

    # --- character budget ---------------------------------------------------
    # The real cap. Drop leading blank-line-delimited blocks until we fit, so the
    # newest content always survives and the cut always lands on a boundary.
    $trimmed = $false
    while ((($out -join "`n").Length -gt $Budget) -and $out.Count -gt 1) {
        $trimmed = $true
        $nxt = -1
        for ($k = 1; $k -lt $out.Count; $k++) { if ($out[$k] -eq '') { $nxt = $k; break } }
        if ($nxt -lt 0) {
            # One block bigger than the budget: fall back to a line-wise trim.
            while ((($out -join "`n").Length -gt $Budget) -and $out.Count -gt 1) { $out.RemoveAt(0) }
            break
        }
        $out.RemoveRange(0, $nxt + 1)
        while ($out.Count -gt 0 -and $out[0] -eq '') { $out.RemoveAt(0) }
    }
    if ($trimmed -and -not $note) { $note = '[… earlier output omitted …]' }
    if ($note) { $out.Insert(0, ''); $out.Insert(0, $note) }

    $body = ($out -join "`n")
    [pscustomobject]@{
        Text  = $body
        Stats = "raw_lines=$($Lines.Count) out_lines=$($out.Count) out_chars=$($body.Length) trimmed=$([int]$trimmed)"
    }
}

function Invoke-HerdrTranslate {
    param([string] $Bin, [string] $CaptureFile, [string] $To)
    $a = @('-2', '--bilingual-mode', 'doc', '--no-history', '--instructions', $Instructions)
    if ($To) { $a += @('--to', $To) }
    # Pipe the file in: translate reads stdin when given no positional text, and
    # a capture is far too big for an argv round trip.
    return (Get-Content -LiteralPath $CaptureFile -Raw | & $Bin @a 2>&1)
}

# ---------------------------------------------------------------------------
# __view: run inside the pane that actually has a PTY.
# ---------------------------------------------------------------------------
$argv = @($Argument | Where-Object { $null -ne $_ -and $_ -ne '' })

if ($argv.Count -ge 1 -and $argv[0] -eq '__view') {
    if ($argv.Count -lt 2) { Show-Usage }
    $capture = $argv[1]
    $label = if ($argv.Count -gt 2) { $argv[2] } else { 'pane' }
    $to = ''
    for ($k = 3; $k -lt $argv.Count; $k++) {
        if ($argv[$k] -eq '--to' -and $k + 1 -lt $argv.Count) { $to = $argv[$k + 1]; $k++ }
    }
    if (-not $to) { $to = $env:HERDR_TRANSLATE_TO }
    if (-not (Test-Path -LiteralPath $capture)) { Show-HerdrNotice 'pane-translate: no capture file' 3; exit 1 }

    $bin = Resolve-TranslateBin
    if (-not $bin) { Show-HerdrNotice 'pane-translate: translate not found (scoop install daviddwlee84/translate)' 3; exit 1 }

    $bytes = (Get-Item -LiteralPath $capture).Length
    Write-Host "translate $label — $bytes bytes, ~$([int]($bytes / 160) + 5)s" -ForegroundColor Cyan
    Write-Host ''

    $rc = 0
    try {
        $body = Invoke-HerdrTranslate -Bin $bin -CaptureFile $capture -To $to
        if ($LASTEXITCODE -ne 0) { $rc = $LASTEXITCODE }
        if ($body) { $body | Out-Host }
    } finally {
        # Also runs when translate throws, so a failed call does not leave the
        # capture in TEMP. (The unix side additionally traps SIGHUP for a pane
        # closed mid-translation; PowerShell has no equivalent hook.)
        Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
    }

    # herdr panes keep their own scrollback, so holding here is the whole viewer:
    # scroll back through the result with herdr's own keys, then press Enter.
    $hold = if ($env:HERDR_RUN_HOLD) { $env:HERDR_RUN_HOLD } else { 'fail' }
    $wait = switch ($hold) { 'never' { $false } 'always' { $true } default { $true } }
    if ($wait) { Read-Host "`n[exit $rc] press Enter to close" | Out-Null }
    exit $rc
}

# ---------------------------------------------------------------------------
# Capture side.
# ---------------------------------------------------------------------------
if (-not (Test-HerdrPresent)) { exit 1 }
if (-not (Assert-HerdrServerFresh)) { exit 1 }

$mode = 'visible'
$paneArg = ''
$to = ''
$act = 'split'
$positional = 0
for ($k = 0; $k -lt $argv.Count; $k++) {
    switch -regex ($argv[$k]) {
        '^--to$' { if ($k + 1 -ge $argv.Count) { Show-Usage }; $to = $argv[$k + 1]; $k++ }
        '^--to=' { $to = $argv[$k].Substring(5) }
        '^--copy$' { $act = 'copy' }
        '^--inline$' { $act = 'inline' }
        '^--dry-run$' { $act = 'dry' }
        '^-' { Show-Usage }
        default {
            $positional++
            if ($positional -eq 1) { $mode = $argv[$k] }
            elseif ($positional -eq 2) { $paneArg = $argv[$k] }
            else { Show-Usage }
        }
    }
}

# herdr-plus injects $HERDR_PLUS_PANE_ID; the keybind injects $HERDR_ACTIVE_PANE_ID
# (as an env var, since it does not expand $VAR in the command string here).
if (-not $paneArg -or $paneArg -like '$*') { $paneArg = $env:HERDR_PLUS_PANE_ID }
$pane = Resolve-HerdrPane $paneArg
if (-not $pane) { Show-HerdrNotice 'pane-translate: could not determine a pane id' 3; exit 1 }

$lines = 0
if ($mode -eq 'visible') {
    $source = 'visible'
} elseif ($mode -match '^recent:(\d+)$') {
    # recent-unwrapped joins soft wraps, so long lines never reach the translator
    # broken mid-word. 1000 is herdr's hard per-read ceiling.
    $source = 'recent-unwrapped'
    $lines = [Math]::Min(1000, [Math]::Max(1, [int]$Matches[1]))
} else {
    Show-HerdrNotice "pane-translate: mode must be visible or recent:N (got '$mode')" 3
    exit 64
}

$content = Get-HerdrPaneText -PaneId $pane -Source $source -Lines $lines
if ($null -eq $content) { Show-HerdrNotice "pane-translate: failed to read $pane" 3; exit 1 }

$budget = if ($env:HERDR_TRANSLATE_MAX_CHARS) { [int]$env:HERDR_TRANSLATE_MAX_CHARS } else { 12000 }
$result = Format-HerdrCapture -Lines ($content -split "`r?`n") -Mode $mode -Budget $budget
if (-not $result.Text) { Show-HerdrNotice "pane-translate: nothing to translate in $pane" 3; exit 1 }

$label = "$pane ($mode)"
$capture = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-translate-{0}-{1}.txt" -f ($pane -replace ':', '_'), $PID)
Set-Content -LiteralPath $capture -Value $result.Text -Encoding utf8

switch ($act) {
    'dry' {
        $result.Text | Out-Host
        Write-Host "--- $label`: $($result.Stats)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
    }
    'copy' {
        $bin = Resolve-TranslateBin
        if (-not $bin) {
            Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
            Show-HerdrNotice 'pane-translate: translate not found (scoop install daviddwlee84/translate)' 3
            exit 1
        }
        if (-not $to) { $to = $env:HERDR_TRANSLATE_TO }
        $body = Invoke-HerdrTranslate -Bin $bin -CaptureFile $capture -To $to
        Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
        if (Set-HerdrClipboard (($body | Out-String).TrimEnd())) {
            $null = & herdr notification show "Translated $label" --body $result.Stats 2>&1
            Show-HerdrNotice "copied translation of $label" 1.5
        } else { exit 1 }
    }
    'inline' {
        # prefix+t: a command pane already owns a PTY, so no split is needed.
        $self = Join-Path $PSScriptRoot 'pane-translate.ps1'
        $a = @('__view', $capture, $label)
        if ($to) { $a += @('--to', $to) }
        & $self @a
        exit $LASTEXITCODE
    }
    'split' {
        # Quick Action path: `sh -c`-equivalent, no PTY. The capture is already on
        # disk — note it was taken BEFORE the split, because splitting narrows the
        # source pane and makes the app re-wrap what we just read.
        $j = Invoke-HerdrJson pane split $pane --direction right --ratio 0.5
        $new = if ($j) { $j.result.pane.pane_id } else { $null }
        if (-not $new) {
            Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
            Show-HerdrNotice 'pane-translate: split failed' 3
            exit 1
        }
        # `pane run` types into the new pane's shell, so wait for one to exist.
        for ($n = 0; $n -lt 30; $n++) {
            $pi = Invoke-HerdrJson pane process-info --pane $new
            if ($pi -and $pi.result.process_info.shell_pid) { break }
            Start-Sleep -Milliseconds 100
        }
        $self = Join-Path $PSScriptRoot 'pane-translate.ps1'
        $cmd = "pwsh -NoProfile -File `"$self`" __view `"$capture`" `"$label`""
        if ($to) { $cmd += " --to `"$to`"" }
        $null = & herdr pane run $new $cmd 2>&1
        if ($LASTEXITCODE -ne 0) { Show-HerdrNotice "pane-translate: could not start the viewer in $new" 3; exit 1 }
        # No focus step: this repo has no focus-pane.py port, and `pane focus` is
        # directional only. Reach the viewer with prefix+l.
        # See backlog/herdr-windows-port-verification.md.
    }
}
