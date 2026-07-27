# ~/.config/herdr/new-tab-at-space-root.ps1
# Source: dot_config/herdr/new-tab-at-space-root.ps1 (managed by chezmoi)
#
# Open a NEW TAB rooted at the WORKSPACE ("space") directory, NOT the focused
# pane's live cwd. PowerShell port of the parent repo's
# dot_config/herdr/executable_new-tab-at-space-root.sh.
#
# Why this exists: on herdr >=0.7.x, `new_cwd = "follow"` makes a new tab inherit
# the FOCUSED pane's cwd — herdr issue #912 changed `follow` so new tabs behave
# like pane splits, and the older "new tab opens at the workspace's initial dir"
# was treated as a bug and removed. There is NO new_cwd value for "workspace
# dir", so we compute it and pass it via `herdr tab create --cwd`. (herdr exposes
# no workspace-level cwd field either — `herdr workspace get` has no cwd — so it
# must be derived.)
#
# "Space dir" = the workspace's ROOT tab's pane cwd, where the root tab is the
# lowest-numbered tab — the one whose live-cwd basename herdr uses as the
# workspace label. We prefer the live cwd (foreground_cwd, matches the label),
# falling back to the shell startup cwd.
#
# Bound to prefix+C. prefix+c and the mouse "+" button keep herdr's native
# follow-the-focused-pane behaviour.
#
# Usage:
#   new-tab-at-space-root.ps1 [pane_id]

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

if (-not (Test-HerdrPresent)) { exit 1 }

$paneArg = if ($Argument -and $Argument.Count -ge 1) { $Argument[0] } else { '' }
$pane = Resolve-HerdrPane -PaneId $paneArg
if (-not $pane) {
    Show-HerdrNotice 'new-tab-at-space-root: no pane id (pass one, or run inside herdr)'
    exit 64
}

$paneJson = Invoke-HerdrJson pane get $pane
$wid = if ($paneJson) { $paneJson.result.pane.workspace_id } else { $null }
if (-not $wid) {
    Show-HerdrNotice "new-tab-at-space-root: could not resolve workspace for pane $pane"
    exit 1
}

# Root tab = lowest tab number in the workspace (herdr labels the space after it).
$tabs = Invoke-HerdrJson tab list --workspace $wid
$rootTab = $null
if ($tabs -and $tabs.result.tabs) {
    $rootTab = ($tabs.result.tabs | Sort-Object { [int]$_.number } | Select-Object -First 1).tab_id
}
if (-not $rootTab) {
    Show-HerdrNotice "new-tab-at-space-root: no tabs in workspace $wid"
    exit 1
}

# `herdr tab get` returns tab metadata only (no pane cwd), so read the root tab's
# pane cwd from the full pane list. Prefer live cwd so it matches the space label.
$panes = Invoke-HerdrJson pane list
$root = $null
if ($panes -and $panes.result.panes) {
    $rootPane = $panes.result.panes | Where-Object { $_.tab_id -eq $rootTab } | Select-Object -First 1
    if ($rootPane) {
        foreach ($c in $rootPane.foreground_cwd, $rootPane.cwd) { if ($c) { $root = $c; break } }
    }
}
if (-not $root) {
    Show-HerdrNotice "new-tab-at-space-root: could not resolve root dir for $rootTab"
    exit 1
}

# The only state-mutating call in this script. Capture it: on failure the pane
# closes immediately, so an undiagnosed error is indistinguishable from a dead
# keybind (this is how the protocol-mismatch trap stayed hidden for so long).
$raw = @(& herdr tab create --workspace $wid --cwd $root --focus 2>&1)
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    $s = Split-HerdrStream $raw
    $code = Resolve-HerdrFailure $s.Err $s.Out   # warns if it is a protocol mismatch
    if ($code -ne 'protocol_mismatch') {
        $detail = if ($code) { $code } else { "$($s.Err)$($s.Out)" }
        Show-HerdrNotice "new-tab-at-space-root: herdr tab create failed — $detail" 3
    }
}
exit $rc
