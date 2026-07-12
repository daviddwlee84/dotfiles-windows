# Tools

The install set lives in `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
(the single source of truth), gated by the init toggles. **scoop** handles CLI
tools; **winget** handles GUI apps.

## CLI tools (scoop)

| Tool | Purpose |
|---|---|
| git, gh, glab | version control + GitHub / GitLab CLIs |
| neovim | editor (LazyVim, pre-configured) |
| lazygit | git TUI (delta pager configured) |
| zoxide | smarter `cd` |
| fzf, fd, ripgrep | fuzzy find / file search / grep |
| bat, eza | `cat` / `ls` replacements |
| delta | git diff pager |
| jq | JSON processor |
| yazi, btop | file manager / system monitor |
| television (`tv`) | fuzzy picker / channel launcher |
| tldr (tlrc) | community man-page cheatsheets; `tldrf` adds `zh_TW → zh → en` fallback |
| gh dash | GitHub PR/issue dashboard TUI (gh extension; installs once `gh` is authenticated) |
| starship | prompt |
| node | JS runtime (`nodejs-lts`) |
| uv | Python package/runtime manager |
| bun | JS runtime + package manager (backs copilot-proxy) |
| just | task runner (this repo's `justfile`) |
| make | GNU make |
| zig | C compiler for Neovim tree-sitter parsers |
| gcc | amd64 C compiler (**ARM64 hosts only** — matches the x64-emulated nvim) |
| tree-sitter | tree-sitter CLI (nvim-treesitter `main` branch) |
| win32yank | clipboard provider for Neovim |
| gnupg | `gpg` (git commit signing, verification) |

Runtimes are **native (scoop), not mise** — see [rationale](rationale.md#runtimes-scoop-natives-not-mise-on-windows).
`node` (`nodejs-lts`) and `bun` come from scoop; `go`, `rust` (rustup), `ruby`
are added when **Extra runtimes** is enabled. A default **Python** is uv-managed:
`uv python install --default --preview` puts `python`/`python3` in `~/.local/bin`
(on PATH ahead of the Store's `python.exe` app-alias), so `python`, `uv run`, and
`uv venv` all work without the Microsoft Store.

## GUI apps (winget)

| App | winget id |
|---|---|
| VSCode | `Microsoft.VisualStudioCode` |
| Cursor | `Anysphere.Cursor` |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Alacritty | `Alacritty.Alacritty` |
| WezTerm | `wez.wezterm` (tmux-like multiplexer; managed `~/.config/wezterm/wezterm.lua` sets pwsh as the shell + Nerd Font) |
| PowerToys | `Microsoft.PowerToys` |
| Raycast | `9PFXXSHC64H3` (msstore) |
| Antigravity | `Google.Antigravity` |
| Docker Desktop | `Docker.DockerDesktop` (WSL2 backend via the `installWsl` toggle — see below) |
| Discord | `Discord.Discord` |
| Claude Desktop | `Anthropic.Claude` |
| ChatGPT | `9PLM9XGG6VKS` (msstore) |
| Chrome | `Google.Chrome` |
| Arc | `TheBrowserCompany.Arc` |
| Zen Browser | `Zen-Team.Zen-Browser` |
| Grammarly | `Grammarly.Grammarly` |
| Steam (gaming) | `Valve.Steam` |

**Docker Desktop's WSL2 backend** (`installWsl` toggle, on for workstation) is set up
by `scripts/enable-wsl.ps1` via `wsl --install --no-distribution` — only the WSL2
platform, not a Linux distro (Docker creates its own `docker-desktop` distro).
`wsl --install` needs admin **and** a reboot, so a non-elevated `chezmoi apply`
self-elevates with a single UAC prompt (like scoop), runs the install, then prints a
restart notice — reboot, then Docker Desktop starts on the WSL2 backend. Re-run or
retry (e.g. if the UAC prompt was declined) with `just enable-wsl`. Already-installed
machines are a no-op (no UAC). On a proxy / corporate / GFW network where the WSL app
download is reset ("connection reset"), the script falls back to enabling the WSL2
features **offline via DISM** and points at the kernel MSI + `wsl --update`. WSL as a
*Linux shell* stays out of scope — see
[rationale](rationale.md#powershell-7-default-cmdexe-optional-via-clink).

**Unattended WSL Ubuntu + dotfiles** (`installWslUbuntu`, off by default) goes further:
`scripts/enable-wsl-ubuntu.ps1` registers `Ubuntu-24.04` with **no OOBE** (creates your
user via `wsl -u root`, passwordless sudo, WSL auto-login), then — in the default
`headless` mode — runs a **frozen-from-Windows** chezmoi one-liner that installs the
cross-platform dotfiles (`daviddwlee84/dotfiles`, `ubuntu_server` profile) with no
prompts inside WSL. `wslUbuntuBootstrap` can instead be `interactive` (the parent repo's
prompts on first login) or `none` (set up the distro only). Requires the WSL2 platform
(`installWsl`) + its reboot first; run or retry with `just enable-wsl-ubuntu`. Linux GUI
apps work out of the box via **WSLg** if you later switch the frozen profile to
`ubuntu_desktop`. This is an opt-in *bridge* — the Linux config lives in the
cross-platform repo, not here.

## Utility apps (winget)

Enabled by **Install utility apps**:

| App | winget id | What |
|---|---|---|
| CPU-Z | `CPUID.CPU-Z` | CPU/mainboard info |
| GPU-Z | `TechPowerUp.GPU-Z` | GPU info + sensors |
| HWiNFO | `REALiX.HWiNFO` | full hardware monitoring |
| TreeSize Free | `JAMSoftware.TreeSize.Free` | disk-usage explorer |
| WinDirStat | `WinDirStat.WinDirStat` | disk-usage treemap |
| Everything | `voidtools.Everything` | instant filename search |
| ShareX | `ShareX.ShareX` | screenshots + screen recording |
| OBS Studio | `OBSProject.OBSStudio` | screen recording / streaming |
| VLC | `VideoLAN.VLC` | media player |
| Rufus | `Rufus.Rufus` | bootable USB creator |
| Tailscale | `Tailscale.Tailscale` | mesh VPN |

!!! note "Launchers & the Alt+Space clash"
    **Raycast** (Microsoft Store, id `9PFXXSHC64H3`) is the default launcher.
    It shares **Alt+Space** with **PowerToys Run** — disable PowerToys Run
    (PowerToys Settings › PowerToys Run › off) or rebind one. Raycast for Windows
    is still a Store beta; if it won't install, fall back to
    [Flow Launcher](https://www.flowlauncher.com/):
    `winget install Flow-Launcher.Flow-Launcher`.

!!! note "Notepad++ is opt-in"
    Dropped from the default set: on Windows-on-ARM its installer is a
    low-reputation binary that Windows Defender / SmartScreen flags as PUA
    (a false positive, aggravated by managed-machine PUA protection), and it's
    redundant with VSCode / Cursor / nvim. Add it yourself if you want it:
    `winget install Notepad++.Notepad++` or `scoop install notepadplusplus`.

!!! note "Managed / corporate machines"
    The **Managed machine** init toggle skips apps that org policy commonly
    blocks — **Grammarly** and **Tailscale** (its MSI fails with exit `1625`
    under policy). Leave the toggle off on a personal machine to install them.

!!! note "Alacritty & Nerd Fonts (machine-wide install)"
    scoop's `nerd-fonts` bucket registers **Hack Nerd Font Mono** *per-user*
    (HKCU). Windows Terminal and WezTerm see per-user fonts, but **Alacritty on
    Windows reads only the machine-wide font collection**, so it can't find the
    font and falls back to a default. Fix (needs admin):
    `just install-fonts-machine-wide` (runs `scoop install -g Hack-NF-Mono Hack-NF`),
    then restart Alacritty. Diagnose the family name with
    `[System.Drawing.FontFamily]::Families.Name | Select-String Hack`.

## AI agents

Enabled by **Install coding agents**:

- **Claude Code** — `Anthropic.ClaudeCode` via **winget** (the native Windows
  build; distinct from `Anthropic.Claude`, the desktop app under GUI apps).
  Upgraded with `just upgrade-winget`, not npm.
- **OpenCode** (`opencode-ai`), **Codex** (`@openai/codex`), **Copilot CLI**
  (`@github/copilot`) — installed globally via **npm** (provided by the scoop `node`).
- **OpenCode Desktop** — GUI companion to the `opencode-ai` CLI, via scoop
  (`extras/opencode-desktop`).
- **claude-hud** — a statusline HUD that renders below the Claude Code prompt.
  Enabled in `~/.claude/settings.json` by a `run_onchange` merger
  (`.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`) that
  additively deep-merges an overlay, preserving your live settings. The plugin
  self-installs from its marketplace on first launch and runs on the scoop
  `bun`/`node` runtime; the merger also enables the `pyright-lsp` plugin and sets
  `permissions.defaultMode: auto` + `skipDangerousModePermissionPrompt`. **Restart
  Claude Code** after `chezmoi apply` to see the HUD. See
  [running multiple agents](claude-code-agents.md).

The official **ChatGPT** desktop app installs via the Microsoft Store (see GUI
apps); **Codex** is the `@openai/codex` npm CLI above, not a Store app. SpecStory
has no native-Windows CLI package, so it's omitted here.

## PowerShell modules (PSGallery)

- **PSFzf** — fzf key bindings (Ctrl+t files, Ctrl+r history).
- **AudioDeviceCmdlets** — absolute volume + mute for the `sysvol`/`sysmute` helpers.

## Opt-in dev stacks

Off by default; enable the matching init prompt:

| Toggle | Installs |
|---|---|
| Local LLM tools | Ollama (`Ollama.Ollama`) + LiteLLM (`uv tool install 'litellm[proxy]'`) |
| Tunnel tools | ngrok, cloudflared (scoop) |
| IaC tools | Terraform, OpenTofu (scoop) + Azure CLI & the `azure-devops` extension (`az devops`/`az repos`, winget) |
| OpenSSH server | Microsoft OpenSSH Server (sshd): Windows capability + auto-start service + inbound TCP 22 firewall rule, with pwsh as the default shell. Needs admin — set up on an elevated `chezmoi apply`, or run `just enable-sshd` from an elevated pwsh. |
| herdr multiplexer | herdr, a native Windows terminal multiplexer (**preview beta**). No scoop/winget manifest — installs via herdr.dev's `irm \| iex` script; config managed at `~/.config/herdr/config.toml` (pwsh as the default shell). See [rationale](rationale.md#terminal-multiplexer-wezterm-stable-default-herdr-native-beta). |
| Clink (cmd.exe) | [Clink](https://chrisant996.github.io/clink/) (scoop `main`) — Bash-style line editing for `cmd.exe`, so **starship** + **zoxide** + **fzf** work in the DOS prompt. Reuses the shared `starship.toml`; registers a per-user cmd AutoRun, deploys our `starship.lua`, and fetches the community `clink-zoxide` / `clink-fzf` bridges into `%LocalAppData%\clink`. pwsh stays the default — this is an opt-in secondary shell with prompt + nav parity only. See [rationale](rationale.md#powershell-7-default-cmdexe-optional-via-clink) & [Shell](shell.md#cmdexe-via-clink). |

**China mirrors** routes pip / npm / cargo / go / node package fetches through GFW
mirrors (Tsinghua / npmmirror / goproxy.cn / rsproxy), applied both at install time
and in the interactive shell (`profile.d/05_mirrors.ps1`).

## Television (tv) channels

Custom pickers under `%APPDATA%\television\cable\` (run `tv` to browse, or `tv <name>`):

| Channel | What |
|---|---|
| `aliases` | PowerShell aliases & functions (cached at shell startup) |
| `git-ops` | common git commands → Enter copies to clipboard |
| `ports` | listening TCP ports → Ctrl+K kills the owning process |
| `kill-process` | processes by memory → Enter/Ctrl+K kill, Ctrl+D force-kill |
| `scoop-apps` | installed scoop apps → Enter info, Ctrl+U update, Ctrl+X uninstall |
| `apps` | launch an app from Start Menu shortcuts |
| `channels` | browse every tv channel by description → Enter opens the selected one |

## Upgrades

Install and upgrade are separate. `chezmoi apply` only installs what's missing;
upgrades are explicit:

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
