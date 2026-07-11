# Install a WSL2 Ubuntu distro + bootstrap cross-platform dotfiles (unattended, opt-in)

## Context

The just-shipped `installWsl` toggle installs only the **WSL2 platform**
(`wsl --install --no-distribution`) as Docker Desktop's backend — no Linux
distro. This feature layers a real **Ubuntu** on top: an **opt-in, default-off**
toggle that registers Ubuntu **unattended** (no interactive OOBE
username/password) and bootstraps the user's **cross-platform** dotfiles
(`github.com/daviddwlee84/dotfiles`) inside it.

The parent repo has ~35 chezmoi init prompts (all defaulted; default profile
`ubuntu_server`, correct for WSL). Its `bootstrap.sh` wrapper *aborts* without a
TTY, but the **direct chezmoi one-liner** runs headless with `--promptDefaults`
plus explicit `--promptString`/`--promptChoice` overrides. That's the key: we
**prompt once on Windows, freeze a non-interactive init command, and run it
headless inside WSL** — the user's choices captured up front, zero prompts in
WSL. (Scope: this repo only *triggers* the parent installer; it doesn't own
Linux config — the documented "WSL is a Linux env handled by the other repo"
stance holds, this is an opt-in bridge.)

**Decisions (from the user):**
- **Bootstrap = headless, frozen from Windows** (default), but selectable via a
  `wslUbuntuBootstrap` choice prompt (`headless` | `interactive` | `none`).
- **User account:** a `wslUsername` prompt (default = Windows username), **locked
  password + passwordless sudo** (WSL auto-logs-in as the default user; no OOBE).
