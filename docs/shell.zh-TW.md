# Shell 環境

一個 PowerShell session 是怎麼組起來的 —— 什麼會被載入、怎麼 reload、`PATH`
與 XDG base 目錄怎麼設定 —— 而且**全程不碰 Windows「環境變數」GUI**。

## Profile 載入

`$PROFILE`（`~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`）是一個
很薄的 loader。它依排序（數字前綴）dot-source `~/.config/powershell/profile.d/*.ps1`
底下每個片段,最後再載入你未被追蹤的 `local.ps1`。邏輯全放在片段裡,loader
刻意保持無聊。

| 片段 | 做什麼 |
|---|---|
| `00_env.ps1` | XDG base 目錄、`$env:EDITOR`、PATH |
| `05_mirrors.ps1` | 受管機器使用公司核准 registry；其他機器可選中國鏡像 |
| `10_tools.ps1` | 快取的 `init` 掛鉤與補全：starship、zoxide、atuin、fzf、direnv、tv、dev-cli、translate、pia |
| `20_aliases.ps1` | alias 與 helper（`reload`、`cas`/`cau`、現代 CLI 替身） |
| `21_git.ps1` | oh-my-zsh `git` plugin alias 移植到 pwsh（`gst`、`gco`、`gl`=pull、`gcam`、`glol`…） |
| `28_tldr.ps1` | `tldrf` —— tldr 加上 `zh_TW → zh → en` 語言 fallback |
| `30_apps.ps1` | app 控制（`applaunch`/`appquit`/…）、音量、剪貼簿 |
| `32_try.ps1` | `tri` —— try (tobi/try) 暫時性日期命名 workspace（選用；沒 ruby 時 inert） |
| `35_yazi.ps1` | `y` —— 開啟帶 Git 狀態標記的 Yazi，離開後 cd 到最後目錄 |
| `40_copilot.ps1` | 匯入 `copilot-proxy` PowerShell 模組 |
| `90_psreadline.ps1` | PSReadLine（vi 模式、歷史） |
| `96_ssh_setup.ps1` | `ssh-setup-remote`（`Set-RemoteSshKey`）—— 互動式、支援 ProxyJump 的 SSH 金鑰設定精靈 |

`~/.config/powershell/modules` 底下的模組會被 loader 前置到
`$env:PSModulePath`,所以能直接以名稱匯入(例如 `Copilot`)。

## Reload

`reload` 把 profile **dot-source** 回當前 session —— 跟 `$PROFILE` 啟動時
用的是同一個機制:

```powershell
function reload { . $PROFILE }                    # 重新載入全部
function cas { chezmoi apply  @args; . $PROFILE } # apply,再 reload
function cau { chezmoi update @args; . $PROFILE } # git pull + apply,再 reload
```

!!! note "reload 是疊加,不是乾淨重啟"
    dot-source 是**就地重跑** profile。PATH 的修改有守門(冪等、不會重複加)、
    `Set-Alias` / `Import-Module` 只是重新套用 —— 但**上一次載入定義、這次不再
    定義**的東西**不會**被移除。要保證乾淨的狀態,請開新的 pwsh session。

## PATH:Windows vs Unix

在 **Unix**,`PATH` 是單一個以冒號分隔的變數,由 shell rc（`.zshrc` / `.bashrc`）
在啟動時組出來 —— 純粹 process 範圍、由子行程繼承,不牽涉任何系統資料庫。改一改
dotfile,下個 shell 就生效。

**Windows** 則有兩個存在**登錄檔(registry)**的*持久*層,外加行程內的複本:

| 層 | 位置 | 範圍 |
|---|---|---|
| Machine PATH | `HKLM\…\Session Manager\Environment` | 所有使用者(需系統管理員) |
| User PATH | `HKCU\Environment` | 你的帳號、你所有行程 |
| `$env:PATH` | 記憶體、每個行程一份 | 這個 session 及其子行程 |

