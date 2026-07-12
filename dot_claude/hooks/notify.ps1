#Requires -Version 7
# notify.ps1 — Claude Code notification hook -> Windows toast via apprise.
#
# Native-pwsh port of the parent (macOS/Linux) repo's dot_claude/hooks/notify.sh.
# Reads the hook JSON payload from stdin, builds a title/body, and fires
# `apprise --tag desktop`, which resolves to the native windows:// backend
# configured in ~/.config/apprise/apprise.yaml. Wired to the Notification and
# Stop events by claude/settings-overlay.json.
#
# Best-effort by design: it must never block or fail a Claude turn, so it
# swallows every error and always exits 0. If apprise isn't installed yet, it
# simply no-ops.
$ErrorActionPreference = 'SilentlyContinue'

# Claude launches hook commands with `pwsh -NoProfile`, so profile.d/00_env.ps1
# hasn't run and ~/.local/bin (the uv tool bin dir holding apprise.exe) may not
# be on PATH. Prepend it defensively.
$localBin = Join-Path $HOME '.local\bin'
if ((Test-Path $localBin -PathType Container) -and ($env:PATH -notlike "*$localBin*")) {
    $env:PATH = "$localBin;$env:PATH"
}

$raw = [Console]::In.ReadToEnd()
try { $payload = $raw | ConvertFrom-Json } catch { $payload = $null }

$evt   = if ($payload.hook_event_name) { $payload.hook_event_name } else { 'unknown' }
$title = if ($payload.title) { $payload.title } else { 'Claude Code' }
$msg   = "$($payload.message)"
$ntype = "$($payload.notification_type)"

# The Stop event carries no title/message — synthesize a completion toast
# (matches the parent notify.sh behavior).
if ($evt -eq 'Stop') { $title = 'Claude Code'; $msg = 'Task finished' }

$fullTitle = if ($ntype) { "$title [$ntype]" } else { $title }
# windows:// caps the body around 250 chars; trim so a long message still toasts.
if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 247) + '...' }

if (Get-Command apprise -ErrorAction SilentlyContinue) {
    $cfg = Join-Path $HOME '.config\apprise\apprise.yaml'
    if (Test-Path $cfg) {
        apprise --config $cfg --tag desktop --title $fullTitle --body $msg *> $null
    } else {
        # Config not deployed yet — fall back to an inline windows:// URL.
        apprise --title $fullTitle --body $msg 'windows://' *> $null
    }
}
exit 0
