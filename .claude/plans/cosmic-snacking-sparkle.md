# Fresh-machine setup fixes + OpenSSH server

## Context

Setting up `hanruzhou`'s new (OneDrive-KFM, Microsoft-corp) Windows box surfaced
several defects and one feature request. All are independent and should land as
**separate commits**, but are planned together because they came from one setup log.

1. **OneDrive `$PROFILE` redirect is fragile** (the core request). On a machine
   where `Documents` is OneDrive-redirected, `run_onchange_after_02_profile_redirect.ps1`
   writes a *stub* at the real `$PROFILE` that dot-sources the **literal**
   `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1` — which need not exist
   there under KFM. Result: `The term '...\Documents\PowerShell\...ps1' is not
   recognized`. The managed loader is location-independent (only references
   `~/.config/powershell`), so the stub-pointer indirection is unnecessary and
   should be replaced by writing the loader **content** directly.
2. **pwsh startup takes 8827 ms.** `10_tools.ps1` cold-spawns 5–6 init binaries on
   every shell and does 3 full `PSModulePath` scans (slow under OneDrive hydration).
3. **`uv python install --default` fails** on uv 0.11+ (`--default` moved behind
   `--preview`). Stale "needs uv >= 0.8" comment; command echoed in 4 docs files.
4. **msstore ChatGPT ID is wrong** — mislabeled, not just dead (see IDs below).
5. **New request: install/enable the OpenSSH server (sshd).**
6. **Alacritty can't find `Hack Nerd Font Mono`** (Windows Terminal can) — the font
   is registered per-user (HKCU) by scoop's nerd-fonts bucket, and Alacritty on
   Windows reads only machine-wide (HKLM) fonts.
7. **WezTerm opens `cmd.exe`, not pwsh** — the repo ships no WezTerm config at all,
   so `default_prog` falls back to DOS.

Verified facts from exploration:
- CI (`.github/workflows/windows.yml:100-113`) auto-discovers every `*.ps1.tmpl`
  via `Get-ChildItem -Recurse -Filter *.ps1.tmpl` and render+parse-checks it — a
  renamed/added `.tmpl` needs **no** manual CI list edit.
- `{{ include }}`-into-single-quoted-here-string pattern already exists in
  `.chezmoiscripts/run_onchange_after_20_editor_overlays.ps1.tmpl:10-15`.
- `run_onchange` re-fires when the **rendered** script content changes, so embedding
  the loader via `{{ include }}` makes the redirect re-run whenever the loader edits.
- `$env:XDG_CACHE_HOME` is set in `00_env.ps1:18` (runs before `10_tools.ps1`).
- Loader source is verbatim `Documents/PowerShell/Microsoft.PowerShell_profile.ps1`
  (no `dot_`/`.tmpl`, not in `.chezmoiignore`, no `.chezmoiroot`).

---

## Workstream 1 — OneDrive `$PROFILE` redirect (core)

**Convert** `.chezmoiscripts/run_onchange_after_02_profile_redirect.ps1`
→ `run_onchange_after_02_profile_redirect.ps1.tmpl` (git mv/rename).

Change the write logic (currently `.ps1:47-51`): when `$realFull -ine $managedFull`,
instead of writing a stub that dot-sources `$managedFull`, write the **full managed
loader content** to `$real`, with a marker header line so we can detect our own copy.

- Embed the loader once, mirroring `run_onchange_after_20_editor_overlays.ps1.tmpl:10-15`:
  ```powershell
  $loader = @'
  {{ include "Documents/PowerShell/Microsoft.PowerShell_profile.ps1" }}
  '@
  ```
  Single-quoted here-string is required — the loader contains `$HOME`, `$env:...`,
  `$($fragment.Name)` that must stay literal.
- Written file = marker line + loader body, e.g. first line
  `# Managed by chezmoi (dotfiles-windows) — OneDrive KFM redirect copy. Overrides: ~/.config/powershell/local.ps1`.
- **Keep** the existing once-only backup to
  `~/.dotfiles-backup/Microsoft.PowerShell_profile.ps1.onedrive.bak` and the marker-based
  "is this already our copy?" skip (`.ps1:33-45`) — update the marker string used by both.
