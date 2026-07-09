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
| `20_aliases.ps1` | alias 與 helper（`reload`、`cas`/`cau`、git 快捷） |
| `30_apps.ps1` | app 控制（`applaunch`/`appquit`/…）、音量、剪貼簿 |
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
