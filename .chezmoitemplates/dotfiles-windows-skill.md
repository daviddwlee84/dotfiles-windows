---
name: dotfiles-windows
description: Operate and navigate THIS Windows machine's chezmoi-managed dotfiles (native PowerShell 7). Use when the user asks how to apply/edit/diff dotfiles, where a config or tool lives, how the pwsh $PROFILE / copilot-proxy / scoop+winget install works, how a keybinding or helper (applaunch/sysvol/x/cas) works, or how to use chezmoi / just in this repo.
---

# dotfiles-windows

This machine's `$HOME` is managed by a **chezmoi** dotfiles repo targeting **native
Windows + PowerShell 7**. Packages install via **scoop** (CLI) + **winget** (GUI) —
there is no ansible here. Repo: <https://github.com/daviddwlee84/dotfiles-windows>.
(macOS/Linux/WSL are handled by the separate `daviddwlee84/dotfiles` repo.)

## Orientation
- Source dir: `chezmoi source-path` — edit there (`cd "$(chezmoi source-path)"`).
- Preview / apply: `chezmoi diff` / `chezmoi apply` (or `just diff` / `just apply`).
- Source of a target: `chezmoi source-path <path>`; render without applying: `chezmoi cat <path>`.
- Re-run every init prompt: `chezmoi init --prompt` (answers persist in `~/.config/chezmoi/chezmoi.toml`; bare `chezmoi init` reuses them).
- `docs/**`, `editors/**`, `scripts/**` are chezmoi-ignored (not deployed).

## Shell layout (pwsh)
- `$PROFILE` (`~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`) is a loader
  that dot-sources `~/.config/powershell/profile.d/*.ps1` in sorted order, then
  `~/.config/powershell/local.ps1` (untracked user override, loaded last).
- Fragments: `00_env` (PATH/XDG/env), `10_tools` (starship, zoxide, atuin,
  fzf, direnv, tv, dev/translate completions), `20_aliases` (`ll`/`gs`/`reload`/`cas`/`cau`/`chezmoi-cd`/`run-for`),
  `25_herdr` (`hvibe`/`hcode`/`hhere`/`hroot`/`hmark` workspace helpers, gated on herdr),
  `30_apps` (`applaunch`/`appquit`/`apprestart`/`sysvol`/`sysmute`/`x`), `35_yazi` (`y`),
  `40_copilot` (imports the Copilot module), `90_psreadline` (vi-mode gated on `enableVimMode`).

## Packages
- `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` is the **single source of
  truth** for installs, gated by the init toggles. scoop = CLI tools, winget = GUI
  apps, npm = AI agents, PSGallery = PSFzf/AudioDeviceCmdlets. The coding-agent
  bundle also installs Pi through the shared npm-source policy with
  `--ignore-scripts --no-bin-links`, OMP through the official `-Binary` installer, gitleaks, and
  the chezmoi external at `~/.local/share/pi-agents` that provides `pia`.
  Fault-tolerant: one failed package is collected + reported, never aborts the apply.
- Package sources are defined once in `.chezmoitemplates/package-sources.ps1` and
  reused by the installer and `profile.d/05_mirrors.ps1`: managed machines use
  company PyPI/npm pull-through registries; otherwise the China-mirror toggle
  selects GFW mirrors. Managed policy wins. An independent, default-off public
  fallback retries only eligible repo-owned npm/uv commands once.
- SpecStory uses the official Windows release with SHA-256 verification; it is
  included with coding agents. The legacy `installSpecstoryBuild` key is a
  standalone opt-in, and `just specstory-build` aliases the release upgrade.
- Herdr and herdr-plus temporarily inherit an enabled Windows system proxy when
  no explicit proxy environment exists; registry/source policy is unchanged.
- Install ≠ upgrade: `chezmoi apply` only installs what's missing; upgrade the
  Pi/pia/OMP stack with `just upgrade-agents`, or use the component recipes
  `upgrade-npm-agents` / `upgrade-omp` / `upgrade-pia`.

## copilot-proxy
- Module at `~/.config/powershell/modules/Copilot`. Commands: `copilot-proxy`
  (`start`/`stop`/`restart`/`status`/`doctor`/`logs`/`shim`/`limiter`/`stats`/`events`/`whoami`/`auth`/`reinstall`),
  `copilot-run`, `claude-copilot`, `claude-copilot-once`, `codex-copilot`,
  `codex-copilot-once`, `copilot-here`, `copilot-model` (incl. `--auto`),
  `copilot-embed`, `semsearch`.