- Add an idempotency guard: if `$real` already equals the intended content, skip the
  write (avoid churn; run_onchange already gates cross-apply re-runs).
- No-redirect path (`$realFull -ieq $managedFull`) stays a no-op; chezmoi manages the
  literal file directly. Keep `$ErrorActionPreference='Continue'` + try/catch (never abort).

**Why content, not pointer:** removes all dependency on the literal `~/Documents`
copy existing; eliminates any self-source recursion risk; and (via `{{ include }}`
re-hashing) future loader edits now propagate to the OneDrive copy automatically —
a latent bug the current plain-`.ps1` stub has (it never updates on loader change).

Files: `.chezmoiscripts/run_onchange_after_02_profile_redirect.ps1` (→ `.tmpl`).

---

## Workstream 2 — pwsh startup performance

Primary lever: **cache each tool's init output** to `$XDG_CACHE_HOME/pwsh-init/`,
keyed on the tool exe's `LastWriteTimeUtc` (auto-busts on scoop upgrade), so warm
shells dot-source a static file instead of cold-spawning the binary.

In `dot_config/powershell/profile.d/10_tools.ps1`:
- Add a helper `Import-CachedInit -Name <n> -Exe <exe> -Generate { ... }` at the top:
  resolves the exe, compares its mtime to a saved stamp, regenerates
  `pwsh-init/<n>.ps1` on miss/staleness, then dot-sources it. Guard on
  `Get-Command $Exe`; wrap generation in try/catch (never error the prompt).
- Route the 5 spawns through it:
  - starship (`:5-7`), zoxide (`:10-12`), atuin (`:18-20`), direnv (`:35-37`),
    tv (`:43-47`, keeping the `power-shell`→`powershell` fallback inside the generator).
  These emit **static** init text (no per-session state), so caching is safe.
- Replace `Get-Module -ListAvailable -Name X` (full PSModulePath scan) with direct
  `Import-Module X -ErrorAction SilentlyContinue` + a cheap `Get-Module -Name X`
  (loaded-only) check, in three places: PSFzf (`10_tools.ps1:28-31`),
  Copilot (`40_copilot.ps1:4-8`), PSReadLine (`90_psreadline.ps1.tmpl:3-4`).

Minor / optional (call out, low priority):
- `98_tv_cache.ps1` regenerates `aliases.txt` every start — add a "skip if content
  unchanged" or mtime guard.
- The loader has no interactive gate; a non-interactive early-return is low value
  (chezmoi runs scripts with `-NoProfile`) — leave unless measurement says otherwise.

**Measure first:** 8827 ms is partly first-run cold cost (Defender scanning freshly
downloaded exes + OneDrive hydration). After a couple of warm `Measure-Command { pwsh
-NoLogo -Command exit }` runs, the steady-state number tells us how much caching buys.

Files: `10_tools.ps1`, `40_copilot.ps1`, `90_psreadline.ps1.tmpl`, `98_tv_cache.ps1`.

---

## Workstream 3 — `uv python install --default`

In `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl:190-192`: add `--preview`
(`uv python install --default --preview`) and update the stale comment at `:188`
("Needs uv >= 0.8" → the flag now requires `--preview` on uv 0.8+/0.11+).

Docs mirror (same commit): drop-in the `--preview` form in `docs/tools.md:38`,
`docs/rationale.md:55`, `docs/tools.zh-TW.md:37`, `docs/rationale.zh-TW.md:47-48`.

---

## Workstream 4 — msstore ChatGPT ID (verification-gated)

Confirmed via Store listings: `9NT1R1C2HH7J` = **"ChatGPT Classic"** (fails / not the
app we want), `9PLM9XGG6VKS` = the real OpenAI **"ChatGPT"** (installs). Our script
labels them backwards at `run_onchange_after_10_packages.ps1.tmpl:272-274`.

Recommended change (after a `winget search --source msstore ChatGPT` on the box to
confirm region availability): drop the dead `9NT1R1C2HH7J`, keep `9PLM9XGG6VKS`
relabeled `# ChatGPT (OpenAI)`. Codex CLI is already covered by npm `@openai/codex`
(coding-agents block), so no separate "Codex" Store app is needed — if one is wanted,
look up its live ID rather than reusing `9PLM9XGG6VKS`.

