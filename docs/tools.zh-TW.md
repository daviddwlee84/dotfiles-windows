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
| television（`tv`） | 模糊選擇器 / channel 啟動器 |
| starship | 提示字元 |
| mise | runtime 版本管理器 |
| uv | Python 套件/runtime 管理器 |
| just | 任務執行器（本 repo 的 `justfile`） |
| make | GNU make |

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
| Docker Desktop | `Docker.DockerDesktop` |
| Discord | `Discord.Discord` |
| Steam（gaming） | `Valve.Steam` |

## 工具程式（winget）

由 **Install utility apps** 開關控制：

| 應用程式 | winget id | 用途 |
|---|---|---|
| CPU-Z | `CPUID.CPU-Z` | CPU/主機板資訊 |
| GPU-Z | `TechPowerUp.GPU-Z` | GPU 資訊 + 感測器 |
| HWiNFO | `REALiX.HWiNFO` | 完整硬體監控 |
| TreeSize Free | `JAMSoftware.TreeSize.Free` | 磁碟用量瀏覽 |
| WinDirStat | `WinDirStat.WinDirStat` | 磁碟用量 treemap |
| Everything | `voidtools.Everything` | 即時檔名搜尋 |
| ShareX | `ShareX.ShareX` | 截圖 + 螢幕錄影 |
| OBS Studio | `OBSProject.OBSStudio` | 螢幕錄影 / 直播 |
| VLC | `VideoLAN.VLC` | 媒體播放器 |
| Rufus | `Rufus.Rufus` | 開機 USB 製作 |
| Tailscale | `tailscale.tailscale` | mesh VPN |

!!! note "Flow Launcher"
    [Flow Launcher](https://www.flowlauncher.com/)（`Flow-Launcher.Flow-Launcher`）
    是不錯的鍵盤啟動器，但預設用 **Alt+Space** —— 與 Raycast、PowerToys Run 撞鍵。
    為避免三方衝突，預設不裝；若你偏好它勝過 Raycast，可自行加入並擇一使用。

## AI agents（npm）

`@anthropic-ai/claude-code`、`opencode-ai`、`@openai/codex`、`@github/copilot`、
`@specstory/cli` —— 透過 npm 全域安裝（由 mise 的 `node` 提供）。

## PowerShell 模組（PSGallery）

- **PSFzf** —— fzf 快捷鍵（Ctrl+t 找檔案、Ctrl+r 歷史）。
- **AudioDeviceCmdlets** —— 提供 `sysvol`/`sysmute` 的絕對音量與靜音控制。

## 選用開發套件

預設關閉；開啟對應的 init 提問即安裝：

| 開關 | 安裝內容 |
|---|---|
| Local LLM tools | Ollama（`Ollama.Ollama`）+ LiteLLM（`uv tool install 'litellm[proxy]'`） |
| Tunnel tools | ngrok、cloudflared（scoop） |
| IaC tools | Terraform、OpenTofu（scoop）+ Azure CLI（winget） |

**China mirrors** 會把 pip / npm / cargo / go / node 的套件抓取導向 GFW 鏡像
（清華 / npmmirror / goproxy.cn / rsproxy），安裝時與互動式 shell
（`profile.d/05_mirrors.ps1`）皆生效。

## 升級

安裝與升級刻意分開。`chezmoi apply` 只安裝缺少的東西；升級要明確執行：

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
