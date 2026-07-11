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
- Re-run init prompts: `chezmoi init` (answers persist in `~/.config/chezmoi/chezmoi.toml`).
- `docs/**`, `editors/**`, `scripts/**` are chezmoi-ignored (not deployed).

## Shell layout (pwsh)
- `$PROFILE` (`~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`) is a loader
  that dot-sources `~/.config/powershell/profile.d/*.ps1` in sorted order, then
  `~/.config/powershell/local.ps1` (untracked user override, loaded last).
- Fragments: `00_env` (PATH/XDG/env), `10_tools` (starship, zoxide, atuin,
  fzf, direnv, tv), `20_aliases` (`ll`/`gs`/`reload`/`cas`/`cau`/`chezmoi-cd`/`run-for`),
  `30_apps` (`applaunch`/`appquit`/`apprestart`/`sysvol`/`sysmute`/`x`), `35_yazi` (`y`),
  `40_copilot` (imports the Copilot module), `90_psreadline` (vi-mode gated on `enableVimMode`).

## Packages
- `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` is the **single source of
  truth** for installs, gated by the init toggles. scoop = CLI tools, winget = GUI
  apps, npm = AI agents, PSGallery = PSFzf/AudioDeviceCmdlets. Fault-tolerant: one
  failed package is collected + reported, never aborts the apply.
- Install ≠ upgrade: `chezmoi apply` only installs what's missing; upgrade via
  `just upgrade-scoop` / `just upgrade-winget`.

## copilot-proxy
- Module at `~/.config/powershell/modules/Copilot`. Commands: `copilot-proxy`
  (`start`/`stop`/`restart`/`status`/`doctor`/`logs`/`shim`/`whoami`/`auth`),
  `copilot-run`, `claude-copilot`, `claude-copilot-once`, `copilot-here`,
  `copilot-model`, `copilot-embed`, `semsearch`.
- Needs `bun`. Token: `~/.local/share/copilot-api/github_token`. Ports 4141 (proxy) /
  4142 (throttle shim). Default model `claude-opus-4-8[1m]`. `copilot-here` writes
  only the gitignored `./.claude/settings.local.json`. Full guide: `docs/copilot-proxy.md`.

## Editors / terminal / tv
- VSCode & Cursor settings + keybindings are deep-merged into `%APPDATA%\{Code,Cursor}\User`
  by `.chezmoiscripts/run_onchange_after_20_editor_overlays.ps1.tmpl` (sources under `editors/`).
- Windows Terminal `profiles.defaults`, Alacritty (`%APPDATA%\alacritty\alacritty.toml`),
  and WezTerm (`~/.config/wezterm/wezterm.lua`, pwsh as default shell) are managed too.
  Television channels live under `%APPDATA%\television\cable\` (`tv <name>`).

## What's enabled on THIS machine
- role: **{{ .role }}**
- Coding agents: {{ .installCodingAgents }} · GUI apps: {{ .installWindowsApps }} · Utility apps: {{ .installUtilityApps }} · Gaming: {{ .installGamingApps }}
- Extra runtimes: {{ .installExtraRuntimes }} · Media: {{ .installMediaTools }} · LLM: {{ .installLlmTools }} · Tunnel: {{ .installTunnelTools }} · IaC: {{ .installIacTools }} · OpenSSH: {{ .installSshServer }} · herdr: {{ .installHerdr }}
- China mirrors: {{ .useChineseMirror }} · Backup mode: {{ .backupMode }} · Vim mode: {{ .enableVimMode }} · Managed machine: {{ .managedMachine }}

## just recipes
`just --list`: `apply`/`diff`/`update`, `upgrade-scoop`/`upgrade-winget`, `lint`/`test`,
`docs-serve`/`docs-build`, `enable-sshd` (opt-in OpenSSH server, elevated),
`install-fonts-machine-wide` (Alacritty Nerd Font fix, elevated), and
`docker-up`/`docker-down`/`docker-clean`/`docker-logs`
(the x86-Linux+KVM Windows-in-Docker test harness — see `docker/windows/`).

## Gotchas
- Windows-only repo — no `{{ "{{" }} if eq .chezmoi.os {{ "}}" }}` branching needed.
- Editor settings use a `run_onchange` pwsh merger (not `modify_`) on Windows.
- tmux / zellij are Unix-only and intentionally absent; **WezTerm** (installed) is
  the stable native tmux-like multiplexer, or use Windows Terminal panes. **herdr**
  is an opt-in (`installHerdr`) native-Windows multiplexer in preview beta —
  installed via herdr.dev's `irm|iex` script, config at `~/.config/herdr/config.toml`.
  Runtimes are native via scoop (node/bun/go/rust/ruby) + uv for Python — no mise on Windows.
- This skill body is shared: `dot_agents/skills/dotfiles-windows/` and
  `dot_claude/skills/dotfiles-windows/` both render `.chezmoitemplates/dotfiles-windows-skill.md`.