Docs mirror: `docs/tools.md:57-58` + `docs/tools.zh-TW.md:57-58`.

---

## Workstream 5 — OpenSSH server (sshd)  [NEW]

Add an **opt-in, admin-gated, off-by-default** feature to install + enable the
Microsoft OpenSSH Server.

⚠️ **Caveat to confirm:** this opens an inbound listener (TCP 22) and enables a
system service — on a **corporate/managed** machine this may violate security policy
or be blocked. Default the toggle **off**; do not force it on. (Open decision: whether
to also hard-skip when `managedMachine` is true, like Tailscale/Grammarly — leaning
*no*, so you can knowingly opt in on the corp box, but with a printed warning.)

- **New init prompt** in `.chezmoi.toml.tmpl` via `promptBoolOnce`, default `false`.
  Proposed exact text (no `=`, per invariant #1):
  `Install and enable the OpenSSH server / sshd (needs admin, opens inbound port 22)?`
- **New dedicated script** `.chezmoiscripts/run_onchange_after_40_openssh_server.ps1.tmpl`,
  gated `{{ if .installSshServer }}` (separate from the user-scoped package installer
  because it needs admin + touches services/firewall — mirrors the dedicated
  `run_onchange_after_30_windows_terminal.ps1`). Fault-tolerant (`Continue`, never abort):
  - If not elevated (reuse a `Test-Admin` like `bootstrap.ps1:36-42`): print guidance
    to run `just enable-sshd` from an elevated pwsh, then return.
  - `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`
  - `Set-Service sshd -StartupType Automatic; Start-Service sshd`
  - Ensure firewall rule `OpenSSH-Server-In-TCP` (create if missing).
  - Optional: set pwsh as sshd `DefaultShell` (HKLM; admin).
- **`just enable-sshd` recipe** in `justfile` as the elevated fallback (mirrors
  `just upgrade-scoop`), running the same commands.
- **Invariant #1 (same commit):** add `--promptBool "<exact prompt text>=false"` to
  `.github/workflows/windows.yml` init flags, matching the prompt text verbatim.

---

## Workstream 6 — Alacritty Nerd Font (verification-gated)

Root cause (to confirm on the box): Alacritty on Windows enumerates only the
**machine-wide** font collection, so a Nerd Font registered **per-user** by scoop is
invisible to it — while Windows Terminal (which resolves the *same* `Hack Nerd Font
Mono` string, `run_onchange_after_30_windows_terminal.ps1:36`) and WezTerm both see
HKCU fonts. The Alacritty config family string (`alacritty.toml.tmpl:18-21`) is
correct and needs **no** change.

**Diagnose first (Windows box):**
```powershell
[System.Drawing.FontFamily]::Families.Name | Select-String Hack   # exact family name Alacritty would match
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' | Format-List *Hack*
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' | Format-List *Hack*
```
- If `Hack*` appears only under HKCU → confirms the per-user-visibility root cause.
- If the GDI family name differs from `Hack Nerd Font Mono` → instead fix the string.

**Fix (recommended, if HKCU-only):** install Hack-NF-Mono **machine-wide** so Alacritty
sees it. Add an admin-gated step that copies the scoop-installed `.ttf`s
(`~/scoop/apps/Hack-NF-Mono/current/*.ttf`) into `%WINDIR%\Fonts` + registers them in
HKLM (or documents `scoop install -g Hack-NF-Mono`). Fits alongside the W5 admin-gated
script / `just` recipe pattern (e.g. a `just install-fonts-machine-wide` recipe), since
a non-elevated `chezmoi apply` can't write HKLM. Keep it fault-tolerant + opt-in.

Files: (no config change) new admin step/recipe; docs note in `docs/tools.md`/`.zh-TW`.

---

## Workstream 7 — WezTerm config (opens cmd instead of pwsh)  [NEW]

The repo installs WezTerm (`run_onchange_after_10_packages.ps1.tmpl:254`) as the
tmux-like multiplexer but ships **no config**, so it defaults to `cmd.exe`.

Add a managed **`dot_config/wezterm/wezterm.lua`** → `~/.config/wezterm/wezterm.lua`
(WezTerm honors the XDG path on Windows; consistent with starship/yazi placement).
Minimal, mirroring the Alacritty/WT choices:
- `config.default_prog = { 'pwsh.exe', '-NoLogo' }` (pwsh resolves via scoop shims on PATH).
- `config.font = wezterm.font('Hack Nerd Font Mono')` — note WezTerm sees the per-user
  font (unlike Alacritty), so no machine-wide dependency here.
- font size, color scheme (e.g. `One Half Dark` to match WT), tab-bar basics.

Plain `.lua` (no templating needed). New config surface → mention in `docs/tools.md` +
`.zh-TW`, and optionally the skill "Config surfaces" note. Fold WezTerm into the
"editors/terminals" mental model in `AGENTS.md`/`CLAUDE.md` architecture bullet if desired.

Files: new `dot_config/wezterm/wezterm.lua`; docs mirror.

---

## Cross-file mirror / invariant checklist (per CLAUDE.md)

- [ ] W5 new prompt → `.chezmoi.toml.tmpl` + `windows.yml` flag + `docs/setup.md` &
      `docs/setup.zh-TW.md` tables + "What's enabled" block in
      `.chezmoitemplates/dotfiles-windows-skill.md`.
- [ ] W4/W5 installer tools → `docs/tools.md` **and** `docs/tools.zh-TW.md`.
- [ ] W3 docs mirrors (4 files above).
- [ ] W6 (machine-wide font recipe) + W7 (WezTerm) → `docs/tools.md` **and** `docs/tools.zh-TW.md`.
- [ ] `just docs-build --strict` stays green.
- [ ] `pitfalls/onedrive-kfm-profile-not-loaded.md` — record the verbatim
      "not recognized as a name of a cmdlet" symptom + the content-vs-pointer fix.

---

## Verification (all off-Windows-safe unless noted)

1. **Lint:** `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"` (Errors only).
2. **Render+parse the new/renamed `.tmpl`s** using the repo's isolated-apply idiom
   (temp config/state/dest, pass EVERY prompt incl. the new `installSshServer`),
   then `chezmoi execute-template ... < run_onchange_after_02_profile_redirect.ps1.tmpl`
   and parse the output with pwsh — confirm the embedded loader lands verbatim.
3. **Pester:** `pwsh -NoProfile -c "Invoke-Pester -Path ./tests"` (existing Copilot tests still pass).
4. **Docs:** `just docs-build`.
5. **On the Windows box (real gate for W1/W2/W5):**
   - W1: `chezmoi apply`; open a new tab → managed profile loads, no "not recognized" error;
     inspect the OneDrive `$PROFILE` now contains the full loader + marker.
   - W2: warm `Measure-Command { pwsh -NoLogo -Command exit }` before/after; expect the
     init spawns gone from `pwsh-init/` cache hits.
   - W5 (opt-in): elevated `chezmoi apply` or `just enable-sshd`; `Get-Service sshd`
     Running; `ssh localhost` connects.
   - W6: run the diagnostic; after machine-wide font install, launch Alacritty → glyphs render.
   - W7: `chezmoi apply`; launch WezTerm → opens pwsh (not cmd), Nerd Font glyphs render.
6. `windows-latest` CI is the authoritative gate (render+parse + init flags).

---

## Noted, no code change

- **`vi`/`vim` "not recognized":** aliases exist (`20_aliases.ps1:17-20`) but are
  created only if `nvim` resolves at profile-load; on the fresh box nvim was installed
  after that shell started. Self-resolves on next shell / `reload`. `$env:EDITOR` same.
- **gh-dash skipped:** intentional, only when gh is unauthenticated
  (`run_onchange_after_10_packages.ps1.tmpl:179`); not a failure. `gh auth login` then reapply.
- **btop `New-Item ... already exists`:** known-tolerated (invariant #2); install succeeds.
- **Installer has no explicit `exit 0`** (relies on falling off the end). Optional
  hardening: add `exit 0` after the summary block (`:337`) so a late native non-zero
  `$LASTEXITCODE` can't propagate. Low risk; mention but not required.
