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
| Steam (gaming) | `Valve.Steam` |

## Utility apps (winget)

Enabled by **Install utility apps**:

| App | winget id | What |
|---|---|---|
| CPU-Z | `CPUID.CPU-Z` | CPU/mainboard info |
| GPU-Z | `TechPowerUp.GPU-Z` | GPU info + sensors |
| HWiNFO | `REALiX.HWiNFO` | full hardware monitoring |
| TreeSize Free | `JAMSoftware.TreeSize.Free` | disk-usage explorer |
| Everything | `voidtools.Everything` | instant filename search |
| ShareX | `ShareX.ShareX` | screenshots + screen recording |
| VLC | `VideoLAN.VLC` | media player |

## AI agents (npm)

`@anthropic-ai/claude-code`, `opencode-ai`, `@openai/codex`, `@github/copilot`,
`@specstory/cli` — installed globally via npm (provided by the mise `node`).

## PowerShell modules (PSGallery)

- **PSFzf** — fzf key bindings (Ctrl+t files, Ctrl+r history).
- **AudioDeviceCmdlets** — absolute volume + mute for the `sysvol`/`sysmute` helpers.

## Upgrades

Install and upgrade are separate. `chezmoi apply` only installs what's missing;
upgrades are explicit:

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