- **Freeze minimal:** name + email + reuse this repo's `useChineseMirror`
  (mapped onto the parent's China-mirror prompt); everything else = parent
  defaults (`ubuntu_server`, coding agents on).
- WSLg (Win11) covers GUI apps for free if the profile is later switched to
  `ubuntu_desktop` — noted as a future toggle, not built now.

## Approach

Mirror the shipped three-part WSL pattern (`scripts/enable-wsl.ps1` +
gated `run_onchange` wrapper + `just` recipe + toggle + CI flag + docs).
Everything lives in **one PowerShell script** — no cloud-init file needed; the
user is created imperatively via `wsl -u root`, which is simpler, version-
agnostic, and avoids deploying/gating a `~/.cloud-init/` artifact.

### 1. `scripts/enable-wsl-ubuntu.ps1` (model on `scripts/enable-wsl.ps1`)

Same skeleton: `#Requires -Version 7`, `param([switch]$Elevated)`,
`$ErrorActionPreference='Continue'` + `PSNativeCommandUseErrorActionPreference=$false`,
`Info`/`Test-Admin`, self-elevation (`Start-Process -Verb RunAs -Wait … -Elevated`,
declined-UAC caught), `Read-Host` pause only when `-Elevated`, all in
`try/catch` — **never abort the apply** (invariant #2). Set `$env:WSL_UTF8='1'`
so `wsl -l`/`--status` output is UTF-8, not UTF-16 mojibake.

Flow (params baked in at render time via the wrapper — see §2):
1. **Precondition:** WSL2 platform usable — `& wsl.exe --status` exits 0. If not
   (platform not enabled or reboot pending from `installWsl`), `Write-Warning`
   "enable installWsl + reboot first, then `just enable-wsl-ubuntu`" and return.
   (Don't install the platform here — separation of concerns.)
2. **Idempotence:** if `Ubuntu-24.04` is already registered (`wsl.exe -l -q`
   contains it) **and** dotfiles are present
   (`wsl -d Ubuntu-24.04 -u <user> -- test -d ~/.local/share/chezmoi`), no-op.
   Registered-but-no-dotfiles → skip straight to the bootstrap step (retry path).
3. **Register (no OOBE):** `wsl.exe --install -d Ubuntu-24.04 --no-launch`
   (fallback/warn if `--no-launch` unsupported).
4. **Create the user as root** (bypasses OOBE) — pipe a small bash script via
   stdin to dodge quoting hell:
   `"<root-setup>" | wsl.exe -d Ubuntu-24.04 -u root -- bash -s` where the script
   does `useradd -m -s /bin/bash -G sudo,adm <user>`, `passwd -l <user>`, writes
   `/etc/sudoers.d/90-<user>` (`<user> ALL=(ALL) NOPASSWD:ALL`), and
   `printf '[user]\ndefault=<user>\n' > /etc/wsl.conf`. Then
   `wsl.exe --terminate Ubuntu-24.04` so `wsl.conf` takes effect.
5. **Dotfiles (headless mode only):** pipe the **frozen bootstrap script** (built
   on Windows, LF endings, with `<name>/<email>/<mirror>` interpolated) via stdin
   to `wsl.exe -d Ubuntu-24.04 -u <user> -- bash -s`. Capture `$LASTEXITCODE`;
   `Register-Failure`-style warning on non-zero. The frozen command:
   ```
   sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" \
     init --apply "https://github.com/daviddwlee84/dotfiles.git" --promptDefaults \
     --promptString "What is your full name=<name>" \
     --promptString "What is your email address=<email>" \
     --promptChoice "Which profile=ubuntu_server" \
     --promptBool "Are you in China (behind GFW) and need to use mirrors=<mirror>"
   ```
   For `interactive`/`none`: skip step 5, print the one-liner as guidance.
6. **No reboot** needed here (the platform reboot already happened via
   `installWsl`); end with a short "Ubuntu ready — open `wsl`" `Info`.

Piping bash via stdin (`bash -s`) is the crux for avoiding PowerShell→wsl→bash
quote escaping — the same reasoning as the CSI-u "generate + re-parse" invariant.

### 2. Wrapper: `.chezmoiscripts/run_onchange_after_46_wsl_ubuntu.ps1.tmpl`

Copy `run_onchange_after_45_wsl.ps1.tmpl`, gate on `installWslUbuntu`, and pass
the frozen answers as script args so the embedded script has them at apply time
(the include renders the `.ps1` with chezmoi data available):
```
{{ if .installWslUbuntu -}}
{{ include "scripts/enable-wsl-ubuntu.ps1" }}
{{ end -}}
```
The script reads `{{ .name }}`, `{{ .email }}`, `{{ .useChineseMirror }}`,
`{{ .wslUsername }}`, `{{ .wslUbuntuBootstrap }}` — but since `enable-wsl-ubuntu.ps1`
must also run standalone via `just`, template values can't be inlined there.
**Resolution:** the wrapper renders a tiny prelude that sets `$Name/$Email/
$Mirror/$User/$Mode` from chezmoi data, then includes the logic; the `just`
recipe passes them as parameters (defaults read from the persisted
`~/.config/chezmoi/chezmoi.toml` via `chezmoi data`, or accepts `--set`). Keep
the script parameterized (`param([string]$User,[string]$Name,...)`) so both
callers work. `after_46` sits right after the platform script (`after_45`).

### 3. Three new prompts: `.chezmoi.toml.tmpl` (after the `installWsl` line, ~L20)

```
installWslUbuntu   = {{ promptBoolOnce . "installWslUbuntu" "Install a WSL2 Ubuntu distro and bootstrap cross-platform dotfiles inside it (needs admin; requires WSL2 platform)" false }}
wslUsername        = {{ promptStringOnce . "wslUsername" "WSL Ubuntu username" (.chezmoi.username | lower) }}
wslUbuntuBootstrap = {{ promptChoiceOnce . "wslUbuntuBootstrap" "WSL Ubuntu dotfiles bootstrap (headless|interactive|none)" (list "headless" "interactive" "none") "headless" | quote }}
```
Default OFF (invariant: no `=` in any prompt text). The script sanitizes
`wslUsername` to a valid Linux name (lowercase, strip domain/`\`, `[a-z0-9_-]`).

### 4. CI flags: `.github/workflows/windows.yml` (in `$flags`, by the `installWsl` line)

Three matching entries (text byte-identical to §3, invariant #1):
```
'--promptBool','Install a WSL2 Ubuntu distro and bootstrap cross-platform dotfiles inside it (needs admin; requires WSL2 platform)=false',
'--promptString','WSL Ubuntu username=ci',
'--promptChoice','WSL Ubuntu dotfiles bootstrap (headless|interactive|none)=none',
```

### 5. `just enable-wsl-ubuntu` recipe: `justfile` (next to `enable-wsl`)

Mirror shape; the retry path after the platform reboot.

### 6. Docs + skill mirrors (same commit — cross-file invariants)

- `docs/setup.md` + `.zh-TW`: 3 new init-prompt table rows (by the WSL2 row).
- `docs/tools.md` + `.zh-TW`: a note by the WSL2-backend note — unattended Ubuntu,
  the frozen-from-Windows bootstrap, `just enable-wsl-ubuntu`, requires
  `installWsl` + reboot first. Mention **WSLg** (GUI apps work if profile→desktop).
- `docs/rationale.md` + `.zh-TW`: extend the WSL exception paragraph — the Ubuntu
  bridge triggers the cross-platform repo's installer; Linux config stays there.
- `.chezmoitemplates/dotfiles-windows-skill.md`: "What's enabled" (`WSL Ubuntu:
  {{ .installWslUbuntu }}`) + `enable-wsl-ubuntu` in the recipe list.

### 7. Pitfall doc: `pitfalls/wsl-ubuntu-oobe-and-wsl-l-encoding.md`

Symptoms: `wsl -l` mojibake in pwsh (fix: `$env:WSL_UTF8=1`); `/etc/wsl.conf`
`[user] default=` ignored until `wsl --terminate`; OOBE username/password prompt
if you launch without `--no-launch`/`-u root`. Root cause + copy-paste fixes.

### 8. Backlog/TODO: promote the existing item

`backlog/wsl-ubuntu-auto-dotfiles.md` + its `TODO.md` P? entry (added last turn,
still uncommitted): move the TODO entry to `## Done` with the dated syntax and
mark the backlog doc `Status: shipped` (keep as record), noting the chosen
imperative-`wsl -u root` approach (cloud-init logged as the considered
alternative).

## Files

**New:** `scripts/enable-wsl-ubuntu.ps1` ·
`.chezmoiscripts/run_onchange_after_46_wsl_ubuntu.ps1.tmpl` ·
`pitfalls/wsl-ubuntu-oobe-and-wsl-l-encoding.md`

**Modified:** `.chezmoi.toml.tmpl` · `.github/workflows/windows.yml` · `justfile` ·
`docs/setup.md`/`.zh-TW` · `docs/tools.md`/`.zh-TW` · `docs/rationale.md`/`.zh-TW` ·
`.chezmoitemplates/dotfiles-windows-skill.md` · `TODO.md` ·
`backlog/wsl-ubuntu-auto-dotfiles.md` · `backlog/README.md`

## Verification (no Windows box — repo's standard idiom; real run needs Windows+WSL)

1. **Lint:** `Invoke-ScriptAnalyzer -Path ./scripts/enable-wsl-ubuntu.ps1 -Settings ./PSScriptAnalyzerSettings.psd1` → Error-free.
2. **Render + parse** `run_onchange_after_46_wsl_ubuntu.ps1.tmpl` for
   `installWslUbuntu` true/false (isolated `chezmoi init` idiom, passing all
   prompts incl. the 3 new ones) → true embeds body & parses, false is a no-op.
   Also render with each `wslUbuntuBootstrap` value to confirm the frozen command
   is well-formed.
3. **Init doesn't hang** on the 3 new prompts (exact-text flags).
4. **Docs:** `just docs-build` (`--strict`) green; anchors resolve.
5. **CI** (`windows.yml`): PSScriptAnalyzer + init + render/parse + Pester.
6. **Real machine (manual):** after `installWsl` + reboot →
   `just enable-wsl-ubuntu` (or a fresh apply) → `Ubuntu-24.04` registers with no
   OOBE, user created (passwordless sudo, WSL auto-login), frozen bootstrap runs
   → `wsl` drops into a ready dotfiles shell, no prompts. Re-run → idempotent
   no-op. `interactive`/`none` modes skip the auto-bootstrap and print guidance.
