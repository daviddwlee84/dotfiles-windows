# 輸入法（Rime / 小狼毫）

[Rime](https://rime.im/) 在 Windows 上的發行版叫 **小狼毫（Weasel）**。這是選用功能 ——
在 `chezmoi init` 時對 `Install the Rime input method (Weasel) for Traditional Chinese`
回答 yes，或之後到 `%USERPROFILE%\.config\chezmoi\chezmoi.toml` 改 `installInputMethod`。

比較有意思的不是安裝，而是**引擎層設定與跨平台 macOS/Linux repo 逐位元組共用**，
所以注音與拼音在小狼毫、鼠鬚管（macOS）、ibus-rime（Linux）上行為完全一致。

## 哪些共用、哪些不共用

`.chezmoitemplates/rime/` 放可攜的本體，各平台的 renderer 只有一行
`{{ template "rime/<檔名>" . }}`。

| 檔案 | 範圍 | 原因 |
|---|---|---|
| `default.custom.yaml` | **共用** | `schema_list`、`menu/page_size` —— 引擎層，與前端無關 |
| `luna_pinyin.custom.yaml` | **共用** | 方案 switch patch —— 引擎層 |
| `weasel.custom.yaml` | 僅 Windows | `style/` 是小狼毫專屬，`app_options` 以 **EXE 檔名**為 key |
| `squirrel.custom.yaml` | 僅 macOS | `app_options` 以 **bundle id** 為 key |
| `user.yaml`、`installation.yaml`、`build/`、`*.userdb/` | **完全不納管** | 執行時狀態 |

部署位置：

| 平台 | 前端 | 使用者資料夾 |
|---|---|---|
| Windows | 小狼毫 Weasel | `%APPDATA%\Rime` |
| macOS | 鼠鬚管 Squirrel | `~/Library/Rime` |
| Linux | ibus-rime | `~/.config/ibus/rime` |

之所以能共用：**小狼毫與鼠鬚管內建的方案集完全相同** —— 兩邊都是用 plum 的
`:preset` 套件組建的（`bopomofo`、`cangjie`、`luna-pinyin`、`terra-pinyin`、
`stroke`、`quick`、`essay`、`prelude`）。我們 `schema_list` 裡的每個方案在三個平台
上都已經存在，套用時不會下載任何東西。

!!! note "修改共用檔案的流程"
    兩個 repo 各存一份。改其中一份，複製到另一份，再 `diff` 兩者 —— 那個 diff
    **就是** drift 檢查。把它們抽成第三個 repo 用 `.chezmoiexternal` 拉，已記在
    `TODO.md`。

## 輸入方案

`Ctrl+`` ` 開啟方案選單：

| 方案 | |
|---|---|
| `bopomofo_tw` | 注音·臺灣正體（預設） |
| `bopomofo` | 注音 |
| `luna_pinyin` | 朙月拼音 —— 已 patch 成臺灣字形 |
| `terra_pinyin` | 地球拼音（帶聲調） |
| `cangjie5` | 倉頡五代 |

要增減或調整順序，改**兩個 repo** 的 `.chezmoitemplates/rime/default.custom.yaml`。
內建集合以外的方案要用 plum 抓（右鍵托盤圖示 → 輸入法設定 → 獲取更多方案）。

## Windows 專屬行為

`weasel.custom.yaml` 設定了：

- **字型 fallback**。小狼毫會用逗號切開 `font_face` 成為真正的 DirectWrite fallback
  chain，所以英數用 `Hack Nerd Font Mono`（本 repo 通用的終端機字型），中文 fallback
  到 `Microsoft JhengHei UI`。
- **`global_ascii: true`** —— 所有應用程式共用一個中／英狀態，而不是各視窗獨立。
  **鼠鬚管做不到這件事**（`rime/squirrel#201`、`#1054` 都是關閉未合併），所以這是
  Windows 才有的好處，macOS 那份刻意沒有這個設定。
- **各應用程式的 `ascii_mode`**：pwsh、Windows Terminal、Alacritty、WezTerm、herdr、
  nvim、VSCode、Cursor。這些是在新 session 繼承全域 ASCII 狀態**之後**才套用的，
  所以終端機與編輯器維持英文，其他程式跟著共用的中／英開關走。

`Install-Weasel` 另外會跑 `WeaselSetup.exe /toggleascii`，讓 `Ctrl+Space` 切換的是
ASCII 而不是整個輸入法的開關 —— 這才讓 `global_ascii` 用起來像單一的中／英鍵。

## 改完設定要重新部署

Rime 只有在**重新部署**時才會吃進 `*.custom.yaml` 的修改。`chezmoi apply` 會自動處理：
`run_onchange_after_50_rime_deploy.ps1` 在任何一份納管的 Rime YAML 變動時重新觸發，
執行 `WeaselDeployer.exe /deploy`。

手動的話：

```powershell
$dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Rime\Weasel' -Name InstallDir).InstallDir
& "$dir\WeaselDeployer.exe" /deploy
```

……或右鍵托盤圖示 → 重新部署。

另外兩個平台維持手動（鼠鬚管的 `--reload` 不夠可靠，`ibus restart` 會打斷當前輸入）：

```bash
# macOS
/Library/Input\ Methods/Squirrel.app/Contents/MacOS/Squirrel --reload
# Linux
touch ~/.config/ibus/rime/ && ibus restart
```

## `WeaselSetup.exe` 命令列參數

upstream 沒有文件，但確實存在（讀 `WeaselSetup/WeaselSetup.cpp` 得到）。下面每個
參數都只寫 `HKCU`，所以**都不需要提權**：

| 參數 | 效果 |
|---|---|
| `/t` / `/s` | 把 TSF 服務（重新）註冊為繁體 / 简体 —— **需要 admin** |
| `/lt` `/ls` `/le` | 小狼毫自己的 UI 語言：繁體 / 简体 / English |
| `/userdir:<dir>` | 把 Rime 使用者資料夾搬離 `%APPDATA%\Rime` |
| `/du` / `/eu` | 關閉 / 開啟自動更新檢查 |
| `/toggleascii` | `Ctrl+Space` 切換 ASCII 而非整個輸入法 |
| `/toggleime` | 上一項的反向 |

`WeaselDeployer.exe` 接受 `/deploy`、`/dict`、`/sync`、`/install`。它是用單純的字串
比對判斷參數，所以只能傳剛好一個參數；而且它持有一個互斥鎖 —— 同時跑第二個部署會
直接 exit 1。

## 陷阱

!!! warning "安裝會跳 UAC"
    `Rime.Weasel` 的 winget manifest 是 machine scope 的 NSIS，所以 `--scope user`
    永遠不會成功。開著 `installInputMethod` 套用時會要求提權，跟 WSL2 與 OpenSSH
    server 那兩個開關一樣。

!!! warning "單純的靜默安裝會註冊成简体中文"
    winget 對 NSIS 的靜默參數是 `/S`，而小狼毫的 `install.nsi` 把單獨的 `/S` 對應到
    `WeaselSetup.exe /s` —— 简体。`Install-Weasel` 用 `--custom '/T'` 蓋掉這個行為。
    如果你曾經手動裝過小狼毫，裝完請到「設定 › 語言」確認，顯示简体的話跑
    `WeaselSetup.exe /t`。見 `pitfalls/weasel-silent-install-registers-simplified-chinese.md`。

!!! note "自動更新檢查維持關閉"
    靜默安裝會寫入 `CheckForUpdates=0`。我們不納管這個機碼；想要小狼毫自己的更新
    檢查就跑 `WeaselSetup.exe /eu`，不然 `just upgrade-winget` 也涵蓋得到。

!!! note "執行時檔案刻意不納管"
    Rime 不會回寫 `*.custom.yaml` —— 切換狀態與最近使用方案是寫進 `user.yaml`
    （`var/option/…`、`var/previously_selected_schema`）。所以這些可以是一般的
    managed file，不需要像 herdr 的設定那樣用 `modify_` overlay。`build/`、
    `installation.yaml`、`user.yaml`、`*.userdb/` 完全不會被碰到。