登入時 Windows 把 Machine + User 串接成每個行程的 `$env:PATH`。改登錄檔**不會**
更新已在執行的行程。

### 我們不用 GUI 就調整 PATH

這個 repo 從不打開系統內容的「環境變數」對話框；持久設定與實際解析順序是兩件事：

1. **持久 User PATH —— 由 Scoop 等 installer 負責。** Scoop 會用程式方式把
   `~/scoop/shims`，以及 manifest 宣告的 app 實體目錄寫進 User PATH。新啟動的 shell
   與 GUI app 都能拿到這些項目，不需系統管理員權限。此 repo 本身不重寫登錄檔 PATH。

2. **當前行程的有效順序 —— 由此 repo 負責。** 共用 helper
   `scripts/windows-path-precedence.ps1` 讀取持久的 User 與 Machine 值、展開環境變數、
   丟掉空項目，並以不分大小寫的方式去重；它只修改當前 `$env:PATH`。

有效解析順序如下：

1. 只存在於繼承來的行程 PATH 內的項目（例如 portable launcher 或 CI toolcache），
   保留繼承順序；
2. profile 明確管理的目錄，依宣告順序排列 —— 特別是 `~/scoop/shims` 在
   `~/.local/bin` 前面，之後才是確認存在的選用工具目錄；
3. 持久 User PATH 的所有項目，完整保留登錄檔中的儲存順序；
4. Machine PATH 的所有項目，統一放最後。

整段 User PATH 都放在 Machine 前面很重要：即使使用者範圍的 package 加入的是實體
安裝目錄而不只是 shim，也能勝過較舊的 machine-wide 指令。第一次出現的大小寫版本會
保留，因此重載 profile 仍是冪等的。

沒載入 profile 時也套用同一政策。packages run-script 會 include 這個 helper，並在第一次
找指令前先正規化 PATH；Scoop 可能寫入新 shim 或實體目錄後，還會再次 refresh，才解析
後續工具。因此直接用 `pwsh -NoProfile` / `chezmoi apply` 不會悄悄退回 Machine-first。
獨立的 `bootstrap.ps1` 為了維持 `irm …/bootstrap.ps1 | iex` 零檔案相依，內嵌同一套
mirror：行程專屬項目 → 持久 User → Machine，並在 Scoop 安裝階段後 refresh。

!!! warning "`~/.local/bin` 通常只在 pwsh session 範圍"
    `~/.local/bin` 是你自己 script/binary 在 Windows 的落腳處 —— 路徑名跟 Unix
    一樣。與 `~/scoop/shims` 不同，此 repo 只把它當成 profile 明確路徑，從不寫進
    登錄檔。因此載入這份 profile 的 pwsh session 會有它，但 Windows PowerShell 5.1、
    GUI app 或其他 no-profile 行程不會自動拿到。若 launcher 已提供它，則會當成
    process-only 項目保留下來。

## Windows 上的 XDG base 目錄

XDG 與 Windows 用**不同的軸**切目錄 —— XDG 按*用途*（config / data / state /
cache），Windows 按*是否漫遊*（Roaming vs Local）—— 所以沒有乾淨的一對一。粗略
對照:

| XDG (Unix) | 最接近的 Windows 資料夾 |
|---|---|
| `XDG_CONFIG_HOME` (`~/.config`) | `%APPDATA%` = `AppData\Roaming` |
| `XDG_DATA_HOME` (`~/.local/share`) | `%APPDATA%` = `AppData\Roaming` |
| `XDG_STATE_HOME` (`~/.local/state`) | `%LOCALAPPDATA%` = `AppData\Local` |
| `XDG_CACHE_HOME` (`~/.cache`) | `%LOCALAPPDATA%` = `AppData\Local` |

