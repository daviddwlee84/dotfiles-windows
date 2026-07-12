# Plan: deploy claude-hud (+ safe general Claude settings) via a Windows settings merger

## Context

The parent macOS/Linux dotfiles repo (`~/.local/share/chezmoi/dot_claude/modify_settings.json`)
hook-aware-merges an overlay into `~/.claude/settings.json` that enables **claude-hud**
(the notch/statusline HUD), the `pyright-lsp` plugin, `permissions.defaultMode=auto`,
`skipDangerousModePermissionPrompt`, plus macOS/Linux-only notify.sh + workmux hooks.

This **Windows** repo currently has **no** `~/.claude/settings.json` handling at all —
`dot_claude/` holds only skills. The user wants the same claude-hud experience (plus the
cross-platform-safe general settings) to deploy on Windows.

We cannot reuse the parent's mechanism verbatim:
- A static `dot_claude/settings.json` would make chezmoi **overwrite** Claude Code's own
  runtime-managed settings on every apply (clobbering the user's live plugins/permissions).
- `modify_settings.json` (sh + jq) is the parent's answer, but **invariant #5** says
  `modify_` interpreter selection is unreliable on Windows — this repo uses a
  `run_onchange` **pwsh merger** for exactly this shape (see the editor-overlay script).
- The parent's `statusLine` is a `bash -c '…'` one-liner; it won't run under pwsh. claude-hud's
  own setup command ships an explicit **Windows + PowerShell** statusLine variant, which is
  what we port.

Outcome: on a Windows box with `installCodingAgents` enabled, `chezmoi apply` additively
merges the claude-hud overlay into `~/.claude/settings.json`, preserving everything Claude
Code / the user already wrote there. The HUD appears after a Claude Code restart.

## Approach (mirror the `editors/` overlay idiom)

Two new files + three small edits. Gate everything on the **existing** `installCodingAgents`
toggle → **no new init prompt**, so invariant #1 (CI flags) and the skill "What's enabled"
block are untouched.

### 1. New overlay source — `claude/settings-overlay.json` (chezmoi-ignored)

Mirrors `editors/vscode-overlay.json`. Contents (the safe subset the user chose — **no**
notify.sh/workmux hooks, which are macOS/Linux-only):

```jsonc
{
  "enabledPlugins": {
    "claude-hud@claude-hud": true,
    "pyright-lsp@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "claude-hud": { "source": { "source": "github", "repo": "jarrodwatts/claude-hud" } }
  },
  "skipDangerousModePermissionPrompt": true,
  "permissions": { "defaultMode": "auto" },
  "statusLine": { "type": "command", "command": "<pwsh statusLine, see below>" }
}
```

`pyright-lsp@claude-plugins-official` uses Claude Code's built-in official marketplace, so it
needs **no** `extraKnownMarketplaces` entry (matches the parent).

**statusLine command** — the Windows-pwsh port of claude-hud's setup output, with dynamic
bun→node detection (so it survives runtime changes, like the parent's bash version rather
than the skill's hardcoded `{RUNTIME_PATH}`):

```
pwsh -NoProfile -Command "& { $d = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }; $p = (Get-ChildItem (Join-Path $d 'plugins\cache\claude-hud\claude-hud') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(\.\d+)+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).FullName; if (-not $p) { return }; $rt = Get-Command bun -ErrorAction SilentlyContinue; if ($rt) { & $rt.Source '--env-file' 'NUL' (Join-Path $p 'src\index.ts'); return }; $rt = Get-Command node -ErrorAction SilentlyContinue; if ($rt) { & $rt.Source (Join-Path $p 'dist\index.js') } }"
```

- `--env-file NUL` for bun mirrors the parent's `--env-file /dev/null` (don't auto-load a
  project `.env`); `NUL` is the Windows null device.
- Self-no-ops (`return`, empty output) if the plugin isn't installed yet or no runtime is
  found — so it's safe even before the plugin's first marketplace install.
- **Invariant #3**: this string carries backslashes + nested quotes. At implementation time,
  generate `settings-overlay.json` with a throwaway Python script and re-parse with
  `json.load` + print `data["statusLine"]["command"]` to confirm the escapes round-trip —
  do **not** hand-type the JSON escaping.

### 2. New merger — `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`

Modeled on `run_onchange_after_20_editor_overlays.ps1.tmpl`. Numbered 25 → after editor
overlays (20), before Windows Terminal (30).

- `#Requires -Version 7`, `$ErrorActionPreference = 'Continue'` (invariant #2 — never abort apply).
- Wrap the body in `{{ if .installCodingAgents -}} … {{ end -}}` (backup-script pattern) so it
  no-ops when Claude Code isn't installed.
- Embed the overlay at render time: `$overlayJson = @'` + `{{ include "claude/settings-overlay.json" }}` + `'@` (self-contained; re-fires when the overlay changes — same trick as the editor script).
- **Recursive deep-merge** (not the editor script's shallow top-level replace): add a
  `Merge-Hashtable` helper so that live-only nested keys are preserved — e.g. the user's
  `permissions.allow`/`deny` arrays and other `enabledPlugins` survive; overlay leaves win.
  Read the live file with `ConvertFrom-Json -AsHashtable` (best-effort JSONC strip like the
  editor script), merge, write back with `ConvertTo-Json -Depth 12 ... -Encoding utf8`.
- Target: `Join-Path $HOME '.claude/settings.json'` (respect `$env:CLAUDE_CONFIG_DIR` if set,
  matching the statusLine + the skill). Create the dir if missing.
- No hook-array merge needed — the chosen overlay has no `hooks` key, so a plain recursive
  object merge can't clobber any hooks Claude Code/other tools wrote.

### 3. `.chezmoiignore` — ignore the overlay source

Add `claude` + `claude/**` to the "package manifests + editor sources are read by
run_onchange scripts, not deployed directly" block (next to `editors` / `editors/**`).
Without this, chezmoi would try to deploy `claude/settings-overlay.json` into `$HOME`.

### 4. `run_once_before_01_backup.ps1.tmpl` — back up the file we now mutate

Add `(Join-Path $HOME '.claude/settings.json')` to the `$targets` array so the pre-apply
snapshot captures it (consistent with backing up the editor settings we merge into).

### 5. Docs mirror — `docs/claude-code-agents.md` + `docs/claude-code-agents.zh-TW.md`

Add a short "Statusline HUD (claude-hud)" section to **both** language twins (docs come in
mirrored pairs): what it is, that it's gated on `installCodingAgents`, that bun/node (scoop
baseline) backs it, and that a Claude Code restart is needed. No new nav page → no `mkdocs.yml`
nav/`nav_translations` churn. `just docs-build` must stay green (`--strict`).

## Files

| Action | Path |
|--------|------|
| new | `claude/settings-overlay.json` (Python-generated, chezmoi-ignored) |
| new | `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl` |
| edit | `.chezmoiignore` (+ `claude`, `claude/**`) |
| edit | `.chezmoiscripts/run_once_before_01_backup.ps1.tmpl` (+ `.claude/settings.json` target) |
| edit | `docs/claude-code-agents.md` + `docs/claude-code-agents.zh-TW.md` |

Reference patterns reused: `.chezmoiscripts/run_onchange_after_20_editor_overlays.ps1.tmpl`
(embed-overlay + merge), `run_once_before_01_backup.ps1.tmpl` (`{{ if }}` gate + targets),
`editors/vscode-overlay.json` (overlay-source layout).

## Verification (off-Windows, per CLAUDE.md)

1. **JSON validity + escape round-trip**: `python -c "import json; d=json.load(open('claude/settings-overlay.json')); print(d['statusLine']['command'])"` — confirm the pwsh command prints with correct `\`/quotes.
2. **Lint**: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path .chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl -Settings ./PSScriptAnalyzerSettings.psd1"` (needs local pwsh; else rely on CI).
3. **Template render + merge behaviour** via the isolated-apply idiom (temp dir; all CLAUDE.md prompt strings; `--exclude=scripts` for apply, then render the script explicitly):
   - `chezmoi execute-template --config="$TMPD/c.toml" --source="$PWD" < .chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl > r.ps1` with `installCodingAgents=true` → body present; with `=false` → body gated out.
   - Parse `r.ps1` with `pwsh -NoProfile -c '[ScriptBlock]::Create((Get-Content -Raw r.ps1)) | Out-Null'` (syntax check).
   - If a local pwsh exists: dot-source the merger logic against a fixture `settings.json` containing a pre-existing `permissions.allow` array + a third-party plugin, and assert both survive while the overlay keys are added (recursive-merge correctness).
4. **Docs**: `just docs-build` stays green.
5. **Real gate**: `windows-latest` CI (`.github/workflows/windows.yml`) — PSScriptAnalyzer, non-interactive init/apply, render+parse of every `.ps1.tmpl`, Pester.
6. **On a real Windows box (manual)**: `chezmoi apply`; restart Claude Code; HUD line appears below the prompt; `~/.claude/settings.json` shows the overlay keys merged in with prior settings intact.

## Out of scope (call out, don't build)

- macOS/Linux-only hooks (notify.sh, workmux) — not applicable on Windows.
- New init prompt / gating toggle — reuse `installCodingAgents`.
- Porting the hook-aware **additive array** merge from the parent's jq script — unnecessary
  because the chosen overlay has no `hooks` key. If hooks are added to the overlay later,
  revisit with an additive `.hooks[].command` merge (record as a `TODO.md`/backlog item then).
