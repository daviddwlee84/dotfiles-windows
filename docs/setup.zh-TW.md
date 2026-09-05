# 安裝

受管環境需要 **PowerShell 7.4+ Core**；只有最初的 `bootstrap.ps1` 相容
Windows PowerShell 5.1，並會在執行 chezmoi 前檢查解析到的 `pwsh`。
已存在的舊版 pwsh 不會被默默升級，請透過原管理器升級後重試。
詳見 [執行環境與維護筆記](powershell-maintenance.md)。

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

若要無人值守地安裝 **minimal**，請先下載並檢閱檔案，再明確傳入 role 與 Git
identity。慣用的 `irm | iex` 仍保持互動式，因為它不適合安全地傳遞腳本參數：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$env:TEMP\bootstrap.ps1" `
  -NonInteractive -Role minimal `
  -Name 'Da-Wei Lee' -Email 'daviddwlee84@gmail.com'
```

`-NonInteractive` 刻意只支援 `minimal`；role／name／email 任一缺少，或已存在
chezmoi config／source，都會在修改 execution policy 或安裝任何東西前拒絕執行。
既有 `prompt*Once` 資料必須用 `chezmoi init --prompt` 或直接編輯 config 修改；
unattended 重跑不能安全地把已儲存的 workstation 切成 minimal。如此可避免自動化
意外選到或沿用完整的 `workstation` 套件組。

用 `powershell`，**不是** `pwsh` —— 全新機器上 pwsh 還沒裝。bootstrap 邏輯只維護一份、
寫在 PowerShell（`bootstrap.ps1`）：elevation / `PATH` / `chezmoi` 這些步驟用 cmd 寫
會又醜又易錯，而且這份 dotfiles 本來就是 PowerShell，一台完全沒有 PowerShell 的機器
本來就用不了這個 repo。

## Windows Git symlink

這個 repo 刻意使用少量 Git symlink：`CLAUDE.md → AGENTS.md`，以及
`.claude/skills/ → .agents/skills/` 的共用 skill。Windows 開啟 **Developer Mode**
後即可免系統管理員權限建立 symlink；但許多 Git for Windows 安裝預設會把
`core.symlinks` 設為 `false`。在 clone 後續 working copies **之前**，為目前 Windows
使用者設定一次即可：

```powershell
git config --global core.symlinks true
```

這是每位使用者一次性的 Git 設定，不是每次 clone 都要執行。若既有 checkout 已把
symlink 展開成只有一行路徑文字的 placeholder，先開啟 Developer Mode，再修復四個
tracked paths。第一次成功 apply 後，受管的 `~/.gitconfig` 也會持續重申
`core.symlinks = true`；手動指令的用途是讓第一次 checkout 就能正確建立連結。

更新後的 shell profile 安裝完成後，在任何既有 repo 裡都可用安全捷徑修復：

```powershell
gwinfix
```

先以 `gwinfix -Root ~/Documents/Program -WhatIf` 預覽指定目錄下所有受影響的 repo，
確認後移除 `-WhatIf` 即可修復。等價的手動操作如下：

```powershell
git config core.symlinks true
Remove-Item -LiteralPath @(
  '.claude/skills/agent-history-hygiene',
  '.claude/skills/mkdocs-site-bootstrap',
  '.claude/skills/project-knowledge-harness',
  'CLAUDE.md'
)
git restore --worktree -- `
  .claude/skills/agent-history-hygiene `
  .claude/skills/mkdocs-site-bootstrap `
  .claude/skills/project-knowledge-harness `
  CLAUDE.md
```

