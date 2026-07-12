# Plan: apprise `windows://` desktop toasts for Claude Code

## Context

The parent (macOS/Linux) dotfiles repo wires Claude Code desktop notifications
through a single clean pattern: an OS-agnostic hook script (`notify.sh`) that
just calls `apprise --tag desktop`, with all platform routing delegated to a
chezmoi-templated `~/.config/apprise/apprise.yaml`. That template **already has
a `windows://` branch** — the Windows work was 90% designed there but never
shipped in this Windows-only repo, which today has **no notification mechanism
at all** and an overlay with **no `hooks` key**.

This change ports that pattern natively to Windows: install `apprise` (with the
`pywin32` backend `windows://` needs), ship an apprise config selecting the
native Windows toast backend, add a **native-pwsh** `notify.ps1` hook, and wire
the Claude `Notification` + `Stop` events to it via `claude/settings-overlay.json`
— mirroring the parent's `dot_claude/modify_settings.json`. Because we're now
adding hooks, the overlay merger is upgraded to the parent's **additive,
hook-aware** merge so it never clobbers hook entries other tools/the user add.

**Decisions (confirmed with user):**
- **Gating:** piggyback on `installCodingAgents` (matches parent's on-by-default
  behavior; no new init prompt → no invariant-#1 CI/doc-flag upkeep).
- **Events:** `Notification` **and** `Stop` (full parity with parent `notify.sh`).

`windows://` facts (appriseit.com/services/windows): needs `pywin32`; URL is bare
`windows://` (`?duration=N` optional, default 12s); body capped ~250 chars;
local-desktop only (exactly our use case).

## Changes

### 1. Install apprise — `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`

Inside the existing `{{ "{{ if .installCodingAgents -}}" }}` block (currently
ends after `Scoop-Install @('extras/opencode-desktop')`, ~line 269), add — using
the exact `uv tool install` + `Have uv` + `Register-Failure` precedent that
LiteLLM uses at line 337:

```powershell
# apprise -> Windows toast notifications for the Claude Code notify hook.
# windows:// needs pywin32 (win32api/win32con/win32gui); pull it into the tool venv.
if (Have uv) {
    Info 'uv tool install apprise (+pywin32 for windows://)'
    uv tool install --with pywin32 apprise
    if ($LASTEXITCODE -ne 0) { Register-Failure 'uv:apprise' }
}
```

### 2. apprise config — new `dot_config/apprise/` (chezmoi → `~/.config/apprise/`)

`dot_config/` already deploys to `~/.config` (starship/yazi/herdr). Windows-only
repo, so no per-OS templating — just the `windows://` branch.

**`dot_config/apprise/apprise.yaml`** (new, plain — no template directives):
```yaml
version: 1
# Managed by chezmoi. Desktop toasts on Windows via the native windows://
# backend. The Claude notify hook (~/.claude/hooks/notify.ps1) targets this by
# the `desktop` tag. Add remote services (Discord/Slack/...) in custom.yaml,
# which is created once and never overwritten.
include:
  - custom.yaml
urls:
  - windows://:
      tag: desktop
```

**`dot_config/apprise/create_custom.yaml`** (new; `create_` = write once, never
overwrite — keeps user-added service URLs w/ secrets out of chezmoi's hands,
matching the parent repo):
```yaml
# Your custom Apprise services (created once; never overwritten by chezmoi).
#   urls:
#     - discord://webhook_id/webhook_token:
#         tag: chat
version: 1
urls: []
```

**`dot_config/apprise/example.yaml`** (new, optional, tracked reference) — a few
commented Discord/Slack/mailto examples + link to appriseit.com config docs
(mirror parent's `example.yaml`). Skip if trimming scope.

### 3. Native-pwsh hook — new `dot_claude/hooks/notify.ps1` (→ `~/.claude/hooks/notify.ps1`)

`dot_claude/` already deploys (the skill renderer). Native pwsh, not a ported
bash `notify.sh` (repo philosophy + avoids a jq dependency). Reads the hook JSON
from stdin, builds title/body, fires apprise. Best-effort, always `exit 0`.

```powershell
#Requires -Version 7
# Claude Code notification hook -> Windows toast via apprise (windows://).
# Native-pwsh port of the parent repo's dot_claude/hooks/notify.sh. Config lives
# in ~/.config/apprise/apprise.yaml (tag: desktop). Never throws; always exit 0.
$ErrorActionPreference = 'SilentlyContinue'

# Hooks launch pwsh with -NoProfile, so ~/.local/bin (uv tool bin, has apprise)
# isn't on PATH from 00_env.ps1 — add it here.
$localBin = Join-Path $HOME '.local\bin'
if ((Test-Path $localBin -PathType Container) -and ($env:PATH -notlike "*$localBin*")) {
    $env:PATH = "$localBin;$env:PATH"
}

$raw = [Console]::In.ReadToEnd()
try { $p = $raw | ConvertFrom-Json } catch { $p = $null }

$event = if ($p.hook_event_name) { $p.hook_event_name } else { 'unknown' }
$title = if ($p.title) { $p.title } else { 'Claude Code' }
$msg   = "$($p.message)"
$ntype = "$($p.notification_type)"

# Stop carries no title/message — synthesize a completion toast (matches notify.sh).
if ($event -eq 'Stop') { $title = 'Claude Code'; $msg = 'Task finished' }

$fullTitle = if ($ntype) { "$title [$ntype]" } else { $title }
if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 247) + '...' }  # windows:// body cap

if (Get-Command apprise -ErrorAction SilentlyContinue) {
    $cfg = Join-Path $HOME '.config\apprise\apprise.yaml'
    if (Test-Path $cfg) { apprise --config $cfg --tag desktop --title $fullTitle --body $msg *> $null }
    else                { apprise --title $fullTitle --body $msg 'windows://' *> $null }  # fallback
}
exit 0
```

### 4. Wire the hooks — `claude/settings-overlay.json`

Add a `hooks` key. Command mirrors the proven `statusLine` style in this same
file (POSIX-sh, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`, `exec`) — these command
strings run under Claude's cygwin/msys bash on Windows (cf. commit f7a73eb), and
msys path-mangles the arg to a Windows path for `pwsh.exe`, same as the existing
statusLine does for `node`:

```json
"hooks": {
  "Notification": [
    { "matcher": "", "hooks": [
      { "type": "command", "command": "exec pwsh -NoProfile -File \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notify.ps1\"" }
    ] }
  ],
  "Stop": [
    { "hooks": [
      { "type": "command", "command": "exec pwsh -NoProfile -File \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notify.ps1\"" }
    ] }
  ]
}
```

### 5. Make the merger hook-aware/additive — `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`

Today `Merge-Hashtable` **replaces arrays wholesale** (deliberately deferred:
"the current overlay has no `hooks` key… if you add hooks later, revisit"). We're
adding hooks now → port the parent's jq additive merge from
`dot_claude/modify_settings.json`: recurse into the `hooks` object, and for each
event **append only overlay entries whose `.hooks[0].command` isn't already
present**, preserving live entries. Add a `hooks` special-case to
`Merge-Hashtable` plus a helper:

```powershell
function Merge-Hashtable([hashtable]$base, [hashtable]$overlay) {
    foreach ($k in $overlay.Keys) {
        if ($k -eq 'hooks' -and ($overlay[$k] -is [hashtable])) {
            if ($base[$k] -isnot [hashtable]) { $base[$k] = @{} }
            Merge-ClaudeHooks $base[$k] $overlay[$k]
        }
        elseif ($base.ContainsKey($k) -and ($base[$k] -is [hashtable]) -and ($overlay[$k] -is [hashtable])) {
            Merge-Hashtable $base[$k] $overlay[$k]
        }
        else { $base[$k] = $overlay[$k] }
    }
}

# Additive per-event merge (mirrors modify_settings.json's jq reduce): append
# overlay entries whose .hooks[0].command isn't already live. Wholesale-replacing
# the arrays would clobber entries the user / other tools add at runtime.
function Merge-ClaudeHooks([hashtable]$base, [hashtable]$overlay) {
    foreach ($event in $overlay.Keys) {
        $live = if ($null -ne $base[$event]) { @($base[$event]) } else { @() }
        $liveCmds = @($live | ForEach-Object { $_.hooks[0].command })
        $additions = @($overlay[$event] | Where-Object {
            $cmd = $_.hooks[0].command
            (-not $cmd) -or ($liveCmds -notcontains $cmd)
        })
        $base[$event] = @($live + $additions)
    }
}
```

Update the script's header comment (it currently claims the parent's jq merge was
*not* ported) to note the additive hook merge is now in place.

### 6. Docs / source-of-truth mirrors (same commit)

- **`docs/tools.md` + `docs/tools.zh-TW.md`** — add apprise (Python tool via uv,
  installed with coding agents) and a one-line note that Claude Code fires
  `windows://` desktop toasts on Notification/Stop via `~/.claude/hooks/notify.ps1`.
- **`CLAUDE.md`** (Architecture → "Config surfaces") — extend the Claude Code
  bullet: the overlay now also wires `Notification`/`Stop` hooks → apprise toast,
  and the merger is additive/hook-aware; add `apprise` (`dot_config/apprise/`,
  `~/.config/apprise/`) to the config-surface list.
- No new init prompt ⇒ **no** `.chezmoi.toml.tmpl` / `windows.yml` / skill
  "what's enabled" changes (the point of piggybacking).

## Critical files

| File | Change |
|---|---|
| `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` | add `uv tool install --with pywin32 apprise` in the `installCodingAgents` block |
| `dot_config/apprise/apprise.yaml` | **new** — `windows://` + `tag: desktop`, `include: custom.yaml` |
| `dot_config/apprise/create_custom.yaml` | **new** — create-once user services |
| `dot_config/apprise/example.yaml` | **new (optional)** — reference examples |
| `dot_claude/hooks/notify.ps1` | **new** — native-pwsh stdin→apprise hook |
| `claude/settings-overlay.json` | add `hooks` (Notification + Stop) |
| `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl` | additive hook-aware merge |
| `docs/tools.md`, `docs/tools.zh-TW.md`, `CLAUDE.md` | doc mirrors |

## Verification

Off-Windows (this dev box) — the CLAUDE.md isolated-apply + render/parse idiom:

1. **JSON validity:** `claude/settings-overlay.json` parses (`python -c "import json,sys;json.load(open('claude/settings-overlay.json'))"`); the two YAML files parse (`python -c "import yaml;yaml.safe_load(open(...))"` if PyYAML available, else eyeball).
2. **Render + pwsh-parse** the two edited `.ps1.tmpl` files via `chezmoi execute-template` (with every prompt supplied, per CLAUDE.md), then `pwsh -NoProfile -c "[scriptblock]::Create((Get-Content -Raw r.ps1)) > $null"` to confirm they parse.
3. **Merge behavior (core risk):** with a local pwsh, dot-run the rendered merger against a synthetic `settings.json` and assert:
   - fresh file (no `hooks`) → gets both events, each a JSON **array** (guard the pwsh single-element-array serialization quirk: re-parse output, assert `hooks.Stop` is a list of len 1);
   - re-run is idempotent (no duplicate entry — command already present);
   - a pre-existing user `Notification` entry is **preserved** and ours appended.
4. **PSScriptAnalyzer** clean on `notify.ps1` + edited scripts (`Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1`).
5. `just docs-build` stays green (`--strict`).

On a real Windows box (the `windows-latest` CI is the true gate):
6. After apply: `apprise --config ~/.config/apprise/apprise.yaml --tag desktop --title Test --body Hello` pops a toast (proves pywin32/`windows://` works).
7. Trigger a Claude `Stop` (finish any turn) and a `Notification` (e.g. a permission prompt) → confirm a "Claude Code / Task finished" toast and an attention toast appear.

## Risks & notes

- **pwsh single-element array JSON** — the one behavior to verify (step 3);
  PS7 should keep nested `[object[]]` as arrays, but Claude requires `hooks.<event>`
  to be an array. If it collapses, write a `pitfalls/` doc + force-wrap.
- **pywin32 in a uv tool venv** — `--with pywin32` should suffice (apprise imports
  `win32*` directly; no `pywin32_postinstall` needed for toast use). If a real box
  proves otherwise, `pitfalls/` it. `uv:apprise` failure is non-fatal (Register-Failure).
- **`~/.local/bin` on PATH** — handled inside `notify.ps1` (hooks run `-NoProfile`).
- **No clean opt-out** (accepted tradeoff of piggybacking): removing the hook by
  hand gets re-added on next apply. A future `installApprise` toggle could add one.
