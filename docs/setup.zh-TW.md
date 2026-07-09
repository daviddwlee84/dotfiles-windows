# 安裝

## 一行安裝

在全新的 Windows PowerShell（或 PowerShell 7）視窗執行：

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/windows-dotfiles/main/bootstrap.ps1 | iex
```

`bootstrap.ps1` 會依序（且可重複執行）完成：

1. 將目前使用者的 execution policy 設為 `RemoteSigned`。
2. 安裝 [scoop](https://scoop.sh)（使用者層級、免系統管理員）。
3. 透過 scoop 安裝 `git`、PowerShell 7（`pwsh`）、`chezmoi`、`uv`。
4. 若是從 Windows PowerShell 5.1 啟動，會改用 `pwsh` 重新執行。
5. 對此 repo 執行 `chezmoi init --apply`。

## 初始化提問

`chezmoi init` 只會問一次（答案會被記住，不再重複問）：

| 提問 | 預設 | 意義 |
|---|---|---|
| Role | `workstation` | `workstation` = 完整桌面；`minimal` = 只有 shell |
| Coding agents | 開（workstation） | Claude Code、OpenCode、Codex、Copilot CLI、SpecStory |
| Windows GUI apps | 開（workstation） | VSCode、Cursor、Notepad++、Terminal、Alacritty、PowerToys、Raycast |
| Gaming apps | 關 | Steam |
| Extra runtimes | 開（workstation） | 透過 mise 安裝 rust、go、ruby（node/bun/uv 為基本內建） |
| Media CLIs | 關 | ffmpeg、imagemagick |
| PSReadLine vi mode | 開 | shell 的 vi 編輯模式 |

之後可再次執行 `chezmoi init` 重新提問，或直接編輯
`%USERPROFILE%\.config\chezmoi\chezmoi.toml`。

## 日常操作

```powershell
chezmoi diff          # 預覽即將套用的變更
chezmoi apply         # 套用
chezmoi update        # git pull 後套用
just upgrade-scoop     # 升級 CLI 工具
just upgrade-winget    # 升級 GUI 應用程式
```

## 本機覆寫

把機器專屬的調整或機密放在 `~/.config/powershell/local.ps1` —— 它會被 `$PROFILE`
最後 dot-source，且永遠不受 chezmoi 管理。

## Raycast 與 PowerToys 的衝突

Raycast 與 PowerToys Run 的啟動器預設都用 **Alt+Space**。請擇一：關閉 PowerToys Run
（PowerToys 設定 → PowerToys Run → 關）或改綁它的快捷鍵。安裝腳本會印出提醒。
