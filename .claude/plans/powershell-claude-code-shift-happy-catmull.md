# Plan: Claude Code on Windows — Shift+Enter newline, winget install, Ctrl+G editor

## Context

Three user questions about running Claude Code in PowerShell on Windows, and the
dotfiles changes they imply:

1. **Shift+Enter doesn't insert a newline** in the Claude Code prompt.
2. **Is Windows still on npm** for Claude Code, or the native binary like mac/Linux?
3. **Does Ctrl+G open `$EDITOR` (nvim)** to compose the prompt, as on other platforms?

Verified against the official docs (`code.claude.com/docs/en/{terminal-config,keybindings,setup}`):

- **Newline** — the universal, terminal-independent newline is **`Ctrl+J`** (or `\`
  then Enter); both work in every terminal with no setup. `Shift+Enter` is *also*
  bound to `chat:newline`, but only fires when the terminal emits a distinct escape
  sequence for it (CSI-u / extended keys). Per the docs, WezTerm works without setup;
  **Alacritty needs `/terminal-setup`**; Windows Terminal is listed as "works without
  setup" but in practice only when win32-input/extended keys reach Claude Code.
- **Install** — Windows now has a native binary (`irm https://claude.ai/install.ps1 | iex`)
  and a **winget package `Anthropic.ClaudeCode`** (distinct from `Anthropic.Claude`,
  the desktop app). npm still works. This repo currently installs via npm.
- **External editor** — `chat:externalEditor` is bound by default to **`Ctrl+G`** (and
  the `Ctrl+X Ctrl+E` chord); needs `$EDITOR` set. **Already works** here: the repo
  sets `$env:EDITOR = 'nvim'` in `dot_config/powershell/profile.d/00_env.ps1`.

**User's terminals:** all four (Windows Terminal, WezTerm, Alacritty, plain pwsh/conhost).
**Installer choice:** winget (`Anthropic.ClaudeCode`) — fits the repo's declarative
scoop=CLI / winget=GUI model; upgrades via `just upgrade-winget`.

### What already works (no change)

- **WezTerm** (`dot_config/wezterm/wezterm.lua`) and **Alacritty**
  (`AppData/Roaming/alacritty/alacritty.toml.tmpl`) already send `Shift+Enter → ESC[13;2u`
  (CSI-u). After `chezmoi apply` + terminal restart, Shift+Enter inserts a newline there.
- **Ctrl+G → nvim** already works (`$EDITOR=nvim` set conditionally in `00_env.ps1`).
- **Plain pwsh/conhost** cannot emit CSI-u at all — `Ctrl+J` is the only newline there
  (documented, not fixed).

The real gap is **Windows Terminal**, whose merger sets no keybindings.

## Changes

### 1. Windows Terminal: add Shift+Enter (+ Ctrl+Enter) CSI-u binding — the core fix

File: `.chezmoiscripts/run_onchange_after_30_windows_terminal.ps1`

Extend the existing non-destructive merger (currently only touches
`profiles.defaults` + `defaultProfile`) to also ensure an `actions` entry mapping
`shift+enter` → `sendInput` of the CSI-u sequence, mirroring WezTerm/Alacritty:

```powershell
# After the profiles.defaults block, before ConvertTo-Json:
# Shift+Enter -> ESC[13;2u so TUI agents (Claude Code, Codex) read it as "newline"
# instead of "submit". Parity with the WezTerm/Alacritty CSI-u configs. Non-
# destructive: only append bindings whose `keys` aren't already present.
if (-not $s.ContainsKey('actions') -or $s.actions -isnot [System.Collections.IEnumerable]) { $s['actions'] = @() }
$want = @(
    @{ keys = 'shift+enter'; command = @{ action = 'sendInput'; input = "$([char]27)[13;2u" } }  # newline in agents
    @{ keys = 'ctrl+enter';  command = @{ action = 'sendInput'; input = "$([char]27)[13;5u" } }   # parity
)
$have = @($s.actions | ForEach-Object { $_['keys'] })   # NB: $_['keys'] not $_.keys (see gotcha)
$s['actions'] = @($s.actions) + @($want | Where-Object { $_.keys -notin $have })
```

Implementation gotchas (both must be honored):

- **`-AsHashtable` gotcha:** entries in `$s.actions` are `[hashtable]`, so an entry's
  `keys` JSON field must be read as **`$entry['keys']`** — `$entry.keys` returns the
  hashtable's own `.Keys` collection instead. (This is why `$have` uses `$_['keys']`.)
- **Preserve the raw ESC (invariant #3):** build the sequence with `[char]27` (real
  `0x1b`); `ConvertTo-Json` serializes it to `[13;2u`, which is what WT wants.
  Verify by re-parsing after write (see Verification).

The merge stays best-effort (`$ErrorActionPreference='Continue'`, existing backup to
`~/.dotfiles-backup/`), and being a `run_onchange`, editing the script re-fires it on
next apply.

### 2. Installer: move Claude Code from npm → winget

File: `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (the single source of
truth for installs). Inside the existing `{{ if .installCodingAgents }}` block:

- **Drop** `'@anthropic-ai/claude-code',` from the `Npm-InstallGlobal @(...)` list
  (keep `opencode-ai`, `@openai/codex`, `@github/copilot`).
- **Add** `Winget-Install 'Anthropic.ClaudeCode'` (helper already defined; tries user
  scope then machine scope; failures are collected, never fatal). Keep it under the
  same `installCodingAgents` gate so the toggle semantics are unchanged.

No new init prompt → **no CI-flag change** needed (invariant #1 not triggered).

### 3. Docs (bilingual — edit both language twins in the same commit)

- `docs/tools.md` + `docs/tools.zh-TW.md`: remove `@anthropic-ai/claude-code` from the
  "AI agents (npm)" line (~L111–117); add a **Claude Code | `Anthropic.ClaudeCode`** row
  to the winget table (near the `Anthropic.Claude` desktop row, ~L56).
- `docs/claude-code-agents.md` + `docs/claude-code-agents.zh-TW.md`: add a short new
  section (e.g. **"Prompt editing: newline & external editor"**) — distinct from the
  existing Agent View `Shift+Enter` dashboard row (L79). Cover: the per-terminal
  Shift+Enter table, `Ctrl+J` / `\`+Enter as the universal fallback, `Ctrl+G` →
  `$EDITOR` (nvim), and that WezTerm/Alacritty/WT are wired via repo config while
  plain conhost is `Ctrl+J`-only. (No `nav`/`nav_translations` change — editing
  existing pages, not adding new ones.)
- `docs/setup.md:78` already lists Claude Code without naming npm — leave as-is.

### 4. Pitfall doc (repo convention for non-obvious, hard-won fixes)

`pitfalls/shift-enter-submits-instead-of-newline-claude-code.md`, titled by symptom:

- **Symptom** (verbatim): Shift+Enter submits instead of inserting a newline in Claude
  Code under pwsh / Windows Terminal.
- **Root cause:** WT/conhost don't emit a distinct Shift+Enter sequence that reaches
  Claude Code; CC needs CSI-u `ESC[13;2u`. Docs say WT "works without setup" but that
  assumes win32-input/extended keys land — not guaranteed.
- **Workaround:** `Ctrl+J` (universal) / add the WT `sendInput` action (this change) /
  WezTerm+Alacritty already send CSI-u via repo config. Include the `$entry['keys']`
  `-AsHashtable` gotcha.
- **Prevention:** per-terminal CSI-u parity; test Shift+Enter after `chezmoi apply`.

### 5. TODO backlog entry (optional full parity — not this session)

Full CSI-u parity for Windows Terminal (`Ctrl+/` → `\x1f`, `Ctrl+0..9` → `ESC[<ascii>;5u`),
matching WezTerm/Alacritty. Add via `scripts/add-todo.sh --priority P3 --effort S
--title "Windows Terminal full CSI-u parity (Ctrl+/, Ctrl+digits)" --description "…"`,
then `scripts/todo-kanban.sh --validate-only TODO.md`.

## Verification

Off-Windows (this dev box) — the CI-parity checks:

1. **Render the packages tmpl** and confirm Claude Code moved: isolated
   `execute-template` of `run_onchange_after_10_packages.ps1.tmpl` (all prompts as in
   `CLAUDE.md`), then assert the output contains `Winget-Install 'Anthropic.ClaudeCode'`
   and **no** `@anthropic-ai/claude-code`.
2. **Parse + lint the WT merger:** `Invoke-ScriptAnalyzer -Path
   .chezmoiscripts/run_onchange_after_30_windows_terminal.ps1 -Settings
   ./PSScriptAnalyzerSettings.psd1` (Errors only).
3. **ESC-escape + merge dry-run (invariant #3):** throwaway pwsh that runs the merge
   logic against a sample `settings.json` (one with a pre-existing `actions` entry to
   prove non-destructive append + dedupe), then re-reads and asserts the `shift+enter`
   entry's `input[0] -eq [char]27` and the serialized JSON contains `[13;2u`.
4. **Docs build:** `just docs-build` stays green (`mkdocs build --strict`).
5. **Pester:** `Invoke-Pester -Path ./tests` (add/extend a WT-merger test if one exists).

On the real Windows box (`chezmoi apply`, the authoritative check):

6. Windows Terminal → run `claude`, press **Shift+Enter** → newline (not submit);
   **Ctrl+J** → newline; **Ctrl+G** → nvim opens with the prompt.
7. `winget list --id Anthropic.ClaudeCode` present; `claude --version` runs.
8. Sanity-check WezTerm + Alacritty still newline on Shift+Enter (unchanged).

## Invariants touched (per CLAUDE.md)

- **#2** never abort the apply — the WT merge extension stays best-effort.
- **#3** preserve raw escapes — `[char]27` + re-parse verification.
- **Cross-file mirror** — `docs/tools.md` + `.zh-TW`, `docs/claude-code-agents.md` + `.zh-TW`.
- **#1 not triggered** — no new/renamed init prompt, so no `windows.yml` flag change.
