# Shift+Enter submits instead of inserting a newline in Claude Code (pwsh / Windows Terminal)

**Symptoms** (grep this section): Shift+Enter sends the prompt instead of adding a line break in the Claude Code TUI; Shift+Enter "does nothing" / behaves exactly like Enter; multiline prompts impossible in `claude` under PowerShell; works in WezTerm but not in Windows Terminal or the bare `pwsh.exe` console; same issue for Codex / other CSI-u TUI agents.
**First seen**: 2026-07
**Affects**: Claude Code (and other CSI-u TUI agents) run inside Windows Terminal or the classic console host on this repo's pwsh setup. WezTerm and Alacritty were already fine.
**Status**: fixed — `run_onchange_after_30_windows_terminal.ps1` now injects a `sendInput` action so WT emits `ESC[13;2u` for Shift+Enter. WezTerm (`dot_config/wezterm/wezterm.lua`) and Alacritty (`AppData/Roaming/alacritty/alacritty.toml.tmpl`) already sent it.

## Symptom

In `claude` running under PowerShell, pressing **Shift+Enter** submits the prompt
(same as Enter) instead of inserting a newline. There is no error — the terminal
simply can't tell Shift+Enter apart from Enter, so Claude Code receives a bare CR
and submits. Reproduces in **Windows Terminal** and the **plain `pwsh.exe`
console**; the same session works in WezTerm.

## Root cause

Claude Code maps Shift+Enter to `chat:newline`, but that only fires when the
terminal sends a **distinct escape sequence** for the chord — the CSI-u encoding
`ESC[13;2u` (Enter = keycode 13, Shift = modifier 2). A terminal that doesn't
encode modified Enter sends a bare `\r` for both Enter and Shift+Enter, so they're
byte-identical and Claude Code can't distinguish them.

The official docs list Windows Terminal as "works without setup", but that assumes
its extended/win32-input keys actually reach Claude Code, which isn't guaranteed on
every version/config. This repo hand-wires the CSI-u sequence per terminal instead
of relying on that:

- **WezTerm** and **Alacritty** already had the `Shift+Enter → ESC[13;2u` binding.
- **Windows Terminal** did **not** — its `run_onchange` merger only touched
  `profiles.defaults` / `defaultProfile` and set no `actions`.
- The **classic console host (conhost)** can't be configured to emit CSI-u at all.

## Workaround

The universal, terminal-independent newline that needs **no** setup:

- **`Ctrl+J`**, or type **`\`** then **Enter**. Works in every terminal.

To get Shift+Enter itself in Windows Terminal, add a `sendInput` action (this is
what the fixed merger does). By hand, in WT `settings.json`:

```jsonc
"actions": [
  { "keys": "shift+enter", "command": { "action": "sendInput", "input": "\u001b[13;2u" } }
]
```

Or `chezmoi apply` on the fixed repo — the merger `run_onchange` re-fires (its
content hash changed) and appends the binding non-destructively. **Restart the
terminal** afterward so WT reloads `settings.json`.

## Prevention

- **Wire CSI-u per terminal; don't assume "works without setup".** The load-bearing
  sequence is `Shift+Enter → ESC[13;2u`. Keep WezTerm / Alacritty / Windows
  Terminal in parity.
- **When authoring the WT `sendInput` value, keep the ESC raw.** Build it with
  `[char]27` (a real `0x1b`); `ConvertTo-Json` serializes that to `\u001b`, which is
  what WT wants. Hand-typing the escape tends to drop it (AGENTS.md invariant #3) —
  verify by re-parsing the written JSON.
- **`ConvertFrom-Json -AsHashtable` gotcha.** When de-duping existing WT actions,
  read an entry's `keys` **field** with `$entry['keys']` — `$entry.keys` returns the
  hashtable's own `.Keys` collection, not the JSON value, so the dedupe silently
  fails and you append a duplicate every apply.
- Use WezTerm or Windows Terminal for `claude`, not the bare console window.

## Related

- `.chezmoiscripts/run_onchange_after_30_windows_terminal.ps1` (the `actions` merge)
- `dot_config/wezterm/wezterm.lua` / `AppData/Roaming/alacritty/alacritty.toml.tmpl` (existing CSI-u bindings)
- `dot_config/powershell/profile.d/00_env.ps1` (`$env:EDITOR = 'nvim'` for the `Ctrl+G` external editor)
- `docs/claude-code-agents.md` → "Prompt editing: newline & external editor"
- Upstream: [Claude Code terminal config](https://code.claude.com/docs/en/terminal-config) · [keybindings](https://code.claude.com/docs/en/keybindings)
