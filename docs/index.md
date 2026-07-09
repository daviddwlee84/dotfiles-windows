# Windows dotfiles

Native **Windows + PowerShell 7** dotfiles, managed by [chezmoi](https://chezmoi.io).
A self-contained, Windows-only companion to the cross-platform (macOS/Linux)
dotfiles — the PowerShell layer is written natively rather than ported line-by-line
from the POSIX shell config.

## What you get

- **Shell**: PowerShell 7 with a modular `$PROFILE` that dot-sources
  `~/.config/powershell/profile.d/*.ps1`.
- **Prompt**: [starship](https://starship.rs) — the same `starship.toml` used on
  macOS/Linux.
- **CLI tools** via [scoop](https://scoop.sh): git, neovim, lazygit, zoxide, fzf,
  bat, eza, ripgrep, fd, gh, delta, jq, yazi, btop, mise, uv, node, bun.
- **AI agents**: Claude Code, OpenCode, Codex, GitHub Copilot CLI, SpecStory, Antigravity.
- **Editors**: VSCode, Cursor, Notepad++ (shared settings + keybindings).
- **Apps** via [winget](https://learn.microsoft.com/windows/package-manager/):
  Windows Terminal, Alacritty, Raycast, PowerToys, Steam.
- **`copilot-proxy`** tool series, rewritten as a native PowerShell module — see
  [copilot-proxy](copilot-proxy.md).

## Quick start

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

Full walkthrough: [Setup](setup.md). Design choices (why scoop, why starship, why
pwsh): [Rationale](rationale.md).

## How it's organized

| Path | What |
|---|---|
| `.chezmoi.toml.tmpl` | Init prompts (role + feature toggles). |
| `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` loader. |
| `dot_config/powershell/profile.d/` | Modular shell fragments. |
| `dot_config/powershell/modules/Copilot/` | `copilot-proxy` module. |
| `.chezmoiscripts/` | Package install + editor/terminal overlays. |
| `bootstrap.ps1` | One-line installer. |

!!! note "Scope"
    This repo targets native Windows only. WSL is covered by the separate
    cross-platform dotfiles (it's just another Linux host there).
