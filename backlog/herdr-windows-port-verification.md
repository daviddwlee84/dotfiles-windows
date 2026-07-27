# herdr Windows port — what still needs verifying on a real Windows box

**Status**: P2 — shipped, unverified on Windows
**Effort**: S (verification pass) / M (if the popup findings force a redesign)
**Related**: `.chezmoitemplates/herdr/config.toml` · `dot_config/herdr/` · `AppData/Roaming/television/cable/herdr-*.toml` · `dot_config/powershell/profile.d/25_herdr.ps1` · parent repo's `docs/tools/herdr.md`

## Context

2026-07-27. Until now this repo carried a **16-line** herdr config (update
channel + `default_shell` + `host_cursor`) and a pwsh port of the workspace
helpers (`hvibe`/`hcode`/`hhere`/`hroot`/`hmark`, 2026-07-12). The parent
(unix) repo's herdr setup had grown to a **310-line** managed config with 20
`[[keys.command]]` bindings, six helper scripts, three tv channels and a
herdr-plus plugin config — none of which had been ported.

This backlog entry records what was ported, what was deliberately dropped, and
— the important part — **which behaviours could not be tested from macOS** and
must be confirmed the first time herdr runs on a Windows host.

## What shipped

- `dot_config/herdr/modify_config.toml.ps1.tmpl` — replaces the plain managed
  `config.toml`. A plain managed file clobbers herdr's runtime writeback
  (onboarding flag, `[session]`, `[remote]`, `[update]` bookkeeping) on every
  `chezmoi apply`; the unix repo hit that and moved `create_` → `modify_` on
  2026-07-06, five days *before* this repo's plain file was added.
- `.chezmoitemplates/herdr/config.toml` — the managed body: `[theme]`, `[ui]`
  (+ `[ui.sidebar.agents]` with the `$review` token), `[terminal]`, `[keys]`
  rebinds, and **17** of the unix side's 20 command bindings.
- Six pwsh helpers in `dot_config/herdr/` (`_common.ps1` +
  `run-command` / `new-tab-at-space-root` / `url-pick` / `path-pick` /
  `pane-copy` / `review-mark`).
- Three tv channels: `herdr-sesh`, `herdr-agent-panes`, `herdr-review`.
- herdr-plus quick-actions + one project template.

## Deliberately NOT ported

| unix binding | why |
|---|---|
| `prefix+N` → `nvtop` | nvtop is Linux-only. No equivalent is bound; `prefix+M` (btop) covers general monitoring. If a Windows GPU TUI is later added to the scoop set, bind it here. |
| `prefix+U` → `tv tools` | there is no `tools` channel in this repo's `AppData/Roaming/television/cable/`. Either port that channel from the parent repo or drop the binding permanently. |
| `prefix+f` → `tv fleet-hosts` | `fleet` is a mac/linux-only tool in the parent repo; nothing to point at here. |

## What was verified, and how

Everything below was exercised from macOS with chezmoi + pwsh 7.4 + uv:

- **The overlay merges correctly.** Isolated apply against a live file holding
  `onboarding_complete`, `[session]`, `[update] channel="stable"` and an in-app
  `[theme]` override: runtime keys preserved, `update.channel` forced back to
  `preview`, the theme override re-asserted from the template. Applying twice is
  a fixpoint (byte-identical).
- **The rendered config is valid TOML** with all 17 bindings present.
- **URL extraction is byte-identical to the unix pipeline.** The six
  `grep -oE`/`sed` passes were rewritten as .NET regex and diffed against the
  original sh implementation on a sample covering all six rewrite rules
  (http/ftp/file, `www.`, IPv4:port, `git@`, quoted `owner/repo`, npm import).
- **Path extraction is byte-identical** on unix-style input, and additionally
  captures Windows forms the unix regex cannot match (`C:\src\x`, `C:/src/x`,
  and quoted `"C:\Program Files\x"`). Using one combined alternation rather than
  separate passes matters: separate passes re-fire the bare-filename branch
  *inside* an already-matched path and emit `main.rs` next to `src/main.rs`.
