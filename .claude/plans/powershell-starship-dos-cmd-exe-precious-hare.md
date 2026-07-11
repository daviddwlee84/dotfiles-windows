# Optional cmd.exe support via Clink (starship + zoxide + fzf)

## Context

The repo is PowerShell-only by design. The user noticed starship also supports
cmd.exe and asked whether we can **also** support a cmd setup, sharing most of
the dotfiles with only the "scripts" differing.

**Feasibility verdict (from research):** yes for the *prompt + env layer*, and the
sharing is actually better than hoped for config, thinner for behavior:

- **Already shared, zero extra work.** `dot_config/starship.toml` is cross-platform
  verbatim. The four `XDG_*` env vars are **already persisted to the User registry**
  by `.chezmoiscripts/run_onchange_after_03_xdg_env.ps1`, so cmd inherits them for
  free. Tools (starship, zoxide, fzf) are scoop-installed once and on PATH via
  scoop shims (also persisted). ⇒ starship in cmd renders *identically* with no
  extra config.
- **cmd's line editor is Clink** — its PSReadLine analog (v1.2.30+, scoop `main`
  bucket, v1.9.28). starship/zoxide/fzf all have Clink Lua integrations. This is
  the new "script" layer cmd needs.
- **No cmd equivalent** for atuin, direnv, tv, or any PowerShell function/module
  (`20_aliases.ps1`, `28_tldr.ps1`, `30_apps.ps1` audio P/Invoke, `35_yazi.ps1`,
  `40_copilot.ps1`, `98_tv_cache.ps1`). cmd gets **prompt + navigation parity, not
  feature parity** — and `90_psreadline.ps1` has no port because *Clink itself* is
  the replacement.

**Decisions locked with the user:**
- Scope = **starship + zoxide + fzf** (vendor `clink-zoxide` + `clink-fzf` Lua).
- Clink profile lives at **`%LocalAppData%\clink`** (Clink's default — auto-found
  at inject time, no env var needed).

Intended outcome: an **opt-in** (`installClink`, default `false`) secondary shell
target that gives cmd.exe a starship prompt, `z` dir-jumping, and Ctrl-R/Ctrl-T
fzf — reusing the existing shared config, without disturbing the pwsh-first story.

## Approach

Four moving parts, each slotting into an existing repo pattern. Clink loads any
`*.lua` in its profile dir automatically, so the config is just static Lua files;
the only imperative step is installing clink + registering its cmd AutoRun.

### 1. Init prompt (Hard invariant #1 — prompt + CI flag in the SAME commit)

- **`.chezmoi.toml.tmpl`** — add one opt-in toggle after the existing block
  (`.chezmoi.toml.tmpl:31`). Default `false` (cmd is a niche secondary target;
  matches `installMediaTools`/`installLlmTools` style, not `$full`):
  ```
  installClink = {{ promptBoolOnce . "installClink" "Install Clink + starship/zoxide/fzf for cmd.exe (DOS prompt)" false }}
  ```
  ⚠️ No `=` anywhere in the prompt TEXT (invariant #1 — the `name=value` parser
  splits on the first `=`).
