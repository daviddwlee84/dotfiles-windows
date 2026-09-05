# 工具索引

安裝清單在 `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
（單一事實來源），並由初始化開關控制。**scoop** 負責 CLI 工具；**winget** 負責
GUI 應用程式。

## CLI 工具（scoop）

本 repo 另提供原生 PowerShell 輔助指令 [`appsrc`](appsrc.md)，唯讀檢查 CLI
來源、重複安裝與遮蔽，不需要另外安裝套件。

| 工具 | 用途 |
|---|---|
| git、gh、glab | 版本控制 + GitHub / GitLab CLI |
| neovim | 編輯器（已配置 LazyVim） |
| lazygit | git TUI（delta 呈現 + [`I` branch containment／PR 洞察](lazygit.zh-TW.md)） |
| zoxide | 更聰明的 `cd` |
| fzf、fd、ripgrep | 模糊搜尋 / 找檔案 / grep |
| bat、eza | `cat` / `ls` 替代品 |
| glow | Markdown 閱讀器 / 分頁器 —— 在終端機渲染 `.md` |
| delta | git diff 分頁器 |
| jq | JSON 處理器 |
| yazi、btop | 檔案管理員 / 系統監控；Yazi 包含受保護的 `git.yazi` 狀態標記（[說明](yazi.zh-TW.md)） |
| pueue | 背景命令佇列（`pueue` client + `pueued` daemon）。以系統管理員 apply 時會安裝並啟動內建 Windows service；未提權時則啟動 detached daemon，之後第一個 pwsh 也會靜默補起。 |
| television（`tv`） | 模糊選擇器 / channel 啟動器 |
| tldr（tlrc） | 社群 man page 速查表；`tldrf` 加上 `zh_TW → zh → en` fallback |
| gh dash | GitHub PR/issue 儀表板 TUI（gh 擴充；`gh` 登入後才會安裝） |
| starship | 提示字元 |
| node | JS runtime（`nodejs-lts`） |
| uv | Python 套件/runtime 管理器 |
| bun | JS runtime + 套件管理器（copilot-proxy 用） |
| just | 任務執行器（本 repo 的 `justfile`） |
| make | GNU make |
| gcc | Neovim tree-sitter parser 的 C 編譯器（MinGW-w64；nvim-treesitter `main` 分支透過 `tree-sitter build` → Rust `cc` crate 編譯，需要 gcc/clang/MSVC —— **不是** zig） |
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
UAC）。若在 proxy／公司網路／GFW 下 WSL app 下載被 reset（「连接被重置」），腳本會退而
以 **DISM 離線啟用** WSL2 功能，並指向 kernel MSI 與 `wsl --update`。WSL 作為 *Linux
shell* 仍不在此 repo 範圍 —— 見
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
  公司機器可能因 `registry.npmjs.org` 被封鎖而使用內部 pull-through mirror。npm 會遵守
  設定的 registry，Bun 不會，因此 `copilot-proxy` 優先以 npm 安裝到自己的 prefix。
  用 `npm view <package>@<version> version` 診斷 mirror，不要用 `npm ping`；對應的
  symptom record 是 `pitfalls/` 下的
  `copilot-api-connectionrefused-stale-bun-only-module` 與
  `packagefeedproxy-npm-404-wrong-base-path`。
- **Pi**（`@earendil-works/pi-coding-agent`）—— 走同一套 corporate-first npm
  政策，固定裝進 Scoop Node 自有的 persistent prefix，並一律加上
  `--ignore-scripts --no-bin-links`。chezmoi 管理的 `pi.cmd` 與私有
  `pia-pi.ps1` launcher 會直接解析
  package 宣告的 `bin.pi` entrypoint，因此不會刪除其他 npm `pi` shim。遷移精確的
  舊套件 `@mariozechner/pi-coding-agent` 前會快照既有 package 與 shims；canonical
  安裝失敗時會復原。wrapper 只會阻擋包含 Pi 本體的 update（`pi update`、
  `--self`、`--all`）；只更新 model／extension 仍可使用。Pi 本體請用
  `just upgrade-npm-agents`，以維持固定 prefix、source policy 與 rollback。
  PowerShell 會建立保留 argv 的 `pi` function，直接呼叫私有 launcher。
  `pi.cmd` 與 npm 自己的 batch shim 一樣，只供可信的互動式 cmd.exe 使用；需要
  傳遞任意 argv 的 automation，請用 PowerShell argument array 呼叫
  `~/.config/powershell/bin/pia-pi.ps1`，或使用不啟用 shell parsing 的 `pia`。
- **Oh My Pi（`omp`）** —— 以 `-Binary` 執行官方
  `https://omp.sh/install.ps1`，只安裝預編譯 Windows binary。只有
  `%LOCALAPPDATA%\omp\omp.exe` 確實存在，且 `--version` 成功回傳非空內容，才算
  安裝成功。PATH 也會加入 Scoop Git 真正的 `bin` 目錄，讓上游 installer 能把
  `bash.exe` 記錄給 OMP 的 shell 功能。
