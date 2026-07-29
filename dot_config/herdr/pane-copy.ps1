# ~/.config/herdr/pane-copy.ps1
# Source: dot_config/herdr/pane-copy.ps1 (managed by chezmoi)
#
# Copy distilled facts about a herdr pane to the Windows clipboard. PowerShell
# port of the parent repo's dot_config/herdr/executable_pane-copy.sh. Three targets:
#
#   process  the foreground processes running in the pane (cmdline + pid + cwd)
#   coord    the pane's coordinate in herdr's Session > Workspace > Tab > Pane
#            hierarchy, in a paste-ready form (the ids the herdr CLI accepts, plus
#            the socket path that selects a non-default session — there is NO
#            --session flag on the pane/tab/workspace subcommands)
#   content  the pane's terminal content — visible screen (--source visible) or
#            the full retained scrollback (--source recent, the default)
#
# The pane defaults to $HERDR_ACTIVE_PANE_ID (injected by the keybind), then
# $HERDR_PLUS_PANE_ID's herdr-plus equivalent, then `herdr pane current`.
#
# Clipboard sink is Set-Clipboard — the Windows equivalent of the unix side's
# `x copy` (which auto-selects pbcopy / wl-copy / xclip / OSC 52).
#
# Usage:
#   pane-copy.ps1 process [PANE_ID]
#   pane-copy.ps1 coord   [PANE_ID]
#   pane-copy.ps1 content [PANE_ID] [--source visible|recent]
#
# Consumers: the prefix+P/D/V/S keybinds and the copy-pane-* herdr-plus Quick
# Actions.

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

function Show-Usage {
    # Held: without a pause a bad arg shape looks identical to a dead keybind.
    Show-HerdrNotice 'usage: pane-copy.ps1 process|coord|content [PANE_ID] [--source visible|recent]' 3
    exit 64
}

if (-not (Test-HerdrPresent)) { exit 1 }

$argv = @($Argument | Where-Object { $null -ne $_ })
if ($argv.Count -lt 1) { Show-Usage }
$action = $argv[0]
$rest = if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] } else { @() }

$paneArg = ''
$source = 'recent'
for ($i = 0; $i -lt $rest.Count; $i++) {
    switch -Regex ($rest[$i]) {
        '^--source$' { $source = $rest[++$i] }
        '^--source=' { $source = $rest[$i] -replace '^--source=', '' }
        '^-' { Show-Usage }
        default { if (-not $paneArg) { $paneArg = $rest[$i] } else { Show-Usage } }
    }
}

# herdr-plus passes its own pane var; fall through the same chain otherwise.
if (-not $paneArg -and $env:HERDR_PLUS_PANE_ID) { $paneArg = $env:HERDR_PLUS_PANE_ID }
$pane = Resolve-HerdrPane -PaneId $paneArg
if (-not $pane) { Show-HerdrNotice 'pane-copy: could not determine a pane id'; exit 1 }

switch ($action) {
    'process' {
        $j = Invoke-HerdrJson pane process-info --pane $pane
        if (-not $j) { Show-HerdrNotice "pane-copy: failed to read process info for $pane"; exit 1 }
        $p = $j.result.process_info
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("pane $($p.pane_id)  (shell pid $($p.shell_pid))")
        foreach ($fp in @($p.foreground_processes)) {
            if ($fp) { $lines.Add("  $($fp.cmdline)  [pid $($fp.pid), cwd $($fp.cwd)]") }
        }
        if ($lines.Count -eq 1) { $lines.Clear(); $lines.Add("pane $pane  (no foreground processes)") }
        if (Set-HerdrClipboard ($lines -join "`n")) { Write-Host "copied process info for $pane" }
    }
    'coord' {
        $pj = Invoke-HerdrJson pane get $pane
        if (-not $pj) { Show-HerdrNotice "pane-copy: failed to read pane $pane"; exit 1 }
        $ws = $pj.result.pane.workspace_id
        $tb = $pj.result.pane.tab_id
        $pn = $pj.result.pane.pane_id

        $wsj = Invoke-HerdrJson workspace get $ws
        $wsLabel = if ($wsj) { $wsj.result.workspace.label } else { $null }
        $tbj = Invoke-HerdrJson tab get $tb
        $tbLabel = if ($tbj) { $tbj.result.tab.label } else { $null }

        $sock = $env:HERDR_SOCKET_PATH
        $session = 'default'
        if ($sock) {
            $sj = Invoke-HerdrJson session list --json
            if ($sj -and $sj.sessions) {
                $match = $sj.sessions | Where-Object { $_.socket_path -eq $sock } | Select-Object -First 1
                if ($match -and $match.name) { $session = $match.name }
            }
        }

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("session=$session")
        $lines.Add("workspace=$ws$(if ($wsLabel) { " ($wsLabel)" })")
        $lines.Add("tab=$tb$(if ($tbLabel) { " ($tbLabel)" })")
        $lines.Add("pane=$pn")
        if ($sock) { $lines.Add("socket=$sock") }
        $lines.Add("# herdr pane get $pn")

        if (Set-HerdrClipboard ($lines -join "`n")) { Write-Host "copied coordinate for $pane" }
    }
    'content' {
        if ($source -notin 'visible', 'recent', 'recent-unwrapped') {
            Write-Host 'pane-copy: --source must be visible|recent|recent-unwrapped'
            exit 64
        }
        $body = Get-HerdrPaneText -PaneId $pane -Source $source
        if ($null -eq $body) { Show-HerdrNotice "pane-copy: failed to read content of $pane"; exit 1 }
        if (Set-HerdrClipboard $body) { Write-Host "copied $source content for $pane" }
    }
    default { Show-Usage }
}
