# 設計取捨

說明此設定為何這樣選擇。

## PowerShell 7，而非 cmd/DOS

`cmd.exe`（DOS 血統的 shell）沒有像樣的腳本能力：沒有真正的函式、沒有結構化資料、
引號處理很彆扭。**PowerShell 7（`pwsh`）** 是 Windows 上的現代預設 —— 物件管線、
真正的模組、跨平台，而且此處每個工具都有一流的 `init` 整合（starship、zoxide、
atuin、fzf、direnv）。Windows PowerShell 5.1 雖然內建但已凍結；我們安裝並鎖定 pwsh 7。

（WSL 很好，但它是 Linux 環境 —— 由跨平台 dotfiles 處理，不在此 repo。這個 repo
的重點是一個好用的*原生* Windows shell。）

## scoop 管 CLI + winget 管應用程式，而非 Chocolatey

| | scoop | winget | Chocolatey |
|---|---|---|---|
| 需要系統管理員 | 否（使用者層級） | 機器層級應用程式才需要 | 通常需要 |
| 擅長 | CLI/開發工具 | GUI/Store 應用程式 | 廣泛的舊套件涵蓋 |
| 可重現 | `scoop export/import` | `winget export/import` | `packages.config` |
| 更新方式 | `scoop update *` | `winget upgrade --all` | `choco upgrade all` |

**scoop** 把開發 CLI 裝到每個使用者自己的目錄，**不會跳 UAC**、易於鎖版本、
移除乾淨 —— 非常適合這裡約 20 個 shell 工具。**winget** 是微軟官方管理器，對 GUI
應用程式與第一方安裝程式（VSCode、PowerToys、Steam…）的目錄最完整。

**Chocolatey** 長期以來是預設選擇，套件涵蓋也最廣，但它偏重系統管理員權限、對
每使用者的開發設定較不可重現。它保留為備援，只在 scoop 與 winget 都缺的少數套件才用。

## Runtime：scoop 原生，而非 Windows 上的 mise

macOS/Linux dotfiles 用 **mise** 管理語言 runtime。在 Windows 上我們試過後放棄了
—— runtime 改用 **scoop 原生安裝**（Python 交給 **uv**）。

mise 在這裡撐不住的原因：

- **shims / activate 無法可靠地把全域工具放上 PATH。** `mise activate` 的 pwsh
  prompt-hook 與 shims 目錄實測都沒把全域鎖定的工具（`bun`、`go`）放上 PATH ——
  `mise use -g bun`「成功」了，但 `bun` 卻找不到。
- **架構缺口。** 在 Windows-on-ARM 上，`mise use -g bun` 記了版本，卻沒有
  windows-arm64 的 bun 二進位，留下一個死掉的 shim。
- **與機器既有的 node 打架。** 既有的 `nvm` 蓋掉了 mise 的 node，npm 用錯了。

scoop 的 shims 在 `~/scoop/shims`，scoop 會把它寫進 user PATH（`profile.d/00_env.ps1`
也會前置），所以 `node`（`nodejs-lts`）、`bun`、`go`、`rustup`、`ruby` 就直接
**在 PATH 上**，不用 activate 那套。**Python** 由 uv 管理（`uv python install
--default`），同時把 `python`/`python3` 放到 `~/.local/bin`。

代價是：**沒有 per-project 的 runtime 鎖版本**（mise 的招牌功能）。對 Windows 開發機
而言，換來「工具真的在 PATH 上」是划算的。若你要 per-project 版本，`scoop install
mise` 自己直接用 —— 這裡沒有任何東西依賴它。完整除錯過程見
`backlog/windows-arm64-managed-machine-rough-edges.md`。

## 終端多工器：WezTerm，而非 tmux/zellij

`tmux` 與 `zellij` 是**只有 Unix** —— 沒有原生 Windows 版 —— 所以此處沒有（你仍可在
WSL 裡跑）。要在 Windows 上取得類 tmux 體驗，選項是：

| 選項 | 分割/分頁 | 卸離+保留 | 備註 |
|---|---|---|---|
| **WezTerm** | 有（panes/tabs、Lua `wezterm.mux`） | 有（mux server + `wezterm connect`） | 原生 Windows；最接近 tmux |
| Windows Terminal | 有（panes/tabs） | 無 | 很好的終端，但無 session 保留 |
| Alacritty | 無 | 無 | 快、極簡；搭配多工器用 |
| tmux / zellij | — | — | 只有 Unix；在 WSL 裡用 |

我們安裝 **WezTerm**（`wez.wezterm`）作為多工器的答案：原生 Windows 終端、內建多工器
—— 分割 panes、分頁，以及可卸離再重連的常駐 mux server（`wezterm connect`），還能用
Lua `wezterm.mux` API 腳本化版面。它不是 1:1 的 tmux（session/保留模型不同），但已是
最接近的原生體驗。Windows Terminal 保留給 panes/tabs；Alacritty 保留為快速極簡選項。

## starship，而非 oh-my-posh

兩者都是 prompt 引擎；同時用是多餘的。我們選 **starship**，因為完全相同的
`starship.toml` 已經在 macOS 與 Linux dotfiles 上運作 —— 一份設定、到處一致
（`starship init powershell`）。oh-my-posh 很優秀、也很 PowerShell 原生，但採用它
等於要多維護一份只給 Windows 用的 prompt 設定，卻沒有實質好處。

## 平行的 PowerShell 樹，而非移植 shell 層

macOS/Linux dotfiles 有一大層 POSIX `shell/*.sh`。把它機械式翻成 PowerShell 會變成
維護黑洞（同一套邏輯的兩種方言逐漸走鐘）。因此 PowerShell 設定是在
`profile.d/*.ps1` **原生撰寫** —— 道地的 pwsh，只共享*行為*，不共享程式碼。

## 原生 `copilot-proxy`，而非 bash shim

`copilot-proxy` 工具系列被改寫為真正的 PowerShell 模組（`Invoke-RestMethod`、
`Start-Process`、`ConvertFrom-Json`），而不是去呼叫原本的 bash。只有 Bun 節流 shim
（純 JS）原封不動沿用。見 [copilot-proxy](copilot-proxy.md)。

## XDG 路徑，而非 `%APPDATA%`

Windows 與 XDG 用不同的軸切目錄 —— Windows 看資料夾是否*漫遊*
（`AppData\Roaming` vs `AppData\Local`），XDG 看*用途*（config / data / state /
cache）—— 所以 `%APPDATA%` 並不是乾淨的「Windows 版 XDG」。與其硬對應，
`profile.d/00_env.ps1` 直接把 `XDG_CONFIG_HOME` 等設成 Unix 風格的
`~/.config` / `~/.local/share`。吃 XDG 的工具（starship、atuin、zoxide、yazi）
於是維持乾淨的 `$HOME`，與 macOS/Linux dotfiles 一致 —— 一套心智模型、共用設定。
那些忽略 XDG、硬寫死 `%APPDATA%` 的 app（VSCode、Cursor、Alacritty）就留在原處、
於該路徑管理。完整對照與 `PATH` 機制見 [Shell 環境](shell.md)。
