# ~/.config/herdr/review-mark.ps1
# Source: dot_config/herdr/review-mark.ps1 (managed by chezmoi)
#
# Set / clear / toggle a per-pane "review-pending" flag on a herdr pane, using
# herdr's per-pane metadata TOKENS (`herdr pane report-metadata … --source review
# --token review=…`). PowerShell port of the parent repo's
# dot_config/herdr/executable_review-mark.sh.
#
# Why a metadata token and not agent state: it is pushed under a dedicated
# `--source review`, ORTHOGONAL to herdr's native agent detection. A pane can
# carry `tokens.review = "⭐ REVIEW"` while `agent_status:"idle"` — so peeking
# into a done pane (which collapses it to idle) does NOT wipe the flag.
# Omitting --ttl-ms makes it persistent (no auto-expiry).
#
# herdr >= 0.7.4 ONLY. 0.7.4 removed `--custom-status` / the flat `custom_status`
# field in favour of this namespaced token map. The removal is NOT listed as a
# breaking change upstream — on an older herdr this dies with
# `unknown --custom-status`.
#
# Unlike `custom_status`, a token is NOT rendered by the sidebar automatically —
# it only shows where a row layout references it. `$review` is wired into
# `[ui.sidebar.agents] rows` in .chezmoitemplates/herdr/config.toml; drop the
# token name here and you must drop it there too.
#
# Usage:
#   review-mark.ps1 set    <pane_id> [glyph-text]   # default "⭐ REVIEW"
#   review-mark.ps1 clear  <pane_id>
#   review-mark.ps1 toggle <pane_id> [glyph-text]
#
# Consumers: the prefix+m keybind, the herdr-review tv channel's focus_clear
# action, and hmark/hunmark in profile.d/25_herdr.ps1.

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

$SourceId = 'review'
$Token = 'review'            # the tv channel keys off its PRESENCE, not its text
$DefaultStatus = "$([char]0x2B50) REVIEW"

function Show-Usage {
    Write-Host 'usage: review-mark.ps1 set|clear|toggle <pane_id> [glyph-text]'
    exit 64
}

if (-not (Test-HerdrPresent)) { exit 1 }

$action = if ($Argument.Count -ge 1) { $Argument[0] } else { '' }
$paneArg = if ($Argument.Count -ge 2) { $Argument[1] } else { '' }
$status = if ($Argument.Count -ge 3) { $Argument[2] } else { $DefaultStatus }

if (-not $action) { Show-Usage }

$pane = Resolve-HerdrPane -PaneId $paneArg
if (-not $pane) { Write-Host 'review-mark: could not determine a pane id' -ForegroundColor Red; exit 1 }

function Set-ReviewFlag {
    & herdr pane report-metadata $pane --source $SourceId --token "$Token=$status" | Out-Null
    Write-Host "review flag set on $pane"
}

function Clear-ReviewFlag {
    & herdr pane report-metadata $pane --source $SourceId --clear-token $Token | Out-Null
    Write-Host "review flag cleared on $pane"
}

switch ($action) {
    'set' { Set-ReviewFlag }
    'clear' { Clear-ReviewFlag }
    'toggle' {
        # Presence of the token IS the flag — a cleared token is absent from the
        # map, so no substring match is needed (unlike the pre-0.7.4 single
        # `custom_status` string that every source shared).
        $j = Invoke-HerdrJson pane get $pane
        $current = ''
        if ($j -and $j.result.pane.PSObject.Properties['tokens'] -and $j.result.pane.tokens) {
            $t = $j.result.pane.tokens
            if ($t.PSObject.Properties[$Token]) { $current = [string]$t.$Token }
        }
        if ($current) { Clear-ReviewFlag } else { Set-ReviewFlag }
    }
    default { Show-Usage }
}