- **`pia`** —— chezmoi external 會把 `daviddwlee84/pi-agents` fast-forward 到
  `~/.local/share/pi-agents`；只有 `bin/pia.cmd` 存在時，才把它的 `bin` 提升到
  PowerShell 與原生 User PATH 前段。`PIA_PI_BIN` / `PIA_OMP_BIN` 只在未有使用者
  override 時才預設為自有 launcher。不做排程 refresh；請明確執行
  `just upgrade-pia`。
  這份 checkout 是唯讀部署 mirror：`pia use` 的選擇存於
  `~/.config/pi-agents`，runtime、session 與 handoff 則留在
  `~/.local/state/pi-agents`。PowerShell 會把 `pia completion powershell`
  快取到 `~/.cache/pwsh-init/pia.ps1`，並同時以 launcher timestamp 與 checkout
  的 Git revision 判定是否失效。執行 `just upgrade-pia` 後，開新 shell 或執行
  `reload`；`pia use <Tab>` 就會列出更新後 checkout 裡的 combo ID，而不必每次
  補全都承擔一次 Node 啟動成本。此 bundle 也會安裝 `gitleaks`，供 `pia handoff`
  做最後一道本機 secret scan。
- **Codex 原生 footer** —— chezmoi 以非破壞性 overlay 把 provider-neutral
  status line（model/reasoning、fast mode、branch、context、tasks、directory）合併到
  `~/.codex/config.toml`；不裝 fork 或 PATH shim。見
  [Codex status line](codex-status-line.zh-TW.md)。
- **Codex lifecycle hooks** —— 每次 apply 都把 Herdr 與選用的 peon-ping hooks
  收斂到 inline `config.toml`。只有在所有 entry 都屬於 Herdr 時，才會先備份再停用 legacy
  `hooks.json`；遇到 foreign hooks 會 fail closed、完全保留。Command 使用 PowerShell
  `-EncodedCommand`，因為 Windows 上 Codex 0.144 會再以 `cmd.exe /C` 包住整條 hook，含
  nested quotes 的 `-File "..."` path 會被破壞。新 command identity 需在 Codex `/hooks`
  review 一次；chezmoi 不會寫入 trust hash。
- **OpenCode Desktop** —— `opencode-ai` CLI 的 GUI 版，由 scoop 安裝
  （`extras/opencode-desktop`）。
