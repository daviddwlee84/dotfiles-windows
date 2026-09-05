#Requires -Version 7.4
#Requires -PSEdition Core
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
# "Space dir" = the workspace's oldest surviving tab's pane cwd. The shared
# derivation lives in Resolve-HerdrSpaceRoot because pane-copy.ps1's
# `prefix+y -> Copy space: dir` action needs the exact same answer.
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

$root = Resolve-HerdrSpaceRoot -WorkspaceId $wid
if (-not $root) {
    Show-HerdrNotice "new-tab-at-space-root: could not resolve root dir for workspace $wid"
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
