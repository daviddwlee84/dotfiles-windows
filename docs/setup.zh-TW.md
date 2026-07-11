# 安裝

## 一行安裝

在全新的 Windows PowerShell（或 PowerShell 7）視窗執行：

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

也可以從 **cmd.exe** 執行 —— 不需要維護原生 cmd 版 bootstrap，直接交棒給內建的
**Windows PowerShell（5.1）**（每台 Windows 都有）。先啟動它，再互動式執行那行：

```bat
powershell
```
```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

或把腳本下載下來、看過內容、再執行**檔案**（比較安全，也能避開下面那個 Defender 警告）：

```bat
powershell -Command "irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 -OutFile $env:TEMP\bootstrap.ps1"
notepad "%TEMP%\bootstrap.ps1"
powershell -ExecutionPolicy Bypass -File "%TEMP%\bootstrap.ps1"
```

用 `powershell`，**不是** `pwsh` —— 全新機器上 pwsh 還沒裝。bootstrap 邏輯只維護一份、
寫在 PowerShell（`bootstrap.ps1`）：elevation / `PATH` / `chezmoi` 這些步驟用 cmd 寫
會又醜又易錯，而且這份 dotfiles 本來就是 PowerShell，一台完全沒有 PowerShell 的機器
本來就用不了這個 repo。

!!! warning "Defender 可能把 cmd 的 irm|iex 一行版當成 ClickFix"
    把 cradle 包成 cmd 命令列 ——
    `powershell -ExecutionPolicy Bypass -Command "irm <url> | iex"` —— 可能觸發
    Defender 的 **`Trojan:Win32/ClickFix.*!ml`** 機器學習啟發式偵測。這是對**命令列
    「形狀」的誤判**，不是我們的腳本有問題（內容掃描是乾淨的）：一個 `powershell`
    行程的命令列是遠端 download-cradle（`irm|iex`）再加上 `-ExecutionPolicy Bypass` /
    `-NoProfile`，正是
    [ClickFix](https://www.microsoft.com/en-us/security/blog/2025/08/21/think-before-you-clickfix-analyzing-the-clickfix-social-engineering-technique/)
    假 CAPTCHA 攻擊用的形狀。上面兩種寫法都能避開 —— cradle 不會落在行程命令列上，或
    改成執行檔案 —— 而在**已經開著的 PowerShell 裡**跑那行是沒問題的。更重要的教訓：
    **絕對不要貼上任何網頁或「驗證你是真人」提示塞給你的 `powershell -c "irm|iex"`
    —— 那個要求本身就是攻擊。**

`bootstrap.ps1` 會依序（且可重複執行）完成：

1. 將目前使用者的 execution policy 設為 `RemoteSigned`。
2. 安裝 [scoop](https://scoop.sh)（使用者層級、免系統管理員 —— 但若 shell 本身是
   系統管理員身分，會自動帶上 `-RunAsAdmin`；否則安裝程式會以
   *「Running the installer as administrator is disabled by default」* 拒絕執行）。
3. 透過 scoop 安裝 `git`、PowerShell 7（`pwsh`）、`chezmoi`、`uv`。
4. 從 registry 重新載入 `PATH`，讓剛裝好的 scoop shim（`chezmoi`、`pwsh`、`uv`）
   在同一個 session 就能被找到。
5. 執行 `chezmoi init --apply`（若 source 已經 clone 過則改用 `chezmoi update`）
   —— chezmoi 會透過 `[interpreters.ps1]` 自己用 pwsh 跑 repo 的 `.ps1`，所以**不會**
   重啟 shell。從 Windows PowerShell 5.1 或 pwsh 7 起手都可以。

!!! warning "在 GFW 後面"
    bootstrap 期間請開著 VPN —— scoop 會從 **GitHub releases** 下載
    git / pwsh / chezmoi / uv。`China mirrors` 選項只在執行期重導
    pip / npm / cargo / go / node，**不涵蓋** scoop 自己的下載。

## 初始化提問

`chezmoi init` 只會問一次（答案會被記住，不再重複問）：

| 提問 | 預設 | 意義 |
|---|---|---|
| Role | `workstation` | `workstation` = 完整桌面；`minimal` = 只有 shell |
| Coding agents | 開（workstation） | Claude Code、OpenCode、Codex、Copilot CLI、SpecStory |
| Windows GUI apps | 開（workstation） | VSCode、Cursor、Notepad++、Terminal、Alacritty、PowerToys、Raycast、Docker Desktop、Discord |
| WSL2 backend | 開（workstation） | Docker Desktop 後端所需的 WSL2；自動提權（一次 UAC），需重開機 |
| Utility apps | 開（workstation） | CPU-Z、GPU-Z、TreeSize、VLC、Everything、ShareX、HWiNFO |
| Gaming apps | 關 | Steam |
| Extra runtimes | 開（workstation） | 透過 mise 安裝 rust、go、ruby（node/bun/uv 為基本內建） |
| Media CLIs | 關 | ffmpeg、imagemagick |
| Local LLM tools | 關 | Ollama、LiteLLM |
| Tunnel tools | 關 | ngrok、cloudflared |
| IaC tools | 關 | Azure CLI、Terraform、OpenTofu |
| OpenSSH server | 關 | 安裝並啟用 sshd（需系統管理員；開放 inbound TCP 22） |
| herdr multiplexer | 關 | 原生 Windows 終端多工器（preview beta） |
| Clink (cmd.exe) | 關 | 透過 Clink 在 `cmd.exe` 提供 starship + zoxide + fzf（選用的次要 shell） |
| China mirrors | 關 | pip / npm / cargo / go / node 走 GFW 鏡像 |
| Managed machine | 關 | 略過 org 政策常擋的 app（Tailscale、Grammarly） |
| Backup mode | `smart` | 首次 apply 前備份既有檔案（`smart`/`full`/`off`） |
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