- **claude-hud** —— 顯示在 Claude Code 輸入框下方的狀態列 HUD。同一個
  `run_onchange` 合併腳本（`.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`）
  會彼此獨立地深度合併 `~/.claude/settings.json` 與穩定路徑
  `~/.claude/plugins/claude-hud/config.json`，各自保留只存在於 live 檔的狀態。後者會
  強制套用 **claude-hud 0.8.0 的受管 Full policy**：英文標籤、Expanded 版面、非 compact
  usage bar、活動資訊，以及 token/usage/cost/speed/session 時間戳、memory/cache/version
  與 Git/Jujutsu 狀態。自訂文字、auth/provider、排序、色彩、threshold、時間/model 格式、
  external usage path 與未來新增的 key 仍由使用者擁有。選用的
  `~/.claude/claude-hud.json` per-config override 永遠不會被修改，並可刻意遮蔽受管 base。
  外掛會在首次啟動時從 marketplace 自動安裝；受 guard 保護的 Git Bash status-line
  command 使用 scoop 的 `node`，在 plugin cache 尚未出現前會安靜地 no-op。
  settings overlay 也會啟用 `pyright-lsp`，並設定 `permissions.defaultMode: auto` 與
  `skipDangerousModePermissionPrompt`。執行 `chezmoi apply` 後請**重啟 Claude Code**以載入
  新安裝的外掛。參見[同時執行多個代理](claude-code-agents.zh-TW.md)。
- **桌面通知** —— `apprise`（`uv tool install --with pywin32 apprise`）在 Claude
  Code 的 **Notification**（需要你注意）與 **Stop**（任務完成）事件時，透過原生
  pwsh hook（`~/.claude/hooks/notify.ps1`，由 settings overlay 寫入 `hooks`）
  彈出原生 Windows toast。路由設定於 `~/.config/apprise/apprise.yaml` —— 標記為
  `desktop` 的 `windows://` 後端；自己的遠端服務（Discord/Slack/…）請加在只建立一次
  的 `~/.config/apprise/custom.yaml`。移植自上游 repo 的 `notify.sh` + `apprise.yaml`。

官方 **ChatGPT** 桌面程式透過 Microsoft Store 安裝（見 GUI 應用程式）；**Codex**
是上面的 `@openai/codex` npm CLI，不是 Store app。SpecStory
已有官方 Windows CLI，隨 coding-agent bundle 安裝。安裝器選取最新穩定 release，
驗證官方 SHA-256 並測試 binary 後放入 `~/.local/bin`，不再需要 Go 編譯。
舊的 `installSpecstoryBuild` key 保留為獨立安裝開關；以 `just upgrade-specstory`
升級，`just specstory-build` 則保留為相容指令。


Herdr 與 herdr-plus 在沒有明確 proxy 環境變數時，會暫時沿用 Windows 已啟用的
靜態系統代理，讓原生 curl/Go 與 PowerShell 下載走相同連線；不會修改套件來源、
持久環境變數或 public fallback 政策。

## PowerShell 模組（PSGallery）

- **PSFzf** —— fzf 快捷鍵（Ctrl+t 找檔案、Ctrl+r 歷史）。
- **AudioDeviceCmdlets** —— 提供 `sysvol`/`sysmute` 的絕對音量與靜音控制。

## 選用開發套件

預設關閉；開啟對應的 init 提問即安裝：

