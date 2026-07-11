# 工具索引

安裝清單在 `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
（單一事實來源），並由初始化開關控制。**scoop** 負責 CLI 工具；**winget** 負責
GUI 應用程式。

## CLI 工具（scoop）

| 工具 | 用途 |
|---|---|
| git、gh、glab | 版本控制 + GitHub / GitLab CLI |
| neovim | 編輯器（已配置 LazyVim） |
| lazygit | git TUI（已配置 delta 分頁器） |
| zoxide | 更聰明的 `cd` |
| fzf、fd、ripgrep | 模糊搜尋 / 找檔案 / grep |
| bat、eza | `cat` / `ls` 替代品 |
| delta | git diff 分頁器 |
| jq | JSON 處理器 |
| yazi、btop | 檔案管理員 / 系統監控 |
| television（`tv`） | 模糊選擇器 / channel 啟動器 |
| tldr（tlrc） | 社群 man page 速查表；`tldrf` 加上 `zh_TW → zh → en` fallback |
| gh dash | GitHub PR/issue 儀表板 TUI（gh 擴充；`gh` 登入後才會安裝） |
| starship | 提示字元 |
| node | JS runtime（`nodejs-lts`） |
| uv | Python 套件/runtime 管理器 |
| bun | JS runtime + 套件管理器（copilot-proxy 用） |
| just | 任務執行器（本 repo 的 `justfile`） |
| make | GNU make |
| zig | Neovim tree-sitter parser 的 C 編譯器 |
| gcc | amd64 C 編譯器（**僅 ARM64 主機** —— 對應 x64 模擬的 nvim） |
| tree-sitter | tree-sitter CLI（nvim-treesitter `main` 分支） |
| win32yank | Neovim 的剪貼簿提供者 |
| gnupg | `gpg`（git commit 簽章、驗證） |

Runtime **改用原生（scoop），不用 mise** —— 見 [rationale](rationale.md)。`node`
（`nodejs-lts`）與 `bun` 由 scoop 安裝；啟用 **Extra runtimes** 時才會加裝 `go`、
`rust`（rustup）、`ruby`。預設 **Python** 由 uv 管理：`uv python install --default --preview`
會把 `python`/`python3` 放到 `~/.local/bin`（PATH 上排在 Store 的 `python.exe`
app-alias 前面），所以 `python`、`uv run`、`uv venv`
都能用，不需 Microsoft Store。

## GUI 應用程式（winget）

| 應用程式 | winget id |
|---|---|
| VSCode | `Microsoft.VisualStudioCode` |
| Cursor | `Anysphere.Cursor` |
| Windows Terminal | `Microsoft.WindowsTerminal` |
| Alacritty | `Alacritty.Alacritty` |
| WezTerm | `wez.wezterm`（tmux 式多工器；受管的 `~/.config/wezterm/wezterm.lua` 設定 pwsh 為預設 shell + Nerd Font） |
| PowerToys | `Microsoft.PowerToys` |
| Raycast | `9PFXXSHC64H3`（msstore） |
| Antigravity | `Google.Antigravity` |
| Docker Desktop | `Docker.DockerDesktop`（WSL2 後端由 `installWsl` 開關提供 —— 見下方） |
| Discord | `Discord.Discord` |
| Claude Desktop | `Anthropic.Claude` |
| ChatGPT | `9PLM9XGG6VKS`（msstore） |
| Chrome | `Google.Chrome` |
| Arc | `TheBrowserCompany.Arc` |
| Zen Browser | `Zen-Team.Zen-Browser` |
| Grammarly | `Grammarly.Grammarly` |
| Steam（gaming） | `Valve.Steam` |

**Docker Desktop 的 WSL2 後端**（`installWsl` 開關，workstation 預設開）由
`scripts/enable-wsl.ps1` 透過 `wsl --install --no-distribution` 安裝 —— 只裝 WSL2
平台、不裝 Linux 發行版（Docker 會自建 `docker-desktop` distro）。`wsl --install`
需要系統管理員**且**需重開機，所以未提權的 `chezmoi apply` 會自動提權（跳一次 UAC，
類似 scoop），執行安裝後印出重開機提示 —— 重開機後 Docker Desktop 即以 WSL2 後端啟動。
若要重跑或重試（例如 UAC 被拒），執行 `just enable-wsl`；已安裝的機器則為 no-op（不跳
UAC）。WSL 作為 *Linux shell* 仍不在此 repo 範圍 —— 見
[rationale](rationale.zh-TW.md#powershell-7-cmdexe-clink)。

**無人值守的 WSL Ubuntu + dotfiles**（`installWslUbuntu`，預設關）更進一步：
`scripts/enable-wsl-ubuntu.ps1` 註冊 `Ubuntu-24.04` 且**跳過 OOBE**（用 `wsl -u root`
建立使用者、免密碼 sudo、WSL 自動登入），接著在預設的 `headless` 模式下執行一條**從
Windows 凍結**的 chezmoi 指令，把跨平台 dotfiles（`daviddwlee84/dotfiles`，
`ubuntu_server` profile）裝進去，WSL 內完全不用回答提問。`wslUbuntuBootstrap` 也可設為
`interactive`（首次登入時跑父 repo 的提問）或 `none`（只建發行版）。需先有 WSL2 平台
（`installWsl`）並重開機；用 `just enable-wsl-ubuntu` 執行或重試。若日後把凍結的 profile
改成 `ubuntu_desktop`，Linux GUI app 透過 **WSLg** 直接可用。這是選用的*橋接* —— Linux
設定本身仍屬跨平台 repo，不在這裡。

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
    **Raycast**（Microsoft Store，id `9PFXXSHC64H3`）是預設啟動器，與
    **PowerToys Run** 共用 **Alt+Space** —— 停用 PowerToys Run（PowerToys
    Settings › PowerToys Run › off）或改鍵其一。Raycast for Windows 仍是 Store
    測試版；若裝不起來，改用 [Flow Launcher](https://www.flowlauncher.com/) 備援：
    `winget install Flow-Launcher.Flow-Launcher`。

!!! note "Notepad++ 改為選用"
    已從預設清單移除：在 Windows-on-ARM 上其安裝程式屬低信譽二進位，會被
    Windows Defender / SmartScreen 誤判為 PUA（受管機器的 PUA 防護更嚴），且與
    VSCode / Cursor / nvim 功能重疊。想要的話自行安裝：
    `winget install Notepad++.Notepad++` 或 `scoop install notepadplusplus`。

!!! note "受管／公司機器"
    **Managed machine** 初始化開關會略過 org 政策常擋的 app —— **Grammarly** 與
    **Tailscale**（其 MSI 在政策下以 exit `1625` 失敗）。個人機器把開關關掉即可
    照常安裝。

!!! note "Alacritty 與 Nerd Font（machine-wide 安裝）"
    scoop 的 `nerd-fonts` bucket 是把 **Hack Nerd Font Mono** 註冊在*使用者層級*
    （HKCU）。Windows Terminal 與 WezTerm 看得到使用者字型，但 **Windows 上的
    Alacritty 只讀 machine-wide 字型集**，因此找不到字型、退回預設。修法（需系統
    管理員）：`just install-fonts-machine-wide`（執行 `scoop install -g Hack-NF-Mono
    Hack-NF`），再重啟 Alacritty。用
    `[System.Drawing.FontFamily]::Families.Name | Select-String Hack` 診斷字型家族名。

## AI agents

由 **Install coding agents** 啟用：

- **Claude Code** —— `Anthropic.ClaudeCode`，透過 **winget** 安裝（原生 Windows
  版；與 GUI 應用程式中的桌面程式 `Anthropic.Claude` 不同）。以
  `just upgrade-winget` 升級，不再走 npm。
- **OpenCode**（`opencode-ai`）、**Codex**（`@openai/codex`）、**Copilot CLI**
  （`@github/copilot`）—— 透過 **npm** 全域安裝（由 scoop 的 `node` 提供）。
- **OpenCode Desktop** —— `opencode-ai` CLI 的 GUI 版，由 scoop 安裝
  （`extras/opencode-desktop`）。

官方 **ChatGPT** 桌面程式透過 Microsoft Store 安裝（見 GUI 應用程式）；**Codex**
是上面的 `@openai/codex` npm CLI，不是 Store app。SpecStory 沒有原生 Windows CLI
套件，故此處略過。

## PowerShell 模組（PSGallery）

- **PSFzf** —— fzf 快捷鍵（Ctrl+t 找檔案、Ctrl+r 歷史）。
- **AudioDeviceCmdlets** —— 提供 `sysvol`/`sysmute` 的絕對音量與靜音控制。

## 選用開發套件

預設關閉；開啟對應的 init 提問即安裝：

| 開關 | 安裝內容 |
|---|---|
| Local LLM tools | Ollama（`Ollama.Ollama`）+ LiteLLM（`uv tool install 'litellm[proxy]'`） |
| Tunnel tools | ngrok、cloudflared（scoop） |
| IaC tools | Terraform、OpenTofu（scoop）+ Azure CLI 與 `azure-devops` 擴充（`az devops`/`az repos`,winget） |
| OpenSSH server | Microsoft OpenSSH Server（sshd）：Windows capability + 自動啟動服務 + inbound TCP 22 防火牆規則，並以 pwsh 為預設 shell。需系統管理員 —— 用提升權限的 `chezmoi apply`，或在提升權限的 pwsh 執行 `just enable-sshd`。 |
| herdr multiplexer | herdr，原生 Windows 終端多工器（**preview beta**）。沒有 scoop/winget manifest —— 透過 herdr.dev 的 `irm \| iex` 腳本安裝；設定受管於 `~/.config/herdr/config.toml`（以 pwsh 為預設 shell）。見 [rationale](rationale.zh-TW.md#wezterm-herdr-beta)。 |
| Clink (cmd.exe) | [Clink](https://chrisant996.github.io/clink/)（scoop `main`）—— cmd.exe 的 Bash 風格行編輯，讓 **starship** + **zoxide** + **fzf** 也能用在 DOS 提示字元。沿用共用的 `starship.toml`；註冊使用者層級 cmd AutoRun、部署我們的 `starship.lua`，並把社群的 `clink-zoxide` / `clink-fzf` 橋接抓進 `%LocalAppData%\clink`。pwsh 仍是預設 —— 這是選用的次要 shell，只有 prompt + 導覽對等。見 [rationale](rationale.zh-TW.md#powershell-7-cmdexe-clink) 與 [Shell](shell.zh-TW.md#cmdexe-via-clink)。 |

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
