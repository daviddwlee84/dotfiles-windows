# 工具索引

安裝清單在 `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
（單一事實來源），並由初始化開關控制。**scoop** 負責 CLI 工具；**winget** 負責
GUI 應用程式。

## CLI 工具（scoop）

| 工具 | 用途 |
|---|---|
| git、gh | 版本控制 + GitHub CLI |
| neovim | 編輯器（已配置 LazyVim） |
| lazygit | git TUI（已配置 delta 分頁器） |
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
| zig | Neovim tree-sitter parser 的 C 編譯器 |
| win32yank | Neovim 的剪貼簿提供者 |
| gnupg | `gpg` —— 讓 mise 驗證 runtime 下載 |

Runtime：`node@lts` + `bun` 由 mise 安裝為基本內建（npm-based 的 coding agents 需要
node）。啟用 **Extra runtimes** 時才會加裝 `rust`、`go`、`ruby`。

## GUI 應用程式（winget）

| 應用程式 | winget id |
|---|---|
| VSCode | `Microsoft.VisualStudioCode` |
| Cursor | `Anysphere.Cursor` |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Alacritty | `Alacritty.Alacritty` |
| PowerToys | `Microsoft.PowerToys` |
| Flow Launcher | `Flow-Launcher.Flow-Launcher` |
| Antigravity | `Google.Antigravity` |
| Docker Desktop | `Docker.DockerDesktop` |
| Discord | `Discord.Discord` |
| Claude Desktop | `Anthropic.Claude` |
| ChatGPT | `9NT1R1C2HH7J`（msstore） |
| Codex | `9PLM9XGG6VKS`（msstore） |
| Chrome | `Google.Chrome` |
| Arc | `TheBrowserCompany.Arc` |
| Zen Browser | `Zen-Team.Zen-Browser` |
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
| Tailscale | `Tailscale.Tailscale` | mesh VPN |

!!! note "啟動器與 Alt+Space 撞鍵"
    [Flow Launcher](https://www.flowlauncher.com/) 是預設的鍵盤啟動器（x64 與
    ARM64 都穩定）。**Raycast for Windows** 是 Microsoft Store 測試版、winget id
    不穩定，故改為選用：`winget install raycast`。Flow Launcher、Raycast 與
    **PowerToys Run** 都預設 **Alt+Space** —— 擇一使用，其餘改鍵或停用。

!!! note "Notepad++ 改為選用"
    已從預設清單移除：在 Windows-on-ARM 上其安裝程式屬低信譽二進位，會被
    Windows Defender / SmartScreen 誤判為 PUA（受管機器的 PUA 防護更嚴），且與
    VSCode / Cursor / nvim 功能重疊。想要的話自行安裝：
    `winget install Notepad++.Notepad++` 或 `scoop install notepadplusplus`。

## AI agents（npm）

`@anthropic-ai/claude-code`、`opencode-ai`、`@openai/codex`、`@github/copilot`
—— 透過 npm 全域安裝（由 mise 的 `node` 提供）。官方 **ChatGPT** 與 **Codex**
桌面程式透過 Microsoft Store 安裝（見 GUI 應用程式）。SpecStory 沒有原生 Windows
CLI 套件，故此處略過。

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

## Television（tv）channels

自訂選擇器放在 `%APPDATA%\television\cable\`（執行 `tv` 瀏覽，或 `tv <name>`）：

| Channel | 用途 |
|---|---|
| `aliases` | PowerShell aliases 與函式（shell 啟動時快取） |
| `git-ops` | 常用 git 指令 → Enter 複製到剪貼簿 |
| `ports` | 監聽中的 TCP ports → Ctrl+K 結束佔用的行程 |
| `kill-process` | 依記憶體排序的行程 → Enter/Ctrl+K 結束、Ctrl+D 強制結束 |
| `scoop-apps` | 已安裝的 scoop apps → Enter 資訊、Ctrl+U 更新、Ctrl+X 移除 |
| `apps` | 從開始功能表捷徑啟動應用程式 |
| `channels` | 依描述瀏覽所有 tv channel → Enter 開啟選定的 channel |

## 升級

安裝與升級刻意分開。`chezmoi apply` 只安裝缺少的東西；升級要明確執行：

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
```