| 開關 | 安裝內容 |
|---|---|
| Local LLM tools | Ollama（`Ollama.Ollama`）+ LiteLLM（`uv tool install 'litellm[proxy]'`） |
| summarize | [`summarize`](https://github.com/steipete/summarize) —— YouTube／podcast／網頁／PDF → LLM 摘要，預設輸出繁體中文。沒有 scoop/winget manifest，所以用 npm 全域套件（`@steipete/summarize`，Node 24+ 由 baseline 的 `nodejs-lts` 提供），外加 scoop 的 `ffmpeg`／`yt-dlp`／`tesseract`。`--cli claude|codex|gemini|pi` 可沿用已登入的 coding CLI 而非 API key。`~/.summarize/config.json` 採 `modify_` overlay，因為 summarize 自己也會改寫該檔；包裝函式 `ytsum`／`sumq`／`suml`／`sumj` 放在 `profile.d/32_summarize.ps1`。以 `just upgrade-summarize` 升級。見 [summarize](summarize.zh-TW.md)。 |
| Tunnel tools | ngrok、cloudflared（scoop） |
| IaC tools | Terraform、OpenTofu（scoop）+ Azure CLI 與 `azure-devops` 擴充（`az devops`/`az repos`,winget） |
| OpenSSH server | Microsoft OpenSSH Server（sshd）：保留既有 Microsoft MSI 安裝，否則安裝 Windows capability；驗證 service／listener／firewall，並把真實 pwsh executable 設為整台機器的預設 shell。需系統管理員；見下方檢查清單。 |
| herdr multiplexer | herdr，原生 Windows 終端多工器（**preview beta**）。沒有 scoop/winget manifest —— 透過驗證過雜湊的 herdr.dev 官方安裝器安裝；設定受管於 `~/.config/herdr/config.toml`（以 pwsh 為預設 shell）。此套件也會從官方最新 Windows release 安裝 [`dev`](https://github.com/daviddwlee84/dev-cli)，驗證 SHA-256 後放到 `~\.local\bin`，並以 `dev-cli` 名稱提供，讓 Microsoft DevTool 保留 `dev`（`prefix+d` dashboard + PowerShell completion）；另安裝 herdr-plus（`prefix+y` Quick Actions / `prefix+O` Projects）。即使 Extra runtimes 關閉，仍會為 herdr-plus 安裝 Scoop Go。Apply 只安裝缺少的 dev-cli；`just upgrade-dev` 才會升級到最新 release。六個低頻 pane/workspace copy 操作集中在 `prefix+y`，互動式 path picker 保留在 `prefix+p`。`prefix+alt+e` 會直接編輯既有且非空的 `HERDR_CONFIG_PATH` target；未設定時則編輯 `~/.config/herdr/config.toml`。它驗證同一個檔案，再透過繼承的 socket reload 目前 server，整個流程絕不呼叫 chezmoi。開啟 editor 前會在同一目錄建立唯一且保留 metadata 的備份。editor 或驗證失敗時，拒絕的內容會以權限受限的 `config.toml.invalid-*` sibling 保留，並原子式還原先前有效的 target；若只有 reload 失敗，則保留有效的新 target 與備份。`$env:EDITOR` 必須只指定一個會阻塞的 executable 或 wrapper；`code --wait` 之類的參數應放進 wrapper，不可塞入變數。未設定時，helper 依序 fallback 到 nvim，以及明確等待結束的 Notepad。日後執行 `chezmoi apply` 仍可重新套用 canonical `[theme]`、`[ui]`、`[terminal]` 與 `[keys]` tables。若要永久保存 runtime 改動，必須另外手動、選擇性地編輯 `.chezmoitemplates/herdr/config.toml`；此 target 使用 `modify_` merger，禁止對它執行 `chezmoi add` 或 `chezmoi re-add`，以免取代／繞過 merger 並匯入 runtime-owned state。每次 apply 也會把目前 Herdr binary 的官方 skill 寫入兩個 agent skill root。見 [rationale](rationale.zh-TW.md#wezterm-herdr-beta)。 |
| Clink (cmd.exe) | [Clink](https://chrisant996.github.io/clink/)（scoop `main`）—— cmd.exe 的 Bash 風格行編輯，讓 **starship** + **zoxide** + **fzf** 也能用在 DOS 提示字元。沿用共用的 `starship.toml`；註冊使用者層級 cmd AutoRun、部署我們的 `starship.lua`，並把社群的 `clink-zoxide` / `clink-fzf` 橋接抓進 `%LocalAppData%\clink`。pwsh 仍是預設 —— 這是選用的次要 shell，只有 prompt + 導覽對等。見 [rationale](rationale.zh-TW.md#powershell-7-cmdexe-clink) 與 [Shell](shell.zh-TW.md#cmdexe-via-clink)。 |
| try（暫時性 workspace） | [`try`](https://github.com/tobi/try)，透過 `gem install try-cli` 安裝（若無 ruby 會一併裝）。建立以日期命名的 `~/src/tries/YYYY-MM-DD-name` 試驗目錄 + 模糊選擇器；`tri <git-url>` 會 clone 進其中一個。pwsh 指令是 **`tri`**（`try` 是保留字 —— 裸打 `try` 無法 parse；`& try` 可用）。見 [Shell](shell.zh-TW.md#try)。 |
| translate（workstation 預設開） | [`translate`](https://github.com/daviddwlee84/translate) —— 終端機翻譯工具（CLI + TUI），走 copilot-proxy / Ollama / Google，另有離線的 CC-CEDICT + ECDICT 辭典。它沒有 scoop/winget manifest，也沒有預先編譯的 Windows release，所以用 `go install` 從原始碼編進 `~\.local\bin`（go 由該區塊自己裝，不必開「Extra runtimes」）；**第一次編譯要好幾分鐘**。附帶 pwsh tab 補全與 `translate` tv channel。見 [translate](translate.zh-TW.md)。 |
| Rime 輸入法 | [小狼毫 / Weasel](https://github.com/rime/weasel)（`Rime.Weasel`），Windows 版 Rime，註冊為**繁體中文**。winget manifest 是 machine-scope NSIS，套用時會跳 **UAC**。`%APPDATA%\Rime` 下的 `*.custom.yaml` 由 chezmoi 納管，其中引擎層設定與 macOS/Linux repo（鼠鬚管 / ibus-rime）**逐位元組共用**。見 [輸入法](input-method.zh-TW.md)。 |

### OpenSSH server：先檢查、再啟用、最後驗證

OpenSSH 預設不安裝。先在 chezmoi source 目錄檢查；check-only 不會安裝
capability、修改 service／firewall／registry，也不會要求提權：

```powershell
pwsh -NoProfile -File .\scripts\enable-sshd.ps1 -CheckOnly
```

接著在 Windows **本機提升權限的 pwsh 視窗**執行，並保持該視窗開啟，直到第二台
主機證明新連線可用：

```powershell
just enable-sshd
```

helper 會先偵測可用的 Microsoft OpenSSH MSI／service，只有真的沒有 server 時才考慮
Windows capability；不會只因 capability 顯示 `NotPresent` 就裝出互相競爭的第二套。
它會解析真正的 Scoop `apps\pwsh\current\pwsh.exe`（或 PowerShell 7 MSI
executable）、驗證為 Core 7+，再把該路徑寫入
`HKLM\SOFTWARE\OpenSSH\DefaultShell`。這是 machine-wide 設定，會影響所有透過
sshd 登入的帳號。若有 machine-wide PowerShell 7 MSI 會優先使用；若只有使用者層級
Scoop 安裝，setup 會使用其真實 executable，但會警告其他 SSH 帳號可能無權穿越該
使用者的 profile。多帳號 server 應先安裝並驗證 machine-wide PowerShell 7。
`DefaultShellCommandOption` 只報告、不修改；應在實際安裝的 OpenSSH 版本上驗證
command mode，而不是照搬歷史 registry 值。

既有且相容的 TCP/22 規則會保留；範圍過寬時只警告，不在遠端 session 中偷偷重寫。
若完全沒有相容規則，helper 只建立 inbound Domain/Private + `LocalSubnet` 規則。本機
ready 也要求目前真的有 **active** Private 或 DomainAuthenticated 網路；只有 Public，
或 firewall／network 稽核不完整時一律 fail closed，並提示到 Windows Settings 處理。
helper 絕不開放 Public、更改 network category、改寫 `sshd_config` 或配置
`authorized_keys`。`just enable-sshd` 只有全部本機 readiness check 通過才回傳 0；
嵌入 chezmoi 的 run-script 仍保持 nonfatal，避免單一 optional setup 中斷整個 apply。

關閉提升權限視窗前，請從另一台主機證明三種行為：

```powershell
ssh windows-host '$PSVersionTable.PSEdition; $PSVersionTable.PSVersion; [Environment]::ProcessPath'
ssh windows-host 'exit 23'
$LASTEXITCODE  # 必須是 23
ssh -t windows-host
```

本機驗證失敗時，helper 會精確還原先前的 `DefaultShell`，且只移除這次建立的
firewall rule。若外部連線測試失敗，請從仍開著的本機提升權限視窗還原預先記錄的
registry 狀態；若該值原本存在，不能直接刪掉。

## 套件 registry

套用時的 installer 與互動式 shell（`profile.d/05_mirrors.ps1`）共用同一份政策：

- **受管機器**的 pip/uv 走公司 PyPI pull-through registry，npm 走公司 npm
  pull-through registry；PyPI artifact 最終由公司的 Azure Artifacts backend
  提供。NuGet 由 IT 另外配置，dotfiles 不覆寫。
- **China mirrors** 只在非受管機器生效：pip/uv 用清華、npm 用 npmmirror、
  RubyGems 用 Ruby China、Go 用 goproxy.cn、rustup 用 rsproxy；不影響 Scoop
  下載 runtime。
- 未找到公司的 Go、Rust 或 Ruby registry，因此受管機器保留這些 ecosystem
  既有預設值。

兩個機器 toggle 同時為 true 時仍以 managed policy 優先。另一個獨立的
`allowPublicPackageFallback` 提問**預設關閉**；受管機器明確開啟後，repo 自己
控制的 npm agent 安裝/升級與 uv dependency resolution（Apprise、LiteLLM、
Herdr tomlkit、docs 指令）會先走公司來源。只有 timeout、暫時性網路錯誤或明確
HTTP 5xx 能觸發一次隔離的 public PyPI/npm retry。401/403、TLS/certificate、
404/package absence、rate limit、solver/build 與本機權限錯誤一律不 fallback。

corporate 與 public index 不會同時配置；每次嘗試只在 child process 清除額外
index/registry，保留 parent shell 與 cache，並明確顯示 retry。切換模式時也只
清除舊版 repo 會產生的已知 endpoint 值；其他 user/IT 值都保留，`local.ps1`
仍是互動式 shell 最後套用的 override。

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
| `translate` | 翻譯歷史 → Enter 複製譯文、Ctrl+Y 複製原文、Ctrl+S 朗讀（選用的 `translate`） |

## 升級

安裝與升級刻意分開。`chezmoi apply` 只安裝缺少的東西；升級要明確執行：

```powershell
just upgrade-scoop     # scoop update *
just upgrade-winget    # winget upgrade --all
just upgrade-npm-agents # Pi/OpenCode/Codex/Copilot；請先關閉（Windows 會鎖 executable）
just upgrade-omp       # 重跑官方 -Binary installer，再驗證 omp.exe
just upgrade-pia       # refresh chezmoi external checkout
just upgrade-agents    # 聚合上面三個命令
just upgrade-dev       # go install .../dev@latest（隨 Herdr stack 安裝）
just upgrade-herdr     # 驗證過的官方 installer + 對應版本全域 skill（需在 Herdr 外執行）
just upgrade-yazi-plugins # scoop update yazi，再執行 ya pkg upgrade
just upgrade-translate # go install …/translate@latest（選用工具，不含在 `just upgrade` 裡）
just upgrade-summarize # npm update -g @steipete/summarize（選用工具，不含在 `just upgrade` 裡）
```

這組 agent 升級刻意不掛到裸的 `just upgrade`：Windows 可能鎖住正在執行的 CLI
或 OMP binary，也不應在 active session 中途把 `pia` 的 combos 切到新 revision。
