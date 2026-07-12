# herdr workspace helpers for PowerShell (port of `24_herdr.sh`)

## Context

The herdr **install + config** work is already merged (opt-in `installHerdr`
toggle, `Install-Herdr`, PATH/`HERDR_CONFIG_PATH` in `00_env.ps1`,
`dot_config/herdr/config.toml`). The old plan explicitly left the *shell-helper*
layer out of scope. This change fills that gap: PowerShell analogs of the POSIX
repo's `dot_config/shell/24_herdr.sh` workspace helpers, so the user gets the
same `hvibe`/`hcode`/`hhere`/`hroot`/`hmark`/`hunmark` muscle-memory on Windows.

herdr's CLI is fully scriptable and **prints JSON** ("Most commands print JSON
responses" — herdr.dev/docs/cli-reference); every flag the POSIX script relies on
(`--no-focus`, `--ratio`, `--cwd`, `--label`, `--workspace`, `--direction
right|down`, `--pane`) exists on the current CLI, plus a cleaner `HERDR_SESSION`
env var the POSIX file predates. So a faithful port is feasible — it just needs
PowerShell-native idioms instead of the POSIX/tmux ones.

**Untestable-here caveat (important):** herdr installs via `irm|iex` and is
opt-in (`installHerdr=false` in CI), and this checkout is macOS. So neither this
box nor `windows-latest` CI can exercise these functions — CI only proves the
fragment *parses*. Real behavior is validated by the user on their Windows box
(manual checklist below). The fragment self-guards on `Get-Command herdr`, so it
is a clean no-op everywhere herdr is absent (same pattern as `35_yazi.ps1`).

Scope confirmed with the user: **full port, all 6 commands.**

## What ships

One new self-guarding fragment **`dot_config/powershell/profile.d/25_herdr.ps1`**
(plain `.ps1`, no templating/`.chezmoiignore` gating — runtime-guarded like
`35_yazi.ps1`/`40_copilot.ps1`; sorts after `20_aliases`, before `28_tldr`).
Opens with `if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) { return }`.

### Private helpers (port of the shared `_sesh_*` + `_herdr_*` helpers)

| Helper (pwsh) | Ports | Notes |
|---|---|---|
| git-root | `_sesh_git_root` | `git rev-parse --show-toplevel 2>$null`; empty outside a repo (callers handle fallback). |
| sanitize | `_sesh_sanitize` | `$s -replace '[.:\s]', '-'` (keeps `/`). |
| wrap-agent | `_sesh_wrap_agent` | `never`→raw (`claude` if empty); `auto`+known provider (`claude/codex/cursor/droid/gemini`)→`specstory run <a>`; else raw. **Windows guard:** if `specstory` is absent (it is — no Win CLI), always return raw. Future-proof if they later `just specstory-build`. |
| on-exit-wrap | `_sesh_on_exit_wrap` | **rewritten for pwsh** (see below). |
| ws-by-label | `_herdr_ws_by_label` | `herdr workspace list 2>$null \| ConvertFrom-Json`; `.result.workspaces \| ? label -eq $l \| select -First 1 -Expand workspace_id`. |
| tool-tab | `_herdr_tool_tab` | `herdr tab create --workspace … --cwd … --label … --no-focus` → `.result.root_pane.pane_id` → `herdr pane run`. |
| session-target | `_herdr_session_target` | **simplified**: validate explicit `-Session` via `herdr session list --json`; select it by setting `$env:HERDR_SESSION` for child calls (restored in `finally`). No `HERDR_SOCKET_PATH` juggling. |
| attach-if-outside | `_herdr_attach_if_outside` | `$env:HERDR_ENV` set → return; else `herdr` (default) or `herdr session attach <name>`. |

### On-exit wrapper — the one non-mechanical port

POSIX emits a **bash** snippet (`trap '' INT; …; exec $SHELL -l`). The pane shell
here is **pwsh** (`config.toml` `default_shell = "pwsh"`), so the wrapper is a
pwsh script. To avoid nested-quote breakage when passing a multi-statement
command through `herdr pane run`, encode it: build the wrapper string, then emit
**`pwsh -NoLogo [-NoExit] -EncodedCommand <base64>`** (base64 of UTF-16LE — no
spaces/quotes to escape). `try/finally` is the `trap '' INT` analog.

- **shell** (default): `pwsh -NoLogo -NoExit -EncodedCommand <b64>` where the
  decoded script is `try { <inner> } finally { Write-Host "<re-run hint>" -ForegroundColor Yellow }`. `-NoExit` drops to an interactive prompt after (pane stays alive).
