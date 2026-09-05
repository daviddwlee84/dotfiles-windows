#Requires -Version 7.4
#Requires -PSEdition Core
# ~/.config/herdr/run-command.ps1
# Source: dot_config/herdr/run-command.ps1 (managed by chezmoi)
#
# Run an ARBITRARY command in the focused pane's cwd, inside a floating popup that
# closes by itself when the command exits. PowerShell port of the parent repo's
# dot_config/herdr/executable_run-command.sh. This is the generalisation of the
# hardcoded prefix+G (lazygit) binding — the tmux `display-popup -E` experience,
# with a command you pick or type instead of one baked into the config.
#
# Why a popup and not the alternatives:
#   - type = "pane" (prefix+G/M/`) splits the TILED layout for the duration.
#   - prefix+c + type + exit is four steps and churns the tab bar.
#   - type = "popup" (herdr >= 0.7.4) is session-modal and floats ABOVE the
#     layout, so nothing reflows and you land exactly where you were.
# It also cannot live as a herdr-plus Quick Action (prefix+y): those run with no
# PTY/stdin, and every Quick Action is a fixed command string with no free-text field.
#
# Usage:
#   run-command.ps1 [--cwd DIR] [--no-profile] [--] [QUERY...]
# --cwd         directory to run in; defaults to $HERDR_ACTIVE_PANE_CWD (injected
#               by the keybind) -> the pane's foreground_cwd -> the process cwd.
# --no-profile  run the command with `pwsh -NoProfile` (fast, no repo aliases)
#               instead of the default profile-loading pwsh. This is the analog of
#               the unix script's `--sh` flag: there, the default is `$SHELL -ic`
#               so the interactive rc (and this repo's aliases/functions) resolve;
#               here that means loading $PROFILE.
# QUERY         seeds the picker.
#
# Exit behaviour is governed by $env:HERDR_RUN_HOLD:
#   fail (default)  close on success, wait for a key on non-zero exit
#   always          always wait for a key
#   never           never wait
#
# Consumer: the prefix+E keybind.

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

function Show-Usage {
    Write-Host 'usage: run-command.ps1 [--cwd DIR] [--no-profile] [--] [QUERY...]'
    exit 64
}

$argv = @($Argument | Where-Object { $null -ne $_ })
$cwdArg = ''
$noProfile = $false
$queryParts = [System.Collections.Generic.List[string]]::new()
$positional = $false
for ($i = 0; $i -lt $argv.Count; $i++) {
    if ($positional) { $queryParts.Add($argv[$i]); continue }
    switch -Regex ($argv[$i]) {
        '^--cwd$' { $cwdArg = $argv[++$i] }
        '^--cwd=' { $cwdArg = $argv[$i] -replace '^--cwd=', '' }
        '^(--no-profile|--sh)$' { $noProfile = $true }
        '^(-h|--help)$' { Show-Usage }
        '^--$' { $positional = $true }
        '^-' { Show-Usage }
        default { $positional = $true; $queryParts.Add($argv[$i]) }
    }
}
$query = $queryParts -join ' '

$cwd = Resolve-HerdrCwd -Cwd $cwdArg -PaneId (Resolve-HerdrPane)

# --- history source ---------------------------------------------------------
# The unix script reads ~/.zsh_history; the Windows equivalent is PSReadLine's
# ConsoleHost_history.txt. Under -NoProfile PSReadLine may not be loaded, so ask
# it only if available and fall back to the documented default location.
function Get-CommandHistory {
    $path = $null
    try {
        $opt = Get-PSReadLineOption -ErrorAction Stop
        if ($opt -and $opt.HistorySavePath) { $path = $opt.HistorySavePath }
    } catch { $path = $null }
    if (-not $path -and $env:APPDATA) {
        $path = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }

    # Newest-first, de-duplicated. Lines ending in a backtick are PowerShell
    # line-continuations (multi-line history entries) — skip them, the same way
    # the unix version skips trailing-backslash zsh entries.
    $lines = Get-Content -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }
    [array]::Reverse($lines)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $lines) {
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t.EndsWith('`')) { continue }
        if ($seen.Add($t)) { $out.Add($t) }
    }
    $out
}

# --- pick the command -------------------------------------------------------
$cmd = ''
$leaf = Split-Path -Leaf $cwd
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    # --print-query + --expect together make the outcomes distinguishable. The
    # line layout is NOT fixed — fzf omits trailing lines it has nothing for:
    #
    #   Enter     with a match     rc 0    query \n ""        \n selection
    #   Alt+Enter with a match     rc 0    query \n alt-enter \n selection
    #   Enter     with no match    rc 1    query                            (1 line)
    #   Alt+Enter with no match    rc 1    query \n alt-enter
    #   Esc                        rc 130  -
    #
    # Alt+Enter exists because plain Enter cannot express "run exactly what I
    # typed" while fzf still has a match: type `ls -la` with `ls -la C:\tmp` in
    # history and Enter takes the history entry. Alt+ (not Ctrl+) per the repo's
    # keybinding convention.
    $out = @(Get-CommandHistory | fzf `
            --print-query --expect=alt-enter --no-sort --height=100% --border `
            --query="$query" `
            --header='enter: run highlighted - alt-enter: run what you typed - esc: cancel' `
            --prompt="run [$leaf]> ")
    $rc = $LASTEXITCODE
    if ($rc -notin 0, 1) { exit 0 }   # 130 = Esc, or fzf failed -> run nothing

    $key = if ($out.Count -ge 2) { $out[1] } else { '' }
    if ($key -eq 'alt-enter') {
        $cmd = if ($out.Count -ge 1) { $out[0] } else { '' }      # literal query, always
    } elseif ($rc -eq 0 -and $out.Count -ge 3) {
        $cmd = $out[2]                                            # highlighted selection
    } else {
        $cmd = if ($out.Count -ge 1) { $out[0] } else { '' }      # no match -> the query
    }
} else {
    if ($query) { $cmd = $query }
    else { $cmd = Read-Host -Prompt "run [$leaf]> " }
}

if (-not $cmd) { exit 0 }

# --- run it -----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $cwd)) {
    Write-Host "run-command: cannot cd to $cwd" -ForegroundColor Red
    exit 1
}
Push-Location -LiteralPath $cwd
try {
    $pwshArgs = @()
    if ($noProfile) { $pwshArgs += '-NoProfile' }
    $pwshArgs += @('-Command', $cmd)
    & pwsh @pwshArgs
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}

# --- hold policy ------------------------------------------------------------
$hold = if ($env:HERDR_RUN_HOLD) { $env:HERDR_RUN_HOLD } else { 'fail' }
$wait = switch ($hold) {
    'never' { $false }
    'always' { $true }
    default { $rc -ne 0 }
}
if ($wait) {
    Write-Host ''
    Write-Host "[exit $rc] press Enter to close..." -NoNewline
    $null = Read-Host
}

exit $rc
