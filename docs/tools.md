# Tools

The install set lives in `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
(the single source of truth), gated by the init toggles. **scoop** handles CLI
tools; **winget** handles GUI apps.

## CLI tools (scoop)

| Tool | Purpose |
|---|---|
| git, gh | version control + GitHub CLI |
| neovim | editor (LazyVim-ready) |
| lazygit | git TUI |
| zoxide | smarter `cd` |
| fzf, fd, ripgrep | fuzzy find / file search / grep |
| bat, eza | `cat` / `ls` replacements |
| delta | git diff pager |
| jq | JSON processor |
| yazi, btop | file manager / system monitor |
| starship | prompt |
| mise | runtime version manager |
| uv | Python package/runtime manager |

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
| Raycast | `Raycast.Raycast` |
| Antigravity | `Google.Antigravity` |
| Docker Desktop | `Docker.DockerDesktop` |
| Discord | `Discord.Discord` |
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
| Tailscale | `tailscale.tailscale` | mesh VPN |

!!! note "Flow Launcher"
    [Flow Launcher](https://www.flowlauncher.com/) (`Flow-Launcher.Flow-Launcher`)
    is a good keyboard launcher, but it defaults to **Alt+Space** — the same hotkey
    as Raycast and PowerToys Run. It's left out of the default set to avoid a
    three-way clash; add it (and pick one launcher) if you prefer it over Raycast.

## AI agents (npm)

`@anthropic-ai/claude-code`, `opencode-ai`, `@openai/codex`, `@github/copilot`,
`@specstory/cli` — installed globally via npm (provided by the mise `node`).

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

## Upgrades

Install and upgrade are separate. `chezmoi apply` only installs what's missing;
upgrades are explicit:

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