- **restart**: `pwsh -NoLogo -EncodedCommand <b64>` of `while ($true) { <inner>; Write-Host '…respawning in 1s…' -ForegroundColor Yellow; Start-Sleep 1 }`.
- **kill**: no wrapper — `herdr pane run $pane $inner` raw (pane closes on exit).

`<inner>` is a simple command line (`claude`, `specstory run codex`, `nvim`,
`lazygit`, `btop`) placed as a bare pwsh statement — no `Invoke-Expression`.

### User-facing functions + aliases

`herdr-vibe`/`herdr-code`/`herdr-here`/`herdr-root`/`herdr-mark`/`herdr-unmark`,
aliased `hvibe`/`hcode`/`hhere`/`hroot`/`hmark`/`hunmark` via `Set-Alias`. Faithful
flag surface (`-Path`, `-Agents`, `-Session`, `--on-exit`, `--no-specstory`,
`--no-attach`, `--tab-per-agent`, `-h`), idempotent per workspace label, git-repo
required for vibe/code. Windows adaptations:

- **hvibe** even-column split ratios: `1/($nTotal-$m+1)`, formatted with
  **`InvariantCulture`** (`.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture)`) so a zh-* / comma-decimal locale never emits `0,5000` to `--ratio`.
- **hcode** monitor tab: `btop` if present, else a small pwsh
  `Get-Process | Sort CPU` loop (no `htop`/`top` on Windows).
- Agents default to `claude`; fail-fast if a named agent CLI isn't on PATH
  (available on Windows: `claude`, `codex`, `opencode`).
- **hmark/hunmark**: *inlined*, not a separate script port — default pane
  `$env:HERDR_PANE_ID`; set = `herdr pane report-metadata $pane --source review --custom-status '⭐ REVIEW'`, clear = same with `--clear-custom-status`.

### Docs + skill (same commit, keeps `just docs-build --strict` green)

- New concise **"herdr workspace helpers"** subsection in `docs/shell.md` +
  its **`docs/shell.zh-TW.md`** twin (command table; no new nav entries).
- `.chezmoitemplates/dotfiles-windows-skill.md`: one line noting the
  `hvibe/hcode/hhere/hroot/hmark` commands exist (gated on herdr).

## Files to change

| # | File | Change |
|---|---|---|
| 1 | `dot_config/powershell/profile.d/25_herdr.ps1` | **new** — the whole port (helpers + 6 funcs + aliases) |
| 2 | `docs/shell.md` + `docs/shell.zh-TW.md` | new "herdr workspace helpers" section (bilingual) |
| 3 | `.chezmoitemplates/dotfiles-windows-skill.md` | one-line mention of the herdr commands |

## Verification

Off-Windows (structural only — herdr can't run here; the Windows box is the real
behavioral gate):

1. **Parses** — `pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('dot_config/powershell/profile.d/25_herdr.ps1',[ref]$null,[ref]$e); if($e){$e;exit 1}"`.
2. **Lint** — `Invoke-ScriptAnalyzer -Path dot_config/powershell/profile.d/25_herdr.ps1 -Settings ./PSScriptAnalyzerSettings.psd1` (Errors only).
3. **Base64 round-trip** — sanity-check the encode helper: decode a sample
   `-EncodedCommand` payload back to the expected wrapper script.
4. **Ratio locale** — confirm the InvariantCulture format emits `0.5000` (a `.`)
   under a comma-decimal culture (`[Globalization.CultureInfo]::new('de-DE')`).
5. **Deploys** — isolated `chezmoi apply --exclude=scripts` into a temp
   destination writes `.config/powershell/profile.d/25_herdr.ps1`.
6. **Docs** — `just docs-build` stays green.

On the user's Windows box (post-merge, herdr installed): `hhere`, then `hcode`,
then `hvibe 2 claude` / `hvibe --agents claude,codex` — confirm workspace/tabs/
panes appear and attach works; run an agent to exit and confirm shell/kill/
restart on-exit behavior; `hmark`/`hunmark` toggle the ⭐ status on a pane.

## Out of scope (add to `TODO.md`/`backlog/` if wanted)

- `hmark` **toggle** action + a reusable `review-mark.ps1` (only needed if a
  `tv herdr-review` inbox channel or a `prefix+m` herdr keybind is later added —
  neither exists in this repo yet).
- A `herdr init powershell` cwd/shell-integration hook (still nothing to cache).
