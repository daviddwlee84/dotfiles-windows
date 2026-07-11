# Fix Ctrl+R fzf bindings in both pwsh (PSFzf) and cmd.exe (Clink)

## Context

After the latest bootstrap the user reports Ctrl+R still shows the built-in
`bck-i-search:` reverse search instead of an fzf pane — in **both** PowerShell 7
and cmd.exe. Starship works in cmd, so clink autorun is fine.

Everything is *installed* correctly (the log shows no failures): `fzf` +
`PSFzf` for pwsh, and `clink` + downloaded `fzf.lua`/`zoxide.lua` for cmd. The
problem is **two independent ordering bugs** that leave the Ctrl+R key binding
un-applied. Symptom is identical in both shells (`bck-i-search:` = the default
readline/PSReadLine incremental search) because in each case the fzf binding is
either clobbered or never persisted, so the shell falls back to its default.

### Bug 1 — pwsh: `Set-PSReadLineOption -EditMode` clobbers PSFzf's chord

Profile fragments dot-source in numeric order (`10_tools` → `90_psreadline`).

- `dot_config/powershell/profile.d/10_tools.ps1:59` binds the PSFzf chord
  (`Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'`).
- `dot_config/powershell/profile.d/90_psreadline.ps1.tmpl:19/23` runs **later**
  and calls `Set-PSReadLineOption -EditMode Vi|Windows`, which **resets
  PSReadLine's key-handler tables to that mode's defaults** — reverting Ctrl+r
  to the built-in `ReverseSearchHistory` (`bck-i-search:`) and wiping PSFzf.

This fragment also clobbers *its own* `UpArrow`/`DownArrow` prefix-search
handlers (`90_psreadline.ps1.tmpl:14-15`), because they too are set *before* the
`-EditMode` line. This is the canonical PSFzf gotcha: chords must be applied
**after** `-EditMode`.

### Bug 2 — cmd: `clink set` runs before `fzf.lua` exists

In `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (the `{{ if .installClink }}` block):

- Line 371 runs `clink set fzf.default_bindings true` **before** the download
  loop at lines 378-382 fetches `fzf.lua` into `%LOCALAPPDATA%\clink`.
- `fzf.default_bindings` is a setting **defined inside `fzf.lua`** (upstream:
  `maybe_add(rl.setbinding and 'fzf.default_bindings', false, …)`, default
  `false`; keys are bound only `if settings.get('fzf.default_bindings')`).
- Per Clink docs, *"scripts are also loaded every time `clink set` is run"* — so
  at line 371 Clink reloads the profile dir, `fzf.lua` isn't there yet, the
  setting is unknown, and the value is **silently not persisted** (`*> $null`
  swallows the error, no `Register-Failure`).
- At cmd runtime `fzf.lua` loads (it downloaded fine), re-registers the setting
  at its default `false`, and never binds Ctrl-R/Ctrl-T/Alt-C.

## Fix

### 1. `dot_config/powershell/profile.d/90_psreadline.ps1.tmpl`

Reorder so `-EditMode` is set **first**, then the history/prediction options,
then the key handlers, then re-apply the PSFzf chord last:

- Move the templated `Set-PSReadLineOption -EditMode Vi|Windows` block to the
  **top** of the `if (Get-Module -Name PSReadLine)` body (right after import).
- Keep the `PredictionSource`/`ViewStyle`/`HistorySearch*` options and the
  `UpArrow`/`DownArrow` handlers after it (they now survive the reset — a bonus
  fix for prefix history search).
- Append, at the **end** of the body:
  ```powershell
  # PSFzf (imported in 10_tools) binds Ctrl+t files / Ctrl+r history. Re-apply
  # here: the -EditMode reset above wipes those bindings.
  if (Get-Module -Name PSFzf) {
      Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
  }
  ```

### 2. `dot_config/powershell/profile.d/10_tools.ps1`

Remove the now-redundant `Set-PsFzfOption` chord call (lines 58-60); keep the
`Import-Module PSFzf` and the `FZF_DEFAULT_OPTS`/`FZF_DEFAULT_COMMAND` env vars.
Leave a one-line comment noting the chord is bound in `90_psreadline` after
`-EditMode`. (Tool import stays in `10_tools`; all PSReadLine key-table
mutations live in `90_psreadline`, in the correct order.)

### 3. `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`

Move `clink set fzf.default_bindings true` (line 371) to **after** the
`foreach ($name in $clinkPlugins.Keys)` download loop (after line 382, still
inside the `if (Have clink)` block), with a comment explaining the ordering:
```powershell
# fzf.default_bindings is defined INSIDE fzf.lua; `clink set` reloads the
# profile scripts first, so this must run AFTER fzf.lua is downloaded above,
# else the setting is unknown and the value is silently not persisted.
clink set fzf.default_bindings true *> $null    # Ctrl-R history / Ctrl-T files / Alt-C dir
```
Editing this `run_onchange` changes its content hash, so it re-runs on the next
`chezmoi apply` and actually re-writes the setting on the user's machine.

### 4. Record the pitfall (repo convention)

Per `CLAUDE.md`, add a symptom-titled `pitfalls/ctrl-r-shows-bck-i-search-not-fzf.md`
covering both shells (verbatim symptom `bck-i-search:`, the two root causes, the
ordering fix, and the prevention rule "apply key bindings after `-EditMode` /
after `fzf.lua` is present"). Title by symptom for grep-ability. No `TODO.md`,
docs-table, or CI-flag mirrors are needed — these are bug fixes, not new
prompts/tools.

## Notes / out of scope

- Latent conflict: `10_tools.ps1:46` also runs `atuin init powershell`, which
  would bind Ctrl+R if atuin were installed. It isn't here (else the user would
  see atuin's TUI, not `bck-i-search:`). With this fix PSFzf owns Ctrl+R, matching
  the profile's stated intent. Not changing atuin behavior in this pass.

## Verification

Dev box (macOS — cannot run the Windows scripts; render + parse per CLAUDE.md):

1. Render both templates and syntax-check with the local pwsh:
   ```bash
   TMPD=$(mktemp -d); mkdir -p "$TMPD/home"
   chezmoi init --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
     --destination="$TMPD/home" --no-tty <all prompts…>     # include --promptBool 'Install Clink … =true'
   chezmoi execute-template --config="$TMPD/c.toml" --source="$PWD" \
     < dot_config/powershell/profile.d/90_psreadline.ps1.tmpl > /tmp/90.ps1
   chezmoi execute-template --config="$TMPD/c.toml" --source="$PWD" \
     < .chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl > /tmp/pkg.ps1
   pwsh -NoProfile -c "\$null=[ScriptBlock]::Create((Get-Content -Raw /tmp/90.ps1)); \$null=[ScriptBlock]::Create((Get-Content -Raw /tmp/pkg.ps1)); 'parse-ok'"
   ```
2. `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"` (must stay Error-free).
3. Isolated `chezmoi apply … --exclude=scripts` (from CLAUDE.md) to confirm the
   fragments deploy without error.

Windows (real gate — user machine / CI):

- **pwsh**: open a new pwsh, then
  `Get-PSReadLineKeyHandler -Chord 'Ctrl+r'` — Function should be PSFzf's handler,
  **not** `ReverseSearchHistory`. Press Ctrl+R → fzf history pane appears.
- **cmd**: `chezmoi apply` (re-runs the run_onchange), open a **new** cmd, then
  `clink set fzf.default_bindings` should print `true`; `clink info` should list
  `fzf.lua` under loaded scripts; Ctrl+R → fzf history pane.
