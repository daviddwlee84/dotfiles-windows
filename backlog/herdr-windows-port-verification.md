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
  `config.toml` to prevent dual writers. Herdr genuinely writes onboarding,
  in-app setting/key-reset changes, and `update.channel`. Current upstream
  does not write `[session]`, `[remote]`, or `[experimental]`; the merger keeps
  them as live/user-owned config. The unix repo's 2026-07-06 `create_` → `modify_`
  change was preventive while correcting key/CWD behavior: source and live were
  measured identical, not caught in an observed onboarding-clobber incident.
- `.chezmoitemplates/herdr/config.toml` — the managed body: `[theme]`, `[ui]`
  (+ `[ui.sidebar.agents]` with the `$review` token), `[terminal]`, `[keys]`
  rebinds, and the Windows-supported subset of the unix command bindings.
- Shared `_common.ps1` plus seven pwsh command helpers in `dot_config/herdr/`
  (`edit-config` / `run-command` / `new-tab-at-space-root` / `url-pick` /
  `path-pick` / `pane-copy` / `review-mark`).
- Three tv channels: `herdr-sesh`, `herdr-agent-panes`, `herdr-review`.
- herdr-plus quick-actions + one project template.
- 2026-08 alignment: `installHerdr` now also builds `dev` v0.1.0 for both Windows
  architectures, `prefix+d` launches its dashboard, and the six non-interactive
  copy helpers moved to `prefix+y`; only the PTY-dependent path picker keeps
  `prefix+p`. `prefix+C` and *Copy space: dir* share one root-dir derivation.
- 2026-08 config editing: `prefix+alt+e` opens a temporary pane that directly
  edits `HERDR_CONFIG_PATH` (or the default runtime config), validates that exact
  file, and reloads without invoking chezmoi. A same-directory metadata-aware
  backup supports atomic rollback; invalid candidates and reload-failure backups
  are retained according to the failure phase.

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
- **The rendered config is valid TOML** with all 13 active `[[keys.command]]`
  bindings present, including exactly one `prefix+alt+e` pane binding.
- **The runtime editor is isolated and recoverable on macOS.** Focused Pester
  uses only `TestDrive` plus editor/Herdr stubs and covers custom/default paths,
  same-directory backup order, direct-target validation, invalid-candidate
  rollback, metadata restoration, reload/cleanup retention, and injected backup/
  rollback failures. ACL and reparse-point assertions remain Windows-only.
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
- Parse + PSScriptAnalyzer clean on all eight pwsh files.

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
3. **How herdr spawns a `command` string on Windows.** **CONFIRMED (2026-07):**
   the Windows preview does **NOT** expand `$VAR` inside a `[[keys.command]]`
   string — a binding written `... "$HERDR_ACTIVE_PANE_ID"` hands the script the
   LITERAL text, which surfaced as `url-pick: failed to read pane
   $HERDR_ACTIVE_PANE_ID` (and the same on prefix+m / prefix+p / prefix+P/D/V/S /
   prefix+C — every helper that took a pane id). Fixed two ways: (a) stripped all
   `"$HERDR_ACTIVE_PANE_ID"` / `"$HERDR_ACTIVE_PANE_CWD"` args from the command
   strings so the scripts rely on the env vars herdr DOES inject; (b) hardened
   `Resolve-HerdrPane` / `Resolve-HerdrCwd` in `_common.ps1` to skip any
   unexpanded `$*` placeholder. `Resolve-HerdrCwd` already self-healed via
   `Test-Path`, which is why only pane-id bindings errored. Still open: whether
   herdr ever hands the string to `cmd.exe` (embedded double quotes) — untested,
   but the current bindings carry no inner quotes after the arg strip.
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
   the plugin is absent, so this is safe to leave. Note `Install-HerdrPlus`
   (`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`) needs **go** — it
   returns early with `herdr-plus: skipped — needs go to build on Windows` — so
   "the plugin is absent" is a live case, not a hypothetical. Every feature that
   ships a Quick Action must therefore also have a direct-key path; the pane
   translator (`prefix+t`, item 12) is the first one built that way on purpose.
12. **`prefix+t` pane translator.** `pane-translate.ps1` (2026-08-31). Confirm on
    a real box: (a) the `type = "pane"` command pane owns a usable PTY so the
    `--inline` viewer's `Read-Host` hold works; (b) `$env:HERDR_ACTIVE_PANE_ID`
    is injected into a command pane, so `Resolve-HerdrPane` picks the SOURCE pane
    and not the temporary command pane — **`url-pick.ps1` and `path-pick.ps1`
    already depend on this and it has never been checked**; if it resolves to the
    command pane, all three helpers need an explicit source-pane lookup, not just
    this one; (c) the Quick Action split path — `pane split` returning
    `.result.pane.pane_id`, the `process-info` readiness poll, and `pane run`
    accepting a quoted `pwsh -NoProfile -File …` string; (d) the new pane is
    unfocused (no `focus-pane.py` port here — reach it with `prefix+l`), so decide
    whether porting the focuser is worth it; (e) that `translate` resolves without
    an interactive profile (scoop shim on PATH), and that a stale
    `~\.local\bin\translate.exe` does not shadow it. The text pipeline itself
    is already covered off-Windows by `tests/Translate.Tests.ps1`, which asserts
    byte-parity of `Format-HerdrCapture` against the unix filter's fixtures.
13. **`prefix+d` dev dashboard.** `dev` v0.1.0 cross-compiles cleanly to PE32+
    console binaries for windows/amd64 and windows/arm64, but the actual ConPTY
    dashboard and Herdr runtime handoff still need a real Windows smoke test.
14. **`prefix+alt+e` direct runtime editor.** Confirm ConPTY delivers the Alt
    chord distinctly from built-in `prefix+e` / `prefix+E`; `$env:EDITOR` and nvim
    block until exit, and the Notepad fallback waits. Smoke with an isolated target:
    verify backup attributes/ACL match before editing, a rejected candidate is
    current-user-only while the old target is restored, and reload reaches the
    current server through the inherited socket. Also force reload failure once and
    confirm the valid edited target plus backup remain. No phase may invoke chezmoi.

## Next steps

Run through 1–14 on the first Windows host with herdr installed, then either fold
the corrections back into `.chezmoitemplates/herdr/config.toml` or record the
Windows-specific limitation here. If `[[keys.command]]` turns out to be
unsupported, the config's non-keymap half (`[theme]`, `[ui]`, `[terminal]`, the
`[keys]` rebinds) is still worth keeping — drop only the `[[keys.command]]`
array and the helper scripts.
