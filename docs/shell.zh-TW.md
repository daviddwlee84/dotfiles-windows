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
| `05_mirrors.ps1` | 中國套件鏡像（啟用時） |
| `10_tools.ps1` | `init` 掛鉤:starship、zoxide、mise、atuin、fzf、direnv、tv |
| `20_aliases.ps1` | alias 與 helper（`reload`、`cas`/`cau`、現代 CLI 替身） |
| `21_git.ps1` | oh-my-zsh `git` plugin alias 移植到 pwsh（`gst`、`gco`、`gl`=pull、`gcam`、`glol`…） |
| `28_tldr.ps1` | `tldrf` —— tldr 加上 `zh_TW → zh → en` 語言 fallback |
| `30_apps.ps1` | app 控制（`applaunch`/`appquit`/…）、音量、剪貼簿 |
| `32_try.ps1` | `tri` —— try (tobi/try) 暫時性日期命名 workspace（選用；沒 ruby 時 inert） |
| `35_yazi.ps1` | `y` —— 開 yazi,離開時 cd 到你停下的目錄 |
| `40_copilot.ps1` | 匯入 `copilot-proxy` PowerShell 模組 |
| `90_psreadline.ps1` | PSReadLine（vi 模式、歷史） |

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

### 我們不用 GUI 就改了 PATH

這個 repo 動 `PATH` 有兩條路,都是腳本 —— 從不打開系統內容的「環境變數」對話框:

1. **持久(登錄檔 User PATH)—— 只有 scoop。** scoop 安裝時會用程式方式把
   `~/scoop/shims` 寫進 User PATH（`[Environment]::SetEnvironmentVariable('Path', …, 'User')`),
   所以 scoop 的 CLI 在*每個* shell 與 GUI app 都找得到 —— 不需管理員、不需對話框。

2. **只在行程內 —— 我們的 profile。** `00_env.ps1` 在每次 shell 啟動時,把
   `~/.local/bin` 與 `~/scoop/shims` 前置到 `$env:PATH`,冪等、且只在目錄存在時:

   ```powershell
   $UserPaths = @(
       (Join-Path $HOME '.local/bin'),
       (Join-Path $HOME 'scoop/shims')
   ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
   foreach ($p in $UserPaths) {
       if (($env:PATH -split ';') -notcontains $p) { $env:PATH = "$p;$env:PATH" }
   }
   ```

`bootstrap.ps1` 還有第三種、一次性的變體:在 scoop 裝完基礎工具後,立刻用
`Machine + User` 的登錄檔值重建 `$env:PATH`,讓剛裝好的 shim 在**同一個 session**
就找得到(scoop 已寫入持久層,但當前行程的複本早於那次寫入)。

!!! warning "`~/.local/bin` 只在 pwsh session 範圍"
    `~/.local/bin` 是你自己 script/binary 在 Windows 的落腳處 —— 路徑名跟 Unix
    一樣。但與 `~/scoop/shims` 不同,它**只**由這份 profile 加進 `$env:PATH`,
    **從不**寫進登錄檔。所以它在載入此 profile 的 pwsh session 內才在 PATH 上,
    在 Windows PowerShell 5.1、GUI app、或任何在 pwsh 外啟動的東西裡都**看不到**。
    若要讓那裡的 binary 全系統可見,請自己把 `~/.local/bin` 加進 User PATH
    （`setx` 或 `[Environment]::SetEnvironmentVariable(…, 'User')`）。

profile 跑完後的解析順序:`~/scoop/shims` → `~/.local/bin` → 繼承來的 PATH
（每個都是前置,所以最後加的排最前）。

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
SpecStory 自動包裝只有在 PATH 上真的有 `specstory` CLI 時才啟用（Windows 目前尚無
原生版，所以 agent 直接原樣執行）。

!!! warning "herdr 仍是 preview/beta"
    herdr 的 Windows 版本是可選的（`installHerdr`）且僅 preview；這些輔助指令驅動它的
    CLI scripting 介面（`herdr workspace|tab|pane`），只能在真正的 Windows 機器上驗證，
    CI 不涵蓋。
