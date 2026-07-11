# Install WSL2 as the Docker Desktop backend (self-elevating, opt-out)

## Context

Docker Desktop is installed today via winget (`Docker.DockerDesktop`, in the
`installWindowsApps` block of `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl:283`)
but the repo does **nothing** about its WSL2 backend. On a machine without WSL,
Docker Desktop installs but can't start — the user hits "WSL not installed" and
has to run `wsl --install` by hand from an admin PowerShell, then reboot.

`wsl --install` requires **admin elevation** and (almost always) a **reboot** to
finish enabling the kernel/hypervisor features — this is true even for the
modern Store-delivered WSL. We can never auto-reboot from inside a `chezmoi
apply`, so every path ends with a "restart required" message.

**Decisions (from the user):**
- **Self-elevate during apply.** When the apply reaches the WSL step and isn't
  already elevated, it fires a single UAC prompt (`Start-Process -Verb RunAs`),
  runs the install elevated, and returns — the "one click" experience, like
  scoop's popup. (This is a new pattern for the repo, which otherwise only
  *detects* elevation. Note the apply already pops UAC today for Docker's
  machine-scope winget fallback, so it's not unprecedented in effect.)
- **Default ON for workstation** (`$full`), mirroring Docker itself. A fresh
  workstation setup provisions the backend automatically; `minimal` skips it.

We reuse the OpenSSH model wholesale: a single-source-of-truth
`scripts/enable-wsl.ps1`, a gated `run_onchange` wrapper that `{{ include }}`s
it, a `just enable-wsl` fallback recipe, and a new init toggle — exactly the
shape of `scripts/enable-sshd.ps1` + `run_onchange_after_40_openssh_server.ps1.tmpl`.

## Approach

### 1. New logic: `scripts/enable-wsl.ps1` (model on `scripts/enable-sshd.ps1`)

