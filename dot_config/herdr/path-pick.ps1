# ~/.config/herdr/path-pick.ps1
# Source: dot_config/herdr/path-pick.ps1 (managed by chezmoi)
#
# Copy-a-file-path picker — the copy-path sibling of url-pick.ps1 (which OPENS
# URLs). PowerShell port of the parent repo's
# dot_config/herdr/executable_path-pick.sh.
#
# Reads the focused pane, extracts path-like tokens (borrowing extrakto's path
# heuristics), and presents a TWO-TIER fzf list: paths that EXIST relative to the
# pane cwd on top (copied as their resolved ABSOLUTE path), unverified candidates
# (as-seen) below a separator. The choice goes to the clipboard.
#
# The existence check is the noise-killer extrakto lacks: file paths have no
# scheme:// marker, so regex alone matches dates (2024/01/02), rates (10k/s) and
# fractions (1/2); validating against the pane's live cwd drops nearly all of it.
#
# WINDOWS DIFFERENCE from the unix original: the candidate regex also accepts
# drive-absolute (C:\src\foo) and backslash-separated paths, which simply do not
# occur on the unix side. Both separators are normalised for the existence test.
#
# Usage:
#   path-pick.ps1 [PANE_ID] [--source visible|recent] [--cwd DIR]
#
# Consumer: the prefix+p keybind.

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

function Show-Usage {
    Write-Host 'usage: path-pick.ps1 [PANE_ID] [--source visible|recent] [--cwd DIR]'
    exit 64
}

if (-not (Test-HerdrPresent)) { exit 1 }
if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Show-HerdrNotice 'path-pick: fzf is required (scoop install fzf)'; exit 1
}

$argv = @($Argument | Where-Object { $null -ne $_ })
$paneArg = ''
$source = 'visible'
$cwdArg = ''
for ($i = 0; $i -lt $argv.Count; $i++) {
    switch -Regex ($argv[$i]) {
        '^--source$' { $source = $argv[++$i] }
        '^--source=' { $source = $argv[$i] -replace '^--source=', '' }
        '^--cwd$' { $cwdArg = $argv[++$i] }
        '^--cwd=' { $cwdArg = $argv[$i] -replace '^--cwd=', '' }
        '^(-h|--help)$' { Show-Usage }
        '^-' { Show-Usage }
        default { if (-not $paneArg) { $paneArg = $argv[$i] } else { Show-Usage } }
    }
}
if ($source -notin 'visible', 'recent', 'recent-unwrapped') {
    Write-Host 'path-pick: --source must be visible|recent'; exit 64
}

$pane = Resolve-HerdrPane -PaneId $paneArg
if (-not $pane) { Show-HerdrNotice 'path-pick: could not determine a pane id'; exit 1 }
$cwd = Resolve-HerdrCwd -Cwd $cwdArg -PaneId $pane

$content = Get-HerdrPaneText -PaneId $pane -Source $source
if ($null -eq $content) { Show-HerdrNotice "path-pick: failed to read pane $pane"; exit 1 }

# Path candidates (extrakto heuristics + Windows drive/backslash forms).
#
# ONE combined alternation, not several passes: the regex engine consumes each
# match, so the bare-filename alternative can never re-fire INSIDE an already
# matched path. Scanning with separate patterns instead yields `main.rs` next to
# `src/main.rs`, `guide.md` next to `docs/guide.md`, … — pure noise. Verified
# against the unix original's single `grep -oE` alternation: same input, same set.
#
# Alternatives, in priority order:
#   1. quoted drive path   "C:\Program Files\x"   (the only form where a path
#                          containing SPACES can be delimited unambiguously)
#   2. bare drive path     C:\src\foo  /  C:/src/foo
#   3. slash/backslash     ~/x  ./x  ../x  a/b/c  a\b\c
#   4. bare filename.ext
$pattern = '"[A-Za-z]:[\\/][^"]+"' +
    '|[A-Za-z]:[\\/][^\s"'':;,()]+' +
    '|(~|\.\.?)?[\\/]?[A-Za-z0-9._+~-]+([\\/][A-Za-z0-9._+~-]+)+' +
    '|[A-Za-z0-9._+-]+\.[A-Za-z0-9]{1,8}'

$cands = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()
foreach ($m in [regex]::Matches($content, $pattern)) {
    $t = $m.Value -replace '^"', '' -replace '[",):;]+$', ''
    if (-not $t) { continue }
    # extrakto's exclusions: fractions (1/2) and rates (10k/s).
    if ($t -match '^[0-9]+/[0-9]+$' -or $t -match '[kKmMgG]/s$') { continue }
    if ($seen.Add($t)) { $cands.Add($t) }
}

if ($cands.Count -eq 0) {
    Show-HerdrNotice "path-pick: no file paths found in pane $pane ($source)"
    exit 0
}

# Two tiers: exists-under-cwd (resolved absolute) vs the rest (as-seen).
$exist = [System.Collections.Generic.List[string]]::new()
$maybe = [System.Collections.Generic.List[string]]::new()
foreach ($c in $cands) {
    $base = $c -replace ':[0-9]+(:[0-9]+)?$', ''    # strip :line[:col] for the test
    if ($base -match '^~[\\/]') {
        $abs = Join-Path $HOME ($base -replace '^~[\\/]', '')
    } elseif ([System.IO.Path]::IsPathRooted($base)) {
        $abs = $base
    } else {
        $abs = Join-Path $cwd $base
    }
    $resolved = $null
    try {
        if (Test-Path -LiteralPath $abs) {
            $resolved = (Resolve-Path -LiteralPath $abs -ErrorAction Stop).Path
        }
    } catch { $resolved = $null }
    if ($resolved) { $exist.Add($resolved) } else { $maybe.Add($c) }
}

$sep = "$([char]0x2500 * 8)  unverified (not found under cwd)  $([char]0x2500 * 8)"
$list = [System.Collections.Generic.List[string]]::new()
foreach ($e in ($exist | Sort-Object -Unique)) { $list.Add($e) }
if ($maybe.Count -gt 0) {
    $list.Add($sep)
    foreach ($m in ($maybe | Sort-Object -Unique)) { $list.Add($m) }
}

$chosen = $list | fzf --multi --no-sort --height=100% --border --prompt='path> ' --header="Enter=copy - Tab=multi - cwd=$cwd"
if ($LASTEXITCODE -ne 0 -or -not $chosen) { exit 0 }

# Drop the separator if it slipped into the selection; copy the rest.
$picked = @($chosen | Where-Object { $_ -and $_ -ne $sep })
if ($picked.Count -eq 0) { exit 0 }

if (Set-HerdrClipboard ($picked -join "`n")) {
    Write-Host "copied $($picked.Count) path(s)"
}
