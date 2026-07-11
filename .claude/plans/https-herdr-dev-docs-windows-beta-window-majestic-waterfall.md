# Add herdr (native Windows terminal multiplexer, preview beta)

## Context

`docs/rationale.md:64-83` currently asserts there is **no native Windows terminal
multiplexer** — tmux/zellij are Unix-only, so WezTerm is used as the closest
answer. [herdr](https://herdr.dev) has since shipped an **experimental Windows
beta**: a mouse-first, native (ConPTY-based) terminal multiplexer with panes,
splits, persistent sessions, and detach/attach — exactly the gap that section
describes.

Goal: install herdr as an **opt-in** tool and manage its config, wiring it
through the repo the same way every other optional tool is wired.

**Locked decisions (confirmed with user):**
1. **Gating** — a new dedicated `installHerdr` init toggle, default `false`
   (herdr is beta / preview-only / unsigned; opt-in only).
2. **Config** — the dotfiles manage herdr's `config.toml` as well as installing
   the binary.

**Key facts driving the design:**
- herdr has **no scoop/winget/npm manifest** — it installs via an `irm | iex`
  bootstrap: `irm https://herdr.dev/install.ps1 | iex`. This is the same shape as
  this repo's own `Ensure-Scoop` (`run_onchange_after_10_packages.ps1.tmpl:51-71`),
  so it needs a bespoke `Install-Herdr` helper, not the scoop/winget/npm paths.
- The installer is **non-interactive, user-scoped, no elevation**, idempotent
  (lock file, skips re-download). Windows is **preview-only** (honors
  `$env:HERDR_CHANNEL`). Bin junction lands at `%LOCALAPPDATA%\Programs\Herdr\bin`
  (not `~/scoop/shims`), which it prepends to User PATH.
- The `install.ps1` itself writes **no** config file → no installer-vs-chezmoi
  drift; chezmoi can fully own the config.
- herdr config is TOML at `%APPDATA%\herdr\config.toml` by default, but honors
  **`HERDR_CONFIG_PATH`** to relocate it — a clean fit for this repo's XDG
  pattern (identical to `STARSHIP_CONFIG` in `00_env.ps1:20`). Notable non-default
  keys: `[update] channel` must be `preview` on Windows; `[terminal] default_shell`
  defaults to `"nu"` — this repo standardizes on `pwsh` (matches WezTerm).

## Changes

### 1. Install wiring — `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`

- **Header toggle manifest** (after line 16, in the `# Toggles` block): add
  `#   installHerdr         = {{ .installHerdr }}`.
- **New helper**, placed alongside the other `--- xxx ---` function sections
  (e.g. after the npm block, ~line 132). Models `Ensure-Scoop` (fetch script →
  scriptblock → invoke), guarded so it's a no-op when already present, failures
  via `Register-Failure`, checks the real install path (independent of PATH,
  which won't refresh mid-apply):

  ```powershell
  # --- herdr (native Windows terminal multiplexer, preview beta) -------------
  # No scoop/winget/npm manifest — installs via herdr.dev's irm|iex bootstrap
  # (same shape as Ensure-Scoop). Windows is preview-only; the bin junction is
  # %LOCALAPPDATA%\Programs\Herdr\bin (added to PATH in profile.d/00_env.ps1).
  function Install-Herdr {
      $herdrBin = Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'
      if ((Have herdr) -or (Test-Path -LiteralPath $herdrBin)) { Info 'herdr already installed'; return }
      Info 'installing herdr (preview) via herdr.dev/install.ps1'
      try {
          $env:HERDR_CHANNEL = 'preview'   # Windows builds are preview-only
          $installer = [scriptblock]::Create((Invoke-RestMethod https://herdr.dev/install.ps1))
          & $installer
          if (-not (Test-Path -LiteralPath $herdrBin)) { Register-Failure 'herdr' }
      } catch {
          Write-Warning "herdr install error: $_"
          Register-Failure 'herdr'
      }
  }
  ```

- **Gated call** in the bottom `{{ if .installX -}}` region (mirror the
  `installTunnelTools` block, ~line 317):

  ```
  {{ if .installHerdr -}}
  Install-Herdr
  {{ end -}}
  ```

### 2. Init prompt — `.chezmoi.toml.tmpl`

Add after `installSshServer` (line 27). **The prompt TEXT is the CI join key —
copy it verbatim into `windows.yml` (invariant #1); no `=` in the text.**

```toml
    installHerdr         = {{ promptBoolOnce . "installHerdr" "Install herdr (native Windows terminal multiplexer, preview beta)" false }}
```

### 3. CI flags — `.github/workflows/windows.yml`

Add to the `$flags` array (after the sshd line, ~line 60), text matching #2 exactly:

```
      '--promptBool','Install herdr (native Windows terminal multiplexer, preview beta)=false',
```

### 4. PATH + config env — `dot_config/powershell/profile.d/00_env.ps1`

- Add herdr's bin to the `$UserPaths` array (lines 48-51) so `herdr` resolves in
  interactive shells immediately; the existing `Where-Object { Test-Path }`
  filter makes it a clean no-op when herdr isn't installed:

  ```powershell
      (Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin'),
  ```

- Add `HERDR_CONFIG_PATH` next to the other XDG file-redirects (near line 20-22,
  by `STARSHIP_CONFIG`):

  ```powershell
  # herdr reads its config here instead of %APPDATA%\herdr\config.toml (XDG-tidy).
  $env:HERDR_CONFIG_PATH = Join-Path $env:XDG_CONFIG_HOME 'herdr/config.toml'
  ```

### 5. Managed config — new file `dot_config/herdr/config.toml`

Static TOML (no templating needed), deployed to `~/.config/herdr/config.toml`:

```toml
# herdr — native Windows terminal multiplexer (preview beta).
# Managed by chezmoi; read via $env:HERDR_CONFIG_PATH (profile.d/00_env.ps1).
# Full default: `herdr --default-config`. Docs: https://herdr.dev/docs/configuration/

[update]
# Windows builds are preview-only; the installer rejects "stable" here.
channel = "preview"

[terminal]
# Match the rest of this repo (WezTerm / Windows Terminal default to pwsh).
default_shell = "pwsh"

[ui]
# "auto" draws herdr's own cursor on Windows to avoid ConPTY flicker;
# set "native" to hand the cursor to the outer terminal.
host_cursor = "auto"
```

### 6. Gate the config file — `.chezmoiignore`

`.chezmoiignore` ignores `docs/**` etc. but not `.config/**`, so the file would
deploy for everyone. `.chezmoiignore` is rendered as a Go template, so gate it on
the toggle (append):

```
{{ if not .installHerdr }}
.config/herdr/config.toml
{{ end }}
```

### 7. Docs + skill (bilingual mirrors, same commit)

- **`docs/rationale.md:64-83` + `docs/rationale.zh-TW.md:55-71`** — update the
  multiplexer section: add a **herdr** row to the comparison table (native
  Windows, splits/tabs + detach/persist, "beta/preview") and a short paragraph
  noting herdr is now the native tmux-like option (opt-in via `installHerdr`)
  while **WezTerm stays the stable default**. Soften the "no native Windows
  builds" framing so it no longer reads as absolute.
- **`docs/tools.md:125-134` + `docs/tools.zh-TW.md:121-130`** — add a row to the
  "Opt-in dev stacks" table:
  `| herdr | native Windows terminal multiplexer (preview beta), installed via herdr.dev's install script; config at ~/.config/herdr/config.toml |`
- **`docs/setup.md:31-48` + `docs/setup.zh-TW.md:26-42`** — add an init-prompt
  table row: `| herdr multiplexer | off | native Windows terminal multiplexer (preview beta) |`
- **`.chezmoitemplates/dotfiles-windows-skill.md`** — add `· herdr: {{ .installHerdr }}`
  to the "What's enabled" line (line 56) and update the tmux/zellij Gotcha
  (lines 69-71) to mention herdr as the native beta multiplexer.
- **`CLAUDE.md` / `AGENTS.md` "Config surfaces" line** (~line 54) — append herdr
  (`~/.config/herdr/config.toml` via `HERDR_CONFIG_PATH`) so the architecture map
  stays accurate. Minor; keeps future agents oriented.

## Files to change

| # | File | Change |
|---|---|---|
| 1 | `.chezmoi.toml.tmpl` | new `installHerdr` prompt (default false) |
| 2 | `.github/workflows/windows.yml` | matching `--promptBool` flag |
| 3 | `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` | header note + `Install-Herdr` + gated call |
| 4 | `dot_config/powershell/profile.d/00_env.ps1` | PATH entry + `HERDR_CONFIG_PATH` |
| 5 | `dot_config/herdr/config.toml` | **new** managed config |
| 6 | `.chezmoiignore` | gate config on `installHerdr` |
| 7 | `docs/rationale.md` + `.zh-TW.md` | multiplexer section update |
| 8 | `docs/tools.md` + `.zh-TW.md` | opt-in dev stacks row |
| 9 | `docs/setup.md` + `.zh-TW.md` | init-prompt table row |
| 10 | `.chezmoitemplates/dotfiles-windows-skill.md` | "What's enabled" + Gotcha |
| 11 | `CLAUDE.md` (`AGENTS.md` symlink) | config-surfaces line |

## Verification

Off-Windows (this checkout) — the installer can't actually run here; the
`windows-latest` CI is the real gate. Validate structurally:

1. **Template renders + parses** (isolated apply idiom from CLAUDE.md). Init a
   throwaway state passing **every** prompt including the new one
   (`--promptBool 'Install herdr (native Windows terminal multiplexer, preview beta)=true'`),
   then `chezmoi execute-template … < run_onchange_after_10_packages.ps1.tmpl > r.ps1`
   and parse with pwsh — confirm the `Install-Herdr` block is present and parses.
   Re-render with the flag `=false` and confirm the block is absent.
2. **Config gating** — with `installHerdr=false`, confirm `chezmoi apply
   --exclude=scripts` into the temp destination does **not** write
   `.config/herdr/config.toml`; with `=true`, confirm it does.
3. **Config validity** — parse `dot_config/herdr/config.toml` with Python
   `tomllib` (per invariant #3 spirit) to confirm valid TOML.
4. **Lint** — `Invoke-ScriptAnalyzer` on the changed `.ps1.tmpl` (Errors only).
5. **Docs** — `just docs-build` must stay green (`--strict`; bilingual twins).
6. **CI parity** — confirm the new `windows.yml` flag text is byte-identical to
   the `.chezmoi.toml.tmpl` prompt text (otherwise `--no-tty` init hangs).

On a real Windows box (post-merge sanity): `chezmoi apply` with herdr enabled →
`herdr --version` resolves, new shell has `%LOCALAPPDATA%\Programs\Herdr\bin` on
PATH, and `herdr` reads `~/.config/herdr/config.toml` (pwsh as default shell).

## Out of scope (note as TODO if wanted later)

- A `profile.d/15_herdr.ps1` shell-integration fragment (herdr's live-cwd is
  handled by `[terminal] new_cwd`, and PATH/config are covered in `00_env.ps1`)
  — add only if herdr ships a `herdr init powershell` hook worth caching.