!!! warning "Defender 可能把命令列 irm|iex 當成 ClickFix 或 Commando"
    透過 cmd、SSH、WinRM、排程器或其他 process launcher執行時，`irm <url> | iex`
    會直接出現在 `powershell -Command`／`pwsh -c` 命令列。即使抓下來的腳本本身乾淨，
    Defender仍可能依形狀擋成 **`Trojan:Win32/ClickFix.*!ml`** 或
    **`Trojan:Win32/Commando.A!ml`**；這正是
    [ClickFix](https://www.microsoft.com/en-us/security/blog/2025/08/21/think-before-you-clickfix-analyzing-the-clickfix-social-engineering-technique/)
    假 CAPTCHA攻擊使用的 download-execute pattern。

    上方第一種寫法只適用於**已開啟的互動式 PowerShell**；不要原樣送成
    `ssh host 'irm ... | iex'`。遠端自動化應先傳輸或下載檔案、檢閱／驗證 hash，再以
    獨立的 `pwsh -File` process執行。不要為被擋的命令列新增 Defender exclusion或按
    Allow。維護者記錄見
    `pitfalls/clickfix-defender-flags-cmd-irm-iex.md`。

`bootstrap.ps1` 會依序（且可重複執行）完成：

1. 將目前使用者的 execution policy 設為 `RemoteSigned`。
2. 安裝 [scoop](https://scoop.sh)（使用者層級、免系統管理員 —— 但若 shell 本身是
   系統管理員身分，會自動帶上 `-RunAsAdmin`；否則安裝程式會以
   *「Running the installer as administrator is disabled by default」* 拒絕執行）。
3. 透過 scoop 安裝 `git`、`7zip`、PowerShell 7（`pwsh`）、`chezmoi`、`uv`。
   若尚無 pwsh，bootstrap 會先更新 Scoop／bucket metadata，確保安裝目前的
   **stable** manifest。既有 pwsh 不會被隱式升級；確定要升級時請執行
   `scoop update pwsh`。
4. 從 registry 重新載入 `PATH`，讓剛裝好的 scoop shim（`chezmoi`、`pwsh`、`uv`）
   在同一個 session 就能被找到。
5. 實際啟動解析到的 pwsh，並要求 `PSEdition=Core`、版本至少為 7。PowerShell
   安裝失敗或不完整時會在這裡停止，不會拖到 chezmoi 裡才失敗。
6. 執行 `chezmoi init --apply`（若 source 已經 clone 過則改用 `chezmoi update`）
   —— chezmoi 會透過 `[interpreters.ps1]` 自己用 pwsh 跑 repo 的 `.ps1`，所以**不會**
   重啟 shell。從 Windows PowerShell 5.1 或 pwsh 7 起手都可以。

!!! warning "在 GFW 後面"
    bootstrap 期間請開著 VPN —— scoop 會從 **GitHub releases** 下載
    git / pwsh / chezmoi / uv。`China mirrors` 選項只在執行期重導
    pip/uv、npm、RubyGems、Go 與 rustup，**不涵蓋** scoop 自己的下載。

## 初始化提問

`chezmoi init` 只會問一次（答案會被記住，不再重複問）。`minimal` 指只有
shell 的開發 baseline，**不是**極小安裝：它仍會安裝核心 CLI／toolchain，Scoop
下載 cache 與暫存 staging 尚未計入前，估計約 2 GB。見[磁碟空間](disk-space.zh-TW.md)。

!!! note "Private pia checkout"
    `pi-agents` 是 private repo。啟用 coding agents 前，先確保 Git 能透過 HTTPS
    clone（例如執行 `gh auth login`，再執行 `gh auth setup-git`）。完全新機器可先
    關閉 coding agents 套用一次，等 `gh` 安裝後完成驗證，再開啟 chezmoi toggle
    並重新 apply。

| 提問 | 預設 | 意義 |
|---|---|---|
| Role | `workstation` | `workstation` = 完整桌面；`minimal` = 只有 shell |
| `Install coding agents (Claude Code, OpenCode, Codex, Copilot CLI, Pi, pia, OMP, SpecStory)` | 開（workstation） | 原生與 npm agents，加上 Git 管理的 `pia` combo checkout；credentials 與可變 sessions 都不進 chezmoi |
| Agent 完成回饋 | `notify`（workstation）/`none`（minimal） | coding agent 跑完時做什麼：`none`／`notify`（Windows 通知）／`peon`（遊戲語音）／`both` —— 見 [Agent 完成音效](agent-sounds.zh-TW.md) |
| `Install standalone SpecStory CLI (also included with coding agents)` | 關 | 不啟用完整 agent bundle 時獨立安裝官方 Windows release；相容保留 `installSpecstoryBuild` data key |
| Windows GUI apps | 開（workstation） | VSCode、Cursor、Notepad++、Terminal、Alacritty、PowerToys、Raycast、Docker Desktop、Discord |
| WSL2 backend | 開（workstation） | Docker Desktop 後端所需的 WSL2；自動提權（一次 UAC），需重開機 |
| WSL2 Ubuntu | 關 | 安裝 WSL2 Ubuntu 發行版並在其中安裝跨平台 dotfiles（需先開 `installWsl`） |
| WSL Ubuntu 使用者 | 你的 Windows 使用者 | WSL Ubuntu 的 UNIX 登入帳號（免密碼 sudo、自動登入） |
| WSL Ubuntu bootstrap | `headless` | dotfiles 安裝模式：`headless`（從 Windows 凍結）/`interactive`/`none` |
| Utility apps | 開（workstation） | CPU-Z、GPU-Z、TreeSize、VLC、Everything、ShareX、HWiNFO |
| Gaming apps | 關 | Steam |
| Extra runtimes | 開（workstation） | 透過 Scoop 安裝 rustup、go、ruby（node/bun/uv 為基本內建） |
| Media CLIs | 關 | ffmpeg、imagemagick |
| Local LLM tools | 關 | Ollama、LiteLLM |
| Tunnel tools | 關 | ngrok、cloudflared |
| IaC tools | 關 | Azure CLI、Terraform、OpenTofu |
| OpenSSH server | 關 | 安裝並啟用 sshd（需系統管理員；開放 inbound TCP 22） |
| herdr multiplexer | 關 | 原生 Windows 終端多工器（preview beta） |
| Clink (cmd.exe) | 關 | 透過 Clink 在 `cmd.exe` 提供 starship + zoxide + fzf（選用的次要 shell） |
| try（暫時性 workspace） | 關 | Ruby CLI（`gem try-cli`）：以日期命名的試驗目錄 + 模糊選擇器；pwsh 指令為 `tri` |
| translate | 開（workstation） | 終端機翻譯 CLI + TUI，用 `go install` 從原始碼編（第一次要編好幾分鐘） |
| Rime 輸入法（小狼毫） | 關 | 繁體中文輸入法。安裝程式是 machine scope —— 會跳 UAC；並把共用的 Rime `*.custom.yaml` 部署到 `%APPDATA%\Rime` |
| China mirrors | 關 | pip/uv、npm、RubyGems、Go 與 rustup 走 GFW 鏡像 |
| Managed machine | 關 | 使用公司 PyPI/npm registry，並略過 org 政策常擋的 app（Tailscale、Grammarly） |
| Public package fallback | 關 | 受管機器的公司 PyPI/npm 發生符合條件的暫時性錯誤時，以隔離的 public source 重試一次 |
| Backup mode | `smart` | 首次 apply 前備份既有檔案（`smart`/`full`/`off`） |
| PSReadLine vi mode | 開 | shell 的 vi 編輯模式 |

之後可執行 `chezmoi init --prompt` 強制重新詢問每一題，或直接編輯
`%USERPROFILE%\.config\chezmoi\chezmoi.toml`。

## 日常操作

```powershell
chezmoi diff            # 預覽即將套用的變更
chezmoi apply           # 只套用本機 source 的改動（不 pull）
chezmoi update --init   # git pull 後套用；--init 會補問新增的 prompt（沒新增則 noop）
just upgrade-scoop     # 升級 CLI 工具
just upgrade-winget    # 升級 GUI 應用程式
just upgrade-agents    # Pi/OMP/pia + npm coding agents；請先關閉執行中的 agents
```

在已載入的 pwsh session 中,`cau`(= `chezmoi update --init` 後 reload
`$PROFILE`)與 `cas`(= `chezmoi apply` 後 reload)是快捷指令。日常「同步
dotfiles」建議一律用 `cau` —— `--init` 表示落後於新增 init prompt 的機器,
會在下次 pull 時被補問。

## 本機覆寫

把機器專屬的調整或機密放在 `~/.config/powershell/local.ps1` —— 它會被 `$PROFILE`
最後 dot-source，且永遠不受 chezmoi 管理。

## Git 設定

GitHub 登入、Clash 代理設定與 CredentialHelperSelector 彈窗的處理方式，
見 [GitHub 登入與代理](github-auth.zh-TW.md)。

`~/.gitconfig` 由 `modify_` 疊加腳本（`modify_dot_gitconfig.ps1.tmpl`）管理。
`chezmoi apply` 會同步一組固定的設定：來自初始化提問的 `user.name` /
`user.email`、`core.autocrlf = input`、`core.symlinks = true`、`init.defaultBranch`、`pull.rebase`、
`rebase.autoStash`、Git-LFS filter 與 `http.postBuffer`。

不屬於這組設定的內容都會被原封不動保留 —— 包含 Git Credential Manager 在外部
寫入的 `[credential "..."]` 區塊。這正是它採用疊加而非一般受管檔案的原因：一般
受管檔案會在每次 apply 時覆蓋這些區塊，導致公司帳號驗證失效。

機器專屬設定請放到 `~/.gitconfig.local`；基準設定已用 `[include]` 接上它，
chezmoi 不會碰它。請勿手動編輯 `~/.gitconfig` —— 受管理的鍵會在下次 apply 時被還原。

`core.hooksPath` 刻意不設定，因為 Git 會用它**取代** `.git/hooks/`，那會悄悄停用
各個 repo 自己的 hook（例如 `pre-commit install` 寫入的那個）。

## Raycast 與 PowerToys 的衝突

Raycast 與 PowerToys Run 的啟動器預設都用 **Alt+Space**。請擇一：關閉 PowerToys Run
（PowerToys 設定 → PowerToys Run → 關）或改綁它的快捷鍵。安裝腳本會印出提醒。
