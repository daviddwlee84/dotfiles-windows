# Tools

The install set lives in `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
(the single source of truth), gated by the init toggles. **scoop** handles CLI
tools; **winget** handles GUI apps.

## CLI tools (scoop)

| Tool | Purpose |
|---|---|
| git, gh | version control + GitHub CLI |
| neovim | editor (LazyVim, pre-configured) |
| lazygit | git TUI (delta pager configured) |
| zoxide | smarter `cd` |
| fzf, fd, ripgrep | fuzzy find / file search / grep |
| bat, eza | `cat` / `ls` replacements |
| delta | git diff pager |
| jq | JSON processor |
| yazi, btop | file manager / system monitor |
| television (`tv`) | fuzzy picker / channel launcher |
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
`uv python install --default` puts `python`/`python3` in `~/.local/bin` (on PATH
ahead of the Store's `python.exe` app-alias), so `python`, `uv run`, and
`uv venv` all work without the Microsoft Store.

## GUI apps (winget)

| App | winget id |
|---|---|
| VSCode | `Microsoft.VisualStudioCode` |
| Cursor | `Anysphere.Cursor` |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Alacritty | `Alacritty.Alacritty` |
| WezTerm | `wez.wezterm` (built-in tmux-like multiplexer) |
| PowerToys | `Microsoft.PowerToys` |
| Raycast | `9PFXXSHC64H3` (msstore) |
| Antigravity | `Google.Antigravity` |
| Docker Desktop | `Docker.DockerDesktop` |
| Discord | `Discord.Discord` |
| Claude Desktop | `Anthropic.Claude` |
| ChatGPT | `9NT1R1C2HH7J` (msstore) |
| Codex | `9PLM9XGG6VKS` (msstore) |
| Chrome | `Google.Chrome` |
| Arc | `TheBrowserCompany.Arc` |
| Zen Browser | `Zen-Team.Zen-Browser` |
| Grammarly | `Grammarly.Grammarly` |
| Steam (gaming) | `Valve.Steam` |

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

## AI agents (npm)

`@anthropic-ai/claude-code`, `opencode-ai`, `@openai/codex`, `@github/copilot`
— installed globally via npm (provided by the scoop `node`). **OpenCode Desktop**
(GUI companion to the `opencode-ai` CLI) installs via scoop (`extras/opencode-desktop`).
The official **ChatGPT** and **Codex** desktop apps install via the Microsoft
Store (see GUI apps). SpecStory has no native-Windows CLI package, so it's
omitted here.

## PowerShell modules (PSGallery)

- **PSFzf** — fzf key bindings (Ctrl+t files, Ctrl+r history).
- **AudioDeviceCmdlets** — absolute volume + mute for the `sysvol`/`sysmute` helpers.

## Opt-in dev stacks

Off by default; enable the matching init prompt:

| Toggle | Installs |
|---|---|
| Local LLM tools | Ollama (`Ollama.Ollama`) + LiteLLM (`uv tool install 'litellm[proxy]'`) |
| Tunnel tools | ngrok, cloudflared (scoop) |
| IaC tools | Terraform, OpenTofu (scoop) + Azure CLI (winget) |

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