- **`.github/workflows/windows.yml`** — add the matching pair to the `$flags`
  array (verbatim text or CI's non-interactive init hangs):
  ```
  '--promptBool','Install Clink + starship/zoxide/fzf for cmd.exe (DOS prompt)=false',
  ```

### 2. Package install (installer is the single source of truth — invariant #2)

Edit **`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`**:
- Add `installClink = {{ .installClink }}` to the header **Toggles** comment
  (lines 7-18) — otherwise flipping the toggle won't re-render the script and
  `run_onchange` won't re-fire.
- Add a gated block alongside the other single-tool gates (model on the
  `installTunnelTools` block at line 317). `clink` is in scoop `main` (already
  bucket-added by `Ensure-Scoop`). Keep it fault-tolerant (autorun/set are
  idempotent; failures go through `Register-Failure`):
  ```
  {{ if .installClink -}}
  # Clink = Bash-style line editing for cmd.exe, so starship/zoxide/fzf work in
  # the DOS prompt too. Lua config deploys to %LocalAppData%\clink via chezmoi.
  Scoop-Install @('clink')
  if (Have clink) {
      clink autorun install *> $null           # HKCU AutoRun; inject into every cmd.exe (no admin)
      clink set fzf.default_bindings true *> $null   # Ctrl-R history / Ctrl-T files / Alt-C dir
  } else { Register-Failure 'clink (autorun/settings not configured)' }
  {{ end -}}
  ```
  `clink autorun install` writes `HKCU\...\Command Processor\AutoRun` (per-user),
  so every new cmd.exe injects Clink and loads our Lua. fzf.exe is on PATH via the
  scoop shim, so `clink-fzf` auto-locates it.

### 3. Clink profile — three static Lua files at `%LocalAppData%\clink`

chezmoi maps source `AppData/Local/clink/` → `~/AppData/Local/clink` =
`%LOCALAPPDATA%\clink` (Clink's default profile dir). Deploy as **plain chezmoi
files** (like `dot_config/wezterm/wezterm.lua` and `AppData/Roaming/television/`) —
Clink auto-loads them; they also get CI apply-tested by the "apply (files only)"
step. New source files:

- **`AppData/Local/clink/starship.lua`** — the documented one-liner (reuses the
  shared `starship.toml` + inherited env vars, no other config):
  ```lua
  -- starship prompt for cmd.exe via Clink. Reuses ~/.config/starship.toml.
  load(io.popen('starship init cmd'):read("*a"))()
  ```
- **`AppData/Local/clink/zoxide.lua`** — vendored from
  [`shunsambongi/clink-zoxide`](https://github.com/shunsambongi/clink-zoxide)
  (verify MIT; add a header comment citing repo + commit, the way `28_tldr.ps1`
  cites its parent-repo origin). Keep the default `z`/`zi` commands — do **not**
  rebind `cd` in cmd (cmd's builtin `cd` has different semantics than pwsh's).
- **`AppData/Local/clink/fzf.lua`** — vendored from
  [`chrisant996/clink-fzf`](https://github.com/chrisant996/clink-fzf) (MIT).
  Bindings enabled via the `clink set fzf.default_bindings true` in step 2.

**`.chezmoiignore`** — gate these on the toggle so pwsh-only users get nothing in
`%LocalAppData%\clink` (`.chezmoiignore` is always templated by chezmoi):
```
{{ if not .installClink }}
AppData/Local/clink/**
{{ end }}
```

### 4. Docs + skill mirrors (Cross-file mirrors — same commit)

- **`docs/rationale.md` + `docs/rationale.zh-TW.md`** — qualify the opening
  "PowerShell 7, not cmd/DOS" section (`docs/rationale.md:5-13`): pwsh stays the
  default; cmd is an **optional secondary target** via Clink+starship for
  muscle-memory / tools that spawn cmd, with prompt+nav parity only. Reframe from
  anti-goal to "opt-in, scoped."
- **`docs/tools.md` + `docs/tools.zh-TW.md`** — add `clink` as an installer tool
  (mirror rule: new installer tool → both tools docs).
- **`docs/setup.md` + `docs/setup.zh-TW.md`** — add the `installClink` prompt row
  (mirror rule: new init prompt → setup tables).
- **`.chezmoitemplates/dotfiles-windows-skill.md`** — add `installClink` to the
  "What's enabled" block (mirror rule: new init prompt → skill block).
- **`docs/shell.md` + `docs/shell.zh-TW.md`** — add a short "cmd.exe via Clink"
  section (what works: starship/z/fzf; what doesn't: aliases, functions, yazi `y`,
  copilot, atuin/direnv/tv). Folding into shell.md avoids a new nav page +
  `nav_translations` entry; a dedicated `docs/cmd.md` is a heavier alternative.

## Critical files

| File | Change |
|---|---|
| `.chezmoi.toml.tmpl` | + `installClink` prompt (default `false`, no `=` in text) |
| `.github/workflows/windows.yml` | + `--promptBool` flag pair in `$flags` |
| `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` | + header toggle line; + `{{ if .installClink }}` clink block |
| `AppData/Local/clink/starship.lua` | **new** — starship autorun one-liner |
| `AppData/Local/clink/zoxide.lua` | **new** — vendored clink-zoxide |
| `AppData/Local/clink/fzf.lua` | **new** — vendored clink-fzf |
| `.chezmoiignore` | + templated gate for `AppData/Local/clink/**` |
| `docs/rationale{,.zh-TW}.md` | qualify the cmd/DOS section |
| `docs/tools{,.zh-TW}.md` | + clink row |
| `docs/setup{,.zh-TW}.md` | + installClink prompt row |
| `docs/shell{,.zh-TW}.md` | + "cmd.exe via Clink" section |
| `.chezmoitemplates/dotfiles-windows-skill.md` | + installClink in "What's enabled" |

## Verification

Off-Windows (this checkout — the `.lua`/registry parts can't execute here; CI is
the real gate):

1. **Isolated apply** with `installClink` answered `true`, using the exact
   pattern in `CLAUDE.md` (pass **every** prompt incl. the new
   `Install Clink + starship/zoxide/fzf for cmd.exe (DOS prompt)=true`). Confirm
   `AppData/Local/clink/{starship,zoxide,fzf}.lua` land in the temp destination;
   re-run with `=false` and confirm the `.chezmoiignore` gate excludes them.
2. **Render + parse** the packages template with `installClink=true` via
   `chezmoi execute-template` and PowerShell-parse the output (the clink block).
3. **Lint** — `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` (Errors only).
4. **Docs** — `just docs-build` (`--strict`) stays green after rationale/tools/setup/shell edits.
5. **CI (windows-latest)** — the render+parse step covers the new template; the
   "apply (files only)" step deploys the `.lua` files; init won't hang once the
   `$flags` pair is added.

On a real Windows box (the true end-to-end check):

6. `chezmoi apply` with `installClink=true`, open a **new** cmd.exe, and verify:
   starship prompt renders (same theme as pwsh), `z <dir>` jumps, `Ctrl-R` opens
   fzf history, `Ctrl-T` file picker. `clink info` should list the
   `%LocalAppData%\clink` profile and the three loaded scripts.

## Out of scope (documented as cmd limitations, not ported)

atuin, direnv, tv, and all pwsh functions/modules (aliases, yazi `y`, audio,
copilot-proxy, tldrf, tv-cache). These have no first-class cmd/Clink path;
attempting doskey/Lua rewrites would be high-effort, low-value, and is explicitly
excluded. Note them in the `docs/shell.md` cmd section so expectations are clear.