`#Requires -Version 7`, `$ErrorActionPreference='Continue'`,
`PSNativeCommandUseErrorActionPreference=$false`, a `Test-Admin` helper (copy the
one from `enable-sshd.ps1:20-25`), all work in `try/catch` — **never abort the
apply** (hard invariant #2). Header comment explaining the dual run context
(embedded in apply + `just enable-wsl`), same as `enable-sshd.ps1:2-15`.

Flow:
1. **Already-installed guard (runs first, unelevated — must not pop UAC when WSL
   is already present).** Treat WSL as present if `wsl.exe --status` **or**
   `wsl.exe --version` exits 0. If present → `Info 'WSL already installed'` and
   `return`. (Query is exit-code based because `Get-WindowsOptionalFeature
   -Online` needs admin; `wsl.exe` is always on PATH as a stub even when the
   feature is off, so presence must be judged by exit code, not `Get-Command`.)
2. **Install.** Command is `wsl.exe --install --no-distribution` — Docker only
   needs the WSL2 platform + its own auto-created `docker-desktop` distro, not
   Ubuntu. (`--no-distribution` is modern-WSL only; on a build that rejects it,
   fall back to `wsl.exe --install --no-launch`, then plain `wsl.exe --install`.)
   - **If `Test-Admin`:** run it inline, capture `$LASTEXITCODE`.
   - **If not admin (self-elevate):** `Start-Process pwsh -Verb RunAs -Wait
     -ArgumentList '-NoProfile','-NoLogo','-Command',$cmd` where `$cmd` runs the
     install elevated then prints the reboot notice and pauses so the user sees
     it. Wrap in `try/catch`: a declined UAC throws
     ("operation was canceled by the user") → `Write-Warning` with the
     `just enable-wsl` retry guidance and return cleanly.
3. **Reboot notice.** Always end (both paths) with a clear
   `Write-Warning 'WSL: a RESTART is required before Docker Desktop can use the
   WSL2 backend. Reboot, then start Docker Desktop.'` — the repo has no
   pending-reboot convention today; this message is it.

### 2. Wrapper: `.chezmoiscripts/run_onchange_after_45_wsl.ps1.tmpl`

Copy `run_onchange_after_40_openssh_server.ps1.tmpl` verbatim, swapping the gate
and include:
```
{{ if .installWsl -}}
{{ include "scripts/enable-wsl.ps1" }}
{{ end -}}
```
`after_45` groups it with the other admin-feature enabler (sshd = 40). Ordering
vs. the packages script (Docker install, `after_10`) is irrelevant — the reboot
means the backend isn't live until restart regardless.

### 3. Toggle: `.chezmoi.toml.tmpl` (after line 19, near the GUI-apps toggle)

```
installWsl = {{ promptBoolOnce . "installWsl" "Install WSL2 (Docker Desktop backend; needs admin + reboot)" $full }}
```
Default `$full`. Prompt text contains **no `=`** (invariant #1 — the CI parser
splits on the first `=`).

### 4. CI flag: `.github/workflows/windows.yml` (in the `$flags` array, ~line 47-68)

Add, matching the prompt TEXT exactly (invariant #1):
```
'--promptBool','Install WSL2 (Docker Desktop backend; needs admin + reboot)=false',
```
`false` in CI even though real default is `$full` — CI runs `chezmoi apply
--exclude scripts`, so the script never executes there anyway; this only stops
init from hanging on an unanswered prompt.

### 5. `just enable-wsl` recipe: `justfile` (next to `enable-sshd`, ~line 44)

```
# install WSL2 (Docker Desktop backend) — pops one UAC prompt; reboot required after
enable-wsl:
    pwsh -NoProfile -File ./scripts/enable-wsl.ps1
```
This is also the **retry path** if the apply's UAC was declined (run_onchange is
content-hash gated, so it won't re-fire on the next apply — same as sshd).

### 6. Docs + skill mirrors (all in the same commit — cross-file invariants)

- `docs/setup.md` init-prompt table (~line 87, by the OpenSSH row) **+**
  `docs/setup.zh-TW.md` twin: new row — `WSL2 backend | on (workstation) | install WSL2 for Docker Desktop (needs admin; reboot required)`.
- `docs/tools.md` "Opt-in dev stacks" table (~line 141, by the OpenSSH row) **+**
  `docs/tools.zh-TW.md` twin: new row describing `wsl --install --no-distribution`,
  the self-elevating UAC prompt, the reboot, and `just enable-wsl`.
- `docs/rationale.md` (~line 26, the WSL "out of scope" note) **+**
  `docs/rationale.zh-TW.md` twin: short clarification that WSL-as-Docker-backend
  is the **exception** to "WSL is a Linux env handled by the other repo" — here
  we enable only the WSL2 *platform* for Docker's containers, not a Linux shell.
- `.chezmoitemplates/dotfiles-windows-skill.md` "What's enabled" block
  (line 56, end of that line): append ` · WSL2: {{ .installWsl }}`.

### 7. Pitfall doc: `pitfalls/wsl-install-no-action-reboot-required.md`

Symptom-titled (invariant: title by symptom). Verbatim symptom
`No action was taken as a system reboot is required.` /
`The requested operation requires elevation.`; root cause (WSL enables
kernel/hypervisor features that need a restart + admin); workaround
(`just enable-wsl`, approve UAC, reboot, start Docker Desktop); prevention
(the toggle + self-elevating script). `pitfalls/` is chezmoi-ignored — review
for secrets before commit (there are none here).

### 8. (Optional) backlog: auto-resume after reboot

We deliberately **don't** automate the reboot or auto-resume Docker setup after
it. Per CLAUDE.md, log that as a `P?`/`[M]` entry via
`scripts/add-todo.sh --priority P3 --effort M --title "Auto-resume WSL/Docker
setup after required reboot" --description "..." --backlog`, then run
`scripts/todo-kanban.sh --validate-only TODO.md`.

## Files

**New:** `scripts/enable-wsl.ps1` · `.chezmoiscripts/run_onchange_after_45_wsl.ps1.tmpl` ·
`pitfalls/wsl-install-no-action-reboot-required.md`

**Modified:** `.chezmoi.toml.tmpl` · `.github/workflows/windows.yml` · `justfile` ·
`docs/setup.md` · `docs/setup.zh-TW.md` · `docs/tools.md` · `docs/tools.zh-TW.md` ·
`docs/rationale.md` · `docs/rationale.zh-TW.md` ·
`.chezmoitemplates/dotfiles-windows-skill.md` · (optional) `TODO.md` + `backlog/`

## Verification (no Windows box needed — the repo's standard idiom)

1. **Lint:** `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path ./scripts/enable-wsl.ps1 -Settings ./PSScriptAnalyzerSettings.psd1"` — must be Error-free.
2. **Render + parse both gate states** (invariant #3-style verify the include lands):
   ```
   # installWsl=true → body present and parses
   chezmoi execute-template --config="$TMPD/c.toml" --source="$PWD" \
     < .chezmoiscripts/run_onchange_after_45_wsl.ps1.tmpl > r.ps1
   pwsh -NoProfile -c '$null=[System.Management.Automation.Language.Parser]::ParseFile("r.ps1",[ref]$null,[ref]$null)'
   ```
   Re-render with an init that answers the WSL prompt `false` → body should be empty.
3. **Isolated init doesn't hang** on the new prompt: run the `chezmoi init`
   idiom from CLAUDE.md with `--promptBool 'Install WSL2 (Docker Desktop backend; needs admin + reboot)=minimal-or-bool'`
   added; confirm it completes non-interactively.
4. **Docs stay green:** `just docs-build` (mkdocs `--strict`) — catches missing
   nav / broken zh-TW mirror.
5. **CI** (`windows.yml`, the real gate): PSScriptAnalyzer + non-interactive init
   (new flag) + render/parse of the new `.tmpl` + Pester.
6. **Real machine (manual):** on a workstation, `chezmoi apply` → single UAC
   popup at the WSL step → `wsl --install --no-distribution` runs → "restart
   required" warning; reboot → Docker Desktop starts on the WSL2 backend.
   Re-run `chezmoi apply` → the already-installed guard makes it a silent no-op
   (no second UAC). `just enable-wsl` exercises the standalone/retry path.
