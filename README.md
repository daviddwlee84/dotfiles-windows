# dotfiles-windows

Native **Windows + PowerShell 7** dotfiles, managed by [chezmoi](https://chezmoi.io).
A self-contained, Windows-only companion to my cross-platform (macOS/Linux)
dotfiles — the PowerShell layer is written natively rather than ported from the
POSIX shell config.

> Status: work in progress. See [`docs/`](docs/) for the full handbook (bilingual
> EN / 繁體中文) once built.

## Quick start

From a fresh Windows PowerShell (or pwsh) session:

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

This installs [scoop](https://scoop.sh) (CLI tools) + [winget](https://learn.microsoft.com/windows/package-manager/)
(GUI apps), PowerShell 7, [chezmoi](https://chezmoi.io) and [uv](https://docs.astral.sh/uv/),
then applies the dotfiles.

## What you get

- **Shell**: PowerShell 7 with a modular `$PROFILE` (`~/.config/powershell/profile.d/*.ps1`).
- **Prompt**: [starship](https://starship.rs) (shared config with the macOS/Linux dotfiles).
- **CLI tools** (scoop): git, neovim, lazygit, zoxide, fzf, bat, eza, ripgrep, fd, gh, delta, jq, yazi, btop, mise, uv, node, bun.
- **AI agents**: Claude Code, OpenCode, Codex, GitHub Copilot CLI, SpecStory, Antigravity.
- **Editors**: VSCode, Cursor, Notepad++ (shared settings/keybindings).
- **Apps** (winget): Windows Terminal, Alacritty, Raycast, PowerToys, Steam.
- **`copilot-proxy`** tool series, rewritten as a native PowerShell module.

## Package manager

**scoop for CLIs, winget for GUI apps.** Rationale (why not Chocolatey, why
starship not oh-my-posh, why pwsh not cmd) lives in the docs.

## Layout

| Path | What |
|---|---|
| `.chezmoi.toml.tmpl` | Init prompts (role + feature toggles). |
| `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` loader. |
| `dot_config/powershell/profile.d/` | Modular shell fragments. |
| `dot_config/powershell/modules/Copilot/` | `copilot-proxy` PowerShell module. |
| `dot_config/starship.toml` | Prompt config. |
| `.chezmoiscripts/` | Package install + editor-overlay scripts. |
| `bootstrap.ps1` | One-line installer. |
| `docs/`, `mkdocs.yml` | Bilingual documentation site. |

## Manual dotfiles ops

```powershell
chezmoi diff          # preview changes
chezmoi apply         # apply
just upgrade-scoop     # upgrade CLI tools
just upgrade-winget    # upgrade GUI apps
```
