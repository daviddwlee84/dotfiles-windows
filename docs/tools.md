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
| mise | runtime version manager |
| uv | Python package/runtime manager |
| just | task runner (this repo's `justfile`) |
| make | GNU make |
| zig | C compiler for Neovim tree-sitter parsers |
| win32yank | clipboard provider for Neovim |

Runtimes: `node@lts` + `bun` are installed via mise as a baseline (the npm-based
coding agents need node). `rust`, `go`, `ruby` are added when **Extra runtimes**
is enabled.

## GUI apps (winget)

| App | winget id |
|---|---|
| VSCode | `Microsoft.VisualStudioCode` |
| Cursor | `Anysphere.Cursor` |
| Notepad++ | `Notepad++.Notepad++` |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Alacritty | `Alacritty.Alacritty` |
| PowerToys | `Microsoft.PowerToys` |
| Flow Launcher | `Flow-Launcher.Flow-Launcher` |
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
    [Flow Launcher](https://www.flowlauncher.com/) is the default keyboard
    launcher (reliable on x64 **and** ARM64). **Raycast for Windows** is a
    Microsoft Store beta with a finicky winget id, so it's opt-in:
    `winget install raycast`. Flow Launcher, Raycast, and **PowerToys Run** all
    default to **Alt+Space** — pick one and rebind or disable the others.

## AI agents (npm)

`@anthropic-ai/claude-code`, `opencode-ai`, `@openai/codex`, `@github/copilot`
— installed globally via npm (provided by the mise `node`). The official
**ChatGPT** and **Codex** desktop apps install via the Microsoft Store (see GUI
apps). SpecStory has no native-Windows CLI package, so it's omitted here.

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

## Upgrades

Install and upgrade are separate. `chezmoi apply` only installs what's missing;
upgrades are explicit:

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