`AppData\Roaming` 把 XDG 眼中的 *config* 和 *data* 併進同一個資料夾;
`AppData\Local` 則裝了 *cache*、*state* 與不漫遊的 data。（「Roaming」只有在網域
Roaming Profiles / Enterprise State Roaming 下才真的漫遊 —— 單機上它只是個叫這名字
的資料夾。）

與其忍受這種模糊,`00_env.ps1` 直接把 XDG 變數設成 Unix 風格路徑,讓**吃 XDG 的
工具維持乾淨的 `$HOME`,與 macOS/Linux dotfiles 共用**:

```powershell
$env:XDG_CONFIG_HOME = Join-Path $HOME '.config'
$env:XDG_DATA_HOME   = Join-Path $HOME '.local/share'
$env:XDG_STATE_HOME  = Join-Path $HOME '.local/state'
$env:XDG_CACHE_HOME  = Join-Path $HOME '.cache'
$env:YAZI_CONFIG_HOME = Join-Path $env:XDG_CONFIG_HOME 'yazi'  # yazi 預設會找 %APPDATA%
```

starship、atuin、zoxide、yazi 於是都讀 `~/.config`。那些**硬寫死 `%APPDATA%`**、
忽略 XDG 的 app —— VSCode、Cursor、Alacritty —— 就留在 `AppData\Roaming`,這也是
為什麼 repo 追蹤 `AppData/Roaming/alacritty/…`,而 backup 腳本的 allowlist 會點名
`%APPDATA%\Code`、`%APPDATA%\Cursor`、`%APPDATA%\alacritty`。

所以在這個 repo 裡,`AppData\Roaming` **不是**「Windows 版 XDG」—— 它只是那些不吃
XDG 的原生 app 的落腳處;真正扮演 XDG 角色的,是我們明確設出來的 `~/.config` 路徑。

## cmd.exe via Clink

pwsh 是這裡的預設與主要 shell —— 但 `cmd.exe` 還是會出現（有些工具會叫起它，肌肉
記憶也還在）。**選用的 `installClink` 開關**給 DOS 提示字元一個 starship prompt，
外加 `z` 跳目錄與 Ctrl-R/Ctrl-T fzf。它沿用 pwsh 已有的東西：**同一份
`~/.config/starship.toml`**，以及 `run_onchange_after_03_xdg_env.ps1` 已寫入 **User
registry** 的 `XDG_*` 變數 —— 所以 cmd 不用自己的 profile 就能繼承。