- **All three tv channel source commands** produce correct TSV against a stub
  `herdr` (including the `foreground_cwd` → `cwd` fallback and the
  review-token filter).
- **The `installHerdr` gate** deploys nothing when the toggle is off.
- Parse + PSScriptAnalyzer clean on all seven pwsh files.

## What CANNOT be verified off-Windows — check these first

1. **Does the Windows preview build support `[[keys.command]]` at all?** The
   whole keymap assumes `type = "pane"` / `type = "popup"` / `type =
   "plugin_action"` behave as documented. `herdr server reload-config` should
   report empty diagnostics — if it rejects a key, that is the first signal.
2. **`type = "popup"` (herdr >= 0.7.4)** is used for `prefix+E` and
   ``prefix+` ``. **CONFIRMED unsupported** on the Windows preview
   `0.7.5-preview.2026-07-21` (2026-07): the parser rejects it —
   `invalid keybinding config: unknown variant `popup`, expected one of `shell`,
   `pane`, `plugin_action` ... keeping current` — and drops the binding. Both were
   **disabled** (commented out) in `.chezmoitemplates/herdr/config.toml` rather
   than revived as tiled `pane`s, per user preference (dead is acceptable until a
   Windows preview ships `popup`). Note: `type = "shell"` is NOT a substitute — it
   runs detached in the background. Restore path documented inline in the config.
3. **How herdr spawns a `command` string on Windows.** The config passes
   `pwsh -NoProfile -File "<abs path>" "$HERDR_ACTIVE_PANE_ID"`. Two unknowns:
   whether herdr expands `$HERDR_ACTIVE_PANE_ID` in the string (it does on
   unix), and which shell — if any — splits the arguments. Paths are baked
   absolute at render time *precisely because* `pwsh -File` does not expand `~`
   (verified), but if herdr hands the string to `cmd.exe` the embedded double
   quotes may need rework.
4. **`prefix+ctrl+1..9` / `prefix+alt+1..9`.** The unix config uses ctrl/alt
   because under the kitty keyboard protocol `shift+1` still carries the
   printable `!`. ConPTY may behave differently — if ctrl+digit does not reach
   herdr, try shift.
5. **`Set-Clipboard` from inside a herdr command pane.** It works in a normal
   pwsh session; a pane spawned by herdr may not have the clipboard access a
   desktop session does. `_common.ps1` falls back to `clip.exe`.
6. **PSReadLine history for `prefix+E`.** `run-command.ps1` asks
   `Get-PSReadLineOption` first, then falls back to
   `%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt`.
   Under `-NoProfile` PSReadLine is usually not loaded, so the fallback path is
   the one that will actually be used — confirm it exists on the host.
7. **`herdr pane report-metadata … --token`** (review-mark) needs herdr
   **>= 0.7.4**. On an older build it fails with `unknown --custom-status`.
   The `$review` token in `[ui.sidebar.agents] rows` is what makes the flag
   visible at all — a token with no row entry silently renders nowhere.
8. **Unquoted Windows paths containing spaces** (`C:\Users\Da-Wei Lee\…`) are
   still split by `path-pick.ps1` unless they appear quoted in the pane. This is
   inherent to path extraction without a delimiter — extrakto and the unix
   original have the same limitation. If it bites, the fix worth trying is
   extending a drive-path candidate word-by-word while the result still exists
   on disk.
9. **herdr-plus on Windows.** `prefix+O` / `prefix+y` and the quick-actions are
   untested; the plugin may not have a Windows build. The bindings no-op when
   the plugin is absent, so this is safe to leave.

## Next steps

Run through 1–9 on the first Windows host with herdr installed, then either fold
the corrections back into `.chezmoitemplates/herdr/config.toml` or record the
Windows-specific limitation here. If `[[keys.command]]` turns out to be
unsupported, the config's non-keymap half (`[theme]`, `[ui]`, `[terminal]`, the
`[keys]` rebinds) is still worth keeping — drop only the `[[keys.command]]`
array and the helper scripts.
