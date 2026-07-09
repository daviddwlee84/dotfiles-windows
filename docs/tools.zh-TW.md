# 工具索引

安裝清單在 `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
（單一事實來源），並由初始化開關控制。**scoop** 負責 CLI 工具；**winget** 負責
GUI 應用程式。

## CLI 工具（scoop）

| 工具 | 用途 |
|---|---|
| git、gh | 版本控制 + GitHub CLI |
| neovim | 編輯器（可搭 LazyVim） |
| lazygit | git TUI |
| zoxide | 更聰明的 `cd` |
| fzf、fd、ripgrep | 模糊搜尋 / 找檔案 / grep |
| bat、eza | `cat` / `ls` 替代品 |
| delta | git diff 分頁器 |
| jq | JSON 處理器 |
| yazi、btop | 檔案管理員 / 系統監控 |
| starship | 提示字元 |
| mise | runtime 版本管理器 |
| uv | Python 套件/runtime 管理器 |

Runtime：`node@lts` + `bun` 由 mise 安裝為基本內建（npm-based 的 coding agents 需要
node）。啟用 **Extra runtimes** 時才會加裝 `rust`、`go`、`ruby`。

## GUI 應用程式（winget）

| 應用程式 | winget id |
|---|---|
| VSCode | `Microsoft.VisualStudioCode` |
| Cursor | `Anysphere.Cursor` |
| Notepad++ | `Notepad++.Notepad++` |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Alacritty | `Alacritty.Alacritty` |
| PowerToys | `Microsoft.PowerToys` |
| Raycast | `Raycast.Raycast` |
| Antigravity | `Google.Antigravity` |
| Steam（gaming） | `Valve.Steam` |

## AI agents（npm）

`@anthropic-ai/claude-code`、`opencode-ai`、`@openai/codex`、`@github/copilot`、
`@specstory/cli` —— 透過 npm 全域安裝（由 mise 的 `node` 提供）。

## PowerShell 模組（PSGallery）

- **PSFzf** —— fzf 快捷鍵（Ctrl+t 找檔案、Ctrl+r 歷史）。
- **AudioDeviceCmdlets** —— 提供 `sysvol`/`sysmute` 的絕對音量與靜音控制。

## 升級

安裝與升級刻意分開。`chezmoi apply` 只安裝缺少的東西；升級要明確執行：

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