cmd 的行編輯器是 **[Clink](https://chrisant996.github.io/clink/)** —— 它的 PSReadLine
對應。開啟 `installClink` 後，packages 腳本會安裝 Clink（scoop `main`）、註冊使用者
層級的 cmd **AutoRun**（`clink autorun install`，免系統管理員），並填入 Clink profile
目錄（`%LocalAppData%\clink`）：

| 檔案 | 來源 | 提供 |
|---|---|---|
| `starship.lua` | 由 chezmoi 管理（我們的） | starship prompt（`starship init cmd`） |
| `zoxide.lua` | apply 時從 `clink-zoxide` 抓取 | `z` / `zi` 跳目錄 |
| `fzf.lua` | apply 時從 `clink-fzf` 抓取 | Ctrl-R 歷史 · Ctrl-T 檔案 · Alt-C 目錄 |

`starship.lua` 是此 repo 唯一提交的部分（一行 loader，執行 `starship init cmd`）。
那兩個社群橋接沒有 scoop/winget manifest —— 而且 zoxide 沒有原生 cmd 目標 —— 所以
就像 herdr，於 apply 時從上游抓進 `%LocalAppData%\clink`（網路失敗不致命；starship
離線仍可用）。

!!! note "對等的是 prompt，不是功能"
    cmd 拿到的是 **prompt 與導覽**，不是 pwsh 的整套功能。atuin、direnv、Television
    沒有 cmd/Clink 路徑，而每個 PowerShell 函式/模組 —— `ll`/`gs`/`reload` aliases、
    `y`（yazi）、`sysvol`、`copilot-proxy` 模組 —— 都只在 pwsh。要完整體驗請用 pwsh；
    Clink 只是讓不得不用的 cmd session 舒服一點。用 `clink info` 檢視（會列出 profile
    目錄與載入的腳本）。

## Microsoft 管理機器上的 dev-cli

Microsoft 內部 DevTool 可能已占用 `dev.exe` 指令。因此 profile 讓 `dev` 維持一般
PATH 解析，另將 `dev-cli` 直接指向受管的 repository/task CLI：
`~\.local\bin\dev.exe`。PowerShell completion 與 Herdr `prefix+d` 也統一使用
`dev-cli`，不必依賴 PATH 順序即可讓兩個工具並存。

## Git 別名

`profile.d/21_git.ps1` 把整個 [oh-my-zsh `git` plugin](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/git)
移植成原生 pwsh 函式，所以 macOS/Linux dotfiles 免費拿到的那 ~200 個別名
（`gst`、`gco`、`gcam`、`gp`、`gl`、`glol`、`grbom`、`gwip`…）在這裡意義相同。
用 `tv aliases` 模糊瀏覽當前這一整組；preview 會顯示每個定義。

跟上游 omz 有三處刻意的 Windows 專屬差異：

| 差異 | 為什麼 |
|---|---|
| `gcm` / `gm` **不**定義 | 保留為 PowerShell 內建的 `Get-Command` / `Get-Member`。改用 `gswm`（切到 main）與 `gma`/`gmc`/`gms`/`gmff` merge 家族。 |
| `gl` = `git pull` | 對齊上游 omz（取代此 repo 先前的 `gl` = `git log`）。要看圖形 log 用 `glo` / `glog` / `glol` / `glola`。`gs` 額外保留為 `git status` 別名；`gst` 才是正宗那個。 |
| `gbD` / `gcB` / `gbgD` 併入 `gbd` / `gcb` / `gbgd` | pwsh 指令名**不分大小寫**，所以 force 變體無法獨立存在 —— 只定義安全的小寫形式（打錯成 `gbD` 也絕不會 force-delete）。要 force 請用明確 flag：`gbd --force <b>`、`gco -B <b>`。 |

因為內建 alias 優先權高於同名 function，此片段會先移除會遮蔽的 alias：`gc`
（Get-Content）、`gcb`（Get-Clipboard）、`gcs`（Get-PSCallStack）、`gl`
（Get-Location）、`gp`（Get-ItemProperty）、`gpv`（Get-ItemPropertyValue）。需要那些
cmdlet 時請用完整名稱。

## try

安裝了選用的 **try**（`installTry` → `gem install try-cli`）後，`profile.d/32_try.ps1`
會加入一個暫時性 workspace 指令（沒有 ruby / try-cli 時自動 inert）。

指令是 **`tri`**，不是 `try`：`try` 是 PowerShell 保留字（`try`/`catch`），所以裸打
`try foo` 會 parse error、無法當指令名。（`& try foo` 透過呼叫運算子可用，也定義了一個
薄薄的 `try` wrapper 給它。）

| 指令 | 做什麼 |
|---|---|
| `tri <name>` | 模糊選取或建立 `~/src/tries/YYYY-MM-DD-<name>`，然後 `cd` 進去 |
| `tri <git-url>` | clone 進一個以日期命名的試驗目錄並 `cd` 進去 |
| `tri` | 開啟既有試驗的選擇器（Enter 進入、Ctrl-D 刪除…） |
| `tri . <name>` | 從當前目錄建立試驗（git repo 會變成 detached worktree） |

`$env:TRY_PATH`（預設 `~/src/tries`）決定試驗放在哪。我們無法沿用 try 自己的 shell
整合 —— try-cli 吐出的是 pwsh 無法 `eval` 的 POSIX shell，而且 `try` 是保留字 ——
所以 `32_try.ps1` 自己跑 `ruby try.rb exec`，把輸出翻譯成原生 pwsh 在當前 session
執行（讓 `cd` 真的移動這個 shell）。

## herdr workspace 輔助指令（`hvibe` / `hcode` / …）

安裝了可選的 **herdr** 多工器後，`profile.d/25_herdr.ps1` 會加入 macOS/Linux
dotfiles 那份 `24_herdr.sh` 輔助指令的 PowerShell 對應版本 —— 同樣的手感，用來快速
開出 agent workspace。若 PATH 上沒有 `herdr`，此片段不做任何事。

| 指令 | 別名 | 功能 |
|---|---|---|
| `herdr-vibe` | `hvibe` | 新 `vibe/<repo>` workspace：N 個 agent pane + 一個 lazygit tab + 一個 nvim tab。例：`hvibe 3 codex`、`hvibe --agents claude,codex`、`--tab-per-agent`。 |
| `herdr-code` | `hcode` | 新 `coding-agent/<repo>` workspace：nvim + agent split + 一個 monitor tab（btop）。例：`hcode`、`hcode codex`。 |
| `herdr-here` | `hhere` | 在 `$PWD` 開一個純 workspace（可帶指令）並 attach，不需 git repo。 |
| `herdr-root` | `hroot` | 同 `hhere`，但改在 git 根目錄開啟。 |
| `herdr-mark` / `herdr-unmark` | `hmark` / `hunmark` | 標記／清除某 pane 的 ⭐「待審閱」狀態（預設 `$env:HERDR_PANE_ID`）。 |

從 herdr **外部**執行時會 attach 一個 client 讓新 workspace 可見；從**內部**執行則
只是 focus 它。`--no-attach` 在背景建立；`--on-exit shell\|kill\|restart` 控制每個
pane 在其指令結束後的行為；`--session NAME` 指向執行中的 `herdr --session NAME`。

與 Unix 原版的差異：不用 `jq`（改用原生 `ConvertFrom-Json`）；每個 pane 的 on-exit
包裝是一段 pwsh 腳本，以 `pwsh -EncodedCommand …` 傳入，而非 bash 的 `trap`；且
SpecStory 自動包裝只有在 PATH 上真的有 `specstory` CLI 時才啟用（coding-agent bundle 會安裝官方 Windows 版本）。

!!! warning "herdr 仍是 preview/beta"
    herdr 的 Windows 版本是可選的（`installHerdr`）且僅 preview；這些輔助指令驅動它的
    CLI scripting 介面（`herdr workspace|tab|pane`），只能在真正的 Windows 機器上驗證，
    CI 不涵蓋。

## SSH 金鑰設定 (`ssh-setup-remote`)

`profile.d/96_ssh_setup.ps1` 是 macOS/Linux dotfiles 那份 `96_ssh_setup.sh` 的原生 pwsh
移植版 —— 同樣的指令名稱、同樣的流程，刻意沿用相同的片段編號。`Set-RemoteSshKey` 是
函式本體；`ssh-setup-remote` 是一個全域別名，讓兩個平台下的指令完全一致：

```powershell
ssh-setup-remote user@hostname
```

它會選擇或建立金鑰、把公鑰裝到遠端、可選擇把金鑰對複製過去（供遠端使用 GitHub），最後
把金鑰接進本機 `~/.ssh/config` —— 若別名已設定過就就地編輯既有的 `Host` 區塊（遞迴沿著
`Include` 找到正確檔案，萬用字元 `Host` pattern 永遠不會被當成配對——與 Unix 版
`_ssh_cfg_py` helper 相同規則，但改用純 PowerShell 重新實作，不依賴 `python3`），否則就
附加一個全新的別名區塊。

**會先解析 ProxyJump 鏈。** `ssh(1)` 會透明地穿過跳板 (jump host)，所以只設定最終目標
會讓跳板永遠都要求密碼。精靈會遞迴解析 `ssh -G <target>` 的 `proxyjump`（跳板本身也可能
有自己的 `ProxyJump`），然後對每一跳都由外而內重跑一次整套流程——跳板只需要「安裝金鑰」
與「接進本機設定」這兩步，永遠不需要複製金鑰對，因為 ProxyJump 的驗證是從這台機器對最終
目標端對端完成的，跳板完全不會碰到私鑰。

**私鑰旁邊缺 `.pub` 不是致命錯誤，而是可修復的。** 選到一把遺失公鑰的金鑰（部分複製、
只從 agent 匯入過）時，精靈會當場提議執行 `ssh-keygen -y`，而不是讓安裝步驟深處才失敗。

有兩件事和 POSIX 那一側真的不一樣，原因都是 Windows OpenSSH 沒有內建 `ssh-copy-id`：

- 公鑰是透過 `ssh … -EncodedCommand …`（base64 UTF-16LE）在遠端執行一小段 PowerShell
  程式附加上去的，這樣沿途不會有任何環節把引號搞亂。
- **也會偵測遠端是不是 Windows。** 若該帳號屬於遠端的 Administrators 群組，sshd 預設的
  `Match Group administrators` 規則**只會**讀取
  `C:\ProgramData\ssh\administrators_authorized_keys`——寫進 `~/.ssh/authorized_keys`
  的金鑰會被悄悄忽略——所以精靈會寫入該檔案，並把它的 ACL 重設為僅
  Administrators+SYSTEM（sshd 會拒絕權限更寬鬆的檔案）。

### 為什麼是減少連線次數，而不是連線多工

Unix 那一側會為每一跳開一個 `ControlMaster`，讓整條鏈每跳只需輸入一次密碼。
**這在 Windows 上做不到**：Windows OpenSSH 客戶端不支援 `ControlMaster` /
`ControlPath`（`ssh -o ControlPath=… -O check` 會回
`getsockname failed: Not a socket`，詳見
`pitfalls/win32-openssh-no-connection-multiplexing.md`）。不要加這些選項，它們沒有作用。

真正能動的只有「減少連線次數」，所以探測會跟安裝合併成同一次連線：

| 遠端 | 第 1 步所需連線數 |
|---|---|
| POSIX | 1 —— `uname -s` 併進 `authorized_keys` 的附加指令前面 |
| Windows | 2 —— 先試 POSIX，再用一支 PowerShell 程式同時完成 Administrators 判定**與**安裝 |

這也是為什麼 `administrators_authorized_keys` 的問題改成**一開始就問**、而且用條件句
描述，而不是夾在探測與安裝中間：本機的回答只是一個*策略*，遠端會再和該帳號真正的群組
成員身分做 AND。因此在非管理員的機器上回答「是」是安全的。

### 某一跳失敗時

金鑰安裝失敗不再中止該跳剩下的步驟。它會跳過金鑰對複製——把私鑰推到一台連驗證都過不了
的機器上毫無意義——但仍然會提供**本機** `~/.ssh/config` 的編輯，這件事不論遠端連不連得
上都有用。`ssh` 自己的 stderr 會被印出來而不是丟掉，所以連線層的錯誤會直接說明原因，而
不是偽裝成「無法辨識遠端作業系統」。

有真正的主控台時，提示會走 `Read-Host`（因此經過 PSReadLine），方向鍵是移動游標而不是
插入跳脫序列；stdin 被重導時則退回原本的讀取方式。

環境變數（與 Unix 側同名）：`SSH_SETUP_ASSUME_YES=1` 讓每個提示都取預設值、
`SSH_SETUP_KEY=<path>` 跳過金鑰選擇、`SSH_CFG_ROOT`／`SSH_SETUP_HOME` 可改指到別的設定
樹／金鑰目錄（給 `tests/SshSetup.Tests.ps1` 用，日常操作不需要）。