- Needs `bun`. Token: `~/.local/share/copilot-api/github_token`. Ports 4141 (proxy) /
  4142 (throttle shim). Default main model `gpt-5.6-sol[1m]`; the OpenAI role
  profile maps Fable/Opus to Sol, Sonnet to Terra, and Haiku/background to Luna.
  Automatic selection excludes policy-disabled, picker-hidden and embedding-only
  entries. Claude `--auto` is Claude-first; Codex is OpenAI-first; both share the
  named OpenAI order Sol > Terra > 5.5 > 5.4 > 5.3 Codex > Luna > mini.
- Claude launchers derive `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from the selected
  model's live `max_prompt_tokens`; `[1m]` remains the separate full-context hint.
- The shim retries only the same buffered request/model, emits SSE keepalives for
  silent streams, and has a stall watchdog; it never performs request-time
  cross-model failover. A request-body `408` gets one bounded replay; policy 422
  passes through without retry. Its adaptive limit starts at `COPILOT_SHIM_MIN=4`, grows
  toward `MAX=8`, and can be tuned live with `copilot-proxy limiter`. Bun stream
  rejections are contained; a ready shim that still crashes gets at most three
  Windows-only recovery attempts (1s/5s/30s) while 4141 remains healthy. Timing
  knobs: `COPILOT_SHIM_PING_AFTER_MS`, `COPILOT_SHIM_PING_MS`,
  `COPILOT_SHIM_STALL_MS`.
- `copilot-here` writes only the gitignored `./.claude/settings.local.json`. The
  pinned copilot-api is installed ONCE into `~/.local/share/copilot-api/pkg`
  (never `bunx` at launch); `COPILOT_HTTP_PROXY` (auto|always|never|URL) controls
  whether Node fetches the GitHub model catalog through the local proxy. Full guide:
  `docs/copilot-proxy.md`.

## Editors / terminal / tv
- VSCode & Cursor settings + keybindings are deep-merged into `%APPDATA%\{Code,Cursor}\User`
  by `.chezmoiscripts/run_onchange_after_20_editor_overlays.ps1.tmpl` (sources under `editors/`).
- Windows Terminal `profiles.defaults`, Alacritty (`%APPDATA%\alacritty\alacritty.toml`),
  and WezTerm (`~/.config/wezterm/wezterm.lua`, pwsh as default shell) are managed too.
  Television channels live under `%APPDATA%\television\cable\` (`tv <name>`).

## What's enabled on THIS machine
- role: **{{ .role }}**
- Coding agents (Pi/pia/OMP included): {{ .installCodingAgents }} · Agent sounds: {{ .agentSounds }} · Standalone SpecStory (also bundled with coding agents): {{ .installSpecstoryBuild }} · GUI apps: {{ .installWindowsApps }} · WSL2 (Docker backend): {{ .installWsl }} · WSL Ubuntu: {{ .installWslUbuntu }} · Utility apps: {{ .installUtilityApps }} · Gaming: {{ .installGamingApps }}
- Extra runtimes: {{ .installExtraRuntimes }} · Media: {{ .installMediaTools }} · LLM: {{ .installLlmTools }} · summarize: {{ .installSummarize }} · Tunnel: {{ .installTunnelTools }} · IaC: {{ .installIacTools }} · OpenSSH: {{ .installSshServer }} · herdr: {{ .installHerdr }} · Clink(cmd): {{ .installClink }} · try: {{ .installTry }} · translate: {{ .installTranslate }} · Rime/Weasel: {{ .installInputMethod }}
- China mirrors: {{ .useChineseMirror }} · Managed machine: {{ .managedMachine }} · Public package fallback: {{ get . "allowPublicPackageFallback" | default false }} · Backup mode: {{ .backupMode }} · Vim mode: {{ .enableVimMode }}

## just recipes
`just --list`: `apply`/`diff`/`update`, `upgrade-scoop`/`upgrade-winget`,
`upgrade-npm-agents`/`upgrade-omp`/`upgrade-pia`/`upgrade-agents`,
`upgrade-dev`/`upgrade-specstory`/`upgrade-translate`/`upgrade-summarize`, `lint`/`test`,
`docs-serve`/`docs-build`, `enable-sshd` (opt-in OpenSSH server, elevated),
`enable-wsl` (WSL2 for Docker Desktop; self-elevating UAC prompt, reboot after),
`enable-wsl-ubuntu` (WSL2 Ubuntu distro + cross-platform dotfiles; needs enable-wsl first),
`wsl-dotfiles` (bootstrap the cross-platform dotfiles into an existing WSL distro; VPN if behind GFW),
`install-fonts-machine-wide` (Alacritty Nerd Font fix, elevated), and
`docker-up`/`docker-down`/`docker-clean`/`docker-logs`
(the x86-Linux+KVM Windows-in-Docker test harness — see `docker/windows/`).

## Gotchas
- Windows-only repo — no `{{ "{{" }} if eq .chezmoi.os {{ "}}" }}` branching needed.
- Editor settings use a `run_onchange` pwsh merger (not `modify_`) on Windows.
- **Pi / pia / OMP ownership**: Pi is the canonical
  `@earendil-works/pi-coding-agent` npm package in Scoop Node's owned prefix,
  installed with `--ignore-scripts --no-bin-links` and exposed through managed
  `pi.cmd` / private `pia-pi.ps1` wrappers; only the exact deprecated
  `@mariozechner/pi-coding-agent` is migrated with rollback. OMP must resolve from
  `%LOCALAPPDATA%\omp\omp.exe` after the official `-Binary` installer and pass a
  direct `--version` probe. `pia` comes from the immutable chezmoi external;
  selection/runtime/session state stays outside that checkout. Native User PATH
  entries are promoted only when their owned executable exists, while explicit
  `PIA_PI_BIN` / `PIA_OMP_BIN` overrides are preserved.
- PowerShell gets an argv-preserving `pi` function. `pi.cmd` is for trusted
  interactive cmd.exe input; automation with arbitrary argv should invoke
  `~/.config/powershell/bin/pia-pi.ps1` with an argument array or use `pia`.
- tmux / zellij are Unix-only and intentionally absent; **WezTerm** (installed) is
  the stable native tmux-like multiplexer, or use Windows Terminal panes. **herdr**
  is an opt-in (`installHerdr`) native-Windows multiplexer in preview beta —
  installed via the hash-verified official herdr.dev installer, config at `~/.config/herdr/config.toml`,
  with its official global skill exported from the installed binary on each apply.
  The same toggle installs the latest verified Windows `dev` release (`prefix+d`)
  and Scoop Go for herdr-plus (`prefix+y` holds six copy helpers; `prefix+p` stays interactive),
  while `prefix+Y` opens Yazi in a temporary pane at the focused pane cwd.
  `prefix+alt+e` edits the existing `HERDR_CONFIG_PATH` target (default
  `~/.config/herdr/config.toml`) directly, validates that exact file, then reloads
  the current server; it never invokes chezmoi. `$env:EDITOR` must name one blocking
  executable or wrapper (put arguments such as `code --wait` in the wrapper); when
  unset, it falls back to nvim and waited Notepad. Editor/validation failure preserves
  a restrictive `config.toml.invalid-*` and restores the prior valid target; reload
  failure keeps the valid edit and backup. A later apply can reassert canonical
  `[theme]`/`[ui]`/`[terminal]`/`[keys]`. Persist changes by manually and selectively
  editing `.chezmoitemplates/herdr/config.toml`; never `chezmoi add`/`re-add` this
  `modify_` target, which can replace/bypass the merger and import runtime-owned state.
  Yazi itself uses the managed `git.yazi` plugin for file/directory status signs;
  `git-guard.yazi` keeps older pre-26.8.15 installs responsive until `just
  upgrade-yazi-plugins` upgrades the matched yazi/ya pair.
  Runtimes are native via scoop (node/bun/go/rust/ruby) + uv for Python — no mise on Windows.
- **Rime input method** (opt-in `installInputMethod`): Weasel/小狼毫 via winget
  `Rime.Weasel`. Machine-scope NSIS, so applying raises UAC; and a bare silent
  install registers **简体** — `Install-Weasel` passes `--custom '/T'` for 繁體.
  The engine-level YAML in `.chezmoitemplates/rime/` is **byte-identical to the
  parent repo's** copy (Squirrel/ibus-rime); only `weasel.custom.yaml` is
  Windows-specific. Edits need a redeploy, which
  `run_onchange_after_50_rime_deploy.ps1` does via `WeaselDeployer.exe /deploy`.
  See `docs/input-method.md`.
- **cmd.exe** is opt-in via `installClink`: Clink + starship/zoxide/fzf give the DOS
  prompt parity for **prompt + navigation only** (no pwsh funcs/aliases/modules).
  `starship.lua` is chezmoi-managed at `%LocalAppData%\clink`; the zoxide/fzf Clink
  bridges are fetched from upstream at apply. pwsh stays the default shell.
- **`translate`** (`installTranslate`, on for workstation) installs from the author's
  own scoop bucket (`scoop bucket add daviddwlee84 …` + `Scoop-Install
  @('daviddwlee84/translate')`) — prebuilt, no version pin in this repo. It used to
  be a version-pinned `go install` into `~\.local\bin`; a leftover
  `~\.local\bin\translate.exe` from that era **shadows the scoop shim** (that dir
  precedes `~\scoop\shims` on PATH), so the script deletes it once the shim exists.
  Upgrade with `just upgrade-translate` (= `scoop update translate`).
- This skill body is shared: `dot_agents/skills/dotfiles-windows/` and
  `dot_claude/skills/dotfiles-windows/` both render `.chezmoitemplates/dotfiles-windows-skill.md`.
