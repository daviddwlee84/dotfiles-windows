# Windows dotfiles

原生 **Windows + PowerShell 7** dotfiles，由 [chezmoi](https://chezmoi.io) 管理。
這是跨平台（macOS/Linux）dotfiles 的獨立 Windows 版本 —— PowerShell 層是用原生方式
撰寫，而非把 POSIX shell 設定逐行硬翻過來。

## 你會得到

- **Shell**：PowerShell 7，模組化的 `$PROFILE` 會 dot-source
  `~/.config/powershell/profile.d/*.ps1`。
- **提示字元（prompt）**：[starship](https://starship.rs) —— 與 macOS/Linux 共用
  同一份 `starship.toml`。
- **CLI 工具**（透過 [scoop](https://scoop.sh)）：git、neovim、lazygit、zoxide、
  fzf、bat、eza、ripgrep、fd、gh、delta、jq、yazi、btop、mise、uv、node、bun。
- **AI agents**：Claude Code、OpenCode、Codex、GitHub Copilot CLI、SpecStory、Antigravity。
- **編輯器**：VSCode、Cursor、Notepad++（共用 settings 與 keybindings）。
- **應用程式**（透過 [winget](https://learn.microsoft.com/windows/package-manager/)）：
  Windows Terminal、Alacritty、Raycast、PowerToys、Steam。
- **`copilot-proxy`** 工具系列，改寫為原生 PowerShell 模組 —— 見
  [copilot-proxy](copilot-proxy.md)。

## 快速開始

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

完整步驟：[安裝](setup.md)。設計取捨（為何用 scoop、starship、pwsh）：
[設計取捨](rationale.md)。

## 專案結構

| 路徑 | 說明 |
|---|---|
| `.chezmoi.toml.tmpl` | 初始化提問（role + 功能開關）。 |
| `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` 載入器。 |
| `dot_config/powershell/profile.d/` | 模組化 shell 片段。 |
| `dot_config/powershell/modules/Copilot/` | `copilot-proxy` 模組。 |
| `.chezmoiscripts/` | 套件安裝 + 編輯器/終端機 overlay。 |
| `bootstrap.ps1` | 一行安裝指令。 |

!!! note "範圍"
    此 repo 只針對原生 Windows。WSL 由另一份跨平台 dotfiles 處理（在那裡它只是
    另一台 Linux 主機）。
