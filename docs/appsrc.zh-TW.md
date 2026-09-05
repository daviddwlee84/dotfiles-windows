# CLI 來源與衝突

`appsrc` 回答：**目前 shell 會用哪一份、來源判定有什麼證據、還有哪些副本？**
它是原生 PowerShell 7.4+ 工具，不依賴 Python；介面借用 parent repo 的
[`appsrc`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_dotfiles/bin/executable_appsrc)，
但這版刻意只處理 CLI，不包含 GUI 清單、容量統計或 TUI。

## 使用方式

```powershell
appsrc lazygit                       # 等同 appsrc which lazygit
appsrc git
appsrc which -Path 'C:\Program Files\Git\cmd\git.exe'
appsrc scan                         # 不給參數也會 scan
appsrc scan -Conflicts
$report = appsrc scan -Conflicts -Json | ConvertFrom-Json
$report.Groups | Select-Object Name, Installations, Findings
```

profile 只註冊延遲載入的入口，不會在 shell 啟動時掃描。若要檢查無 profile
的環境，可以明確 import `~/.config/powershell/modules/AppSource/AppSource.psd1`，
再呼叫同介面的 `Invoke-AppSource`，或回傳物件的 `Get-AppSourceReport -Name git`。
它不會為了模擬 profile 而修改 PATH，回報的是診斷程式自己的 process。

## 如何閱讀結果

- **Resolution** 是目前 PowerShell 的命令解析，包含已載入的 alias、function
  和 cmdlet。不列出函式完整內容，也不會為了探索而自動 import 其他 module。
  alias target 是命令名稱，不代表另外安裝了一份執行檔。
- **ProcessPathCandidate** 是排除 shell wrapper 的 PATH 候選；
  **PersistedPathCandidate** 模擬 Machine PATH 接 User PATH。這不是已運行的
  IDE／GUI／Herdr server 的環境實測；明確指定路徑或 cmd.exe 的解析也可能不同。
- **Candidates** 保留 `.exe`、`.cmd`、`.ps1` 與實體路徑；**Installations**
  合併已知同一套件、link 及可辨識的 shim。版本取自套件、安裝登錄或 PE metadata，
  不會執行 `--version`；無法取得就留空。
- **Confidence／Evidence** 區分直接證據與目錄推測。Chocolatey 二進位 shim
  只有在套件 snapshot 裡存在唯一同名執行檔時才推測 target。Uninstall registry
  的紀錄不能證明最初由 winget 或 Chocolatey 安裝。
- **Findings** 包含多份安裝、process／持久 PATH 不一致、shell wrapper 及不可用
  target。虛擬環境的 `ExpectedOverride=true`、Windows 系統副本、刻意設定的 alias
  都不等於應該刪除。不同版本也不會自動被稱為過時或有漏洞，因為沒有查詢線上版本。

## 安全界線與限制

這是本機唯讀診斷：不執行候選程式、不啟動 Store alias、不 evaluate shim、
不呼叫套件管理器、不卸載、不修改 registry／PATH。只檢查 PATH 目錄與已知的
管理器 metadata，不掃整顆磁碟；跳過 UNC PATH 目錄，單一 metadata 讀取上限為
2 MiB。缺少管理器、殘留紀錄、無法讀取的目錄與失效 link 不會中斷其他結果。
JSON 將警告放進資料，文字模式另外顯示。

Scoop／Chocolatey 具有套件層級辨識，支援自訂根目錄；WinGet links、標準 npm
shim、uv／pipx、Cargo、.NET tools 與 Windows 目錄依本機可取得的證據判定。
自訂 launcher 或安裝位置可能仍是 unknown，不應僅憑檔名猜套件歸屬。

## 移除舊安裝之前

2026 年 9 月的本機檢查發現 Scoop／Chocolatey 同時存在 LazyGit、Git、fzf、glow，
Node／Python 也有其他位置。互動 pwsh 的 PATH 排序可能讓問題不明顯，但長期
運行的 server 仍可能使用另一份。Herdr 專用 `prefix+G` launcher 處理這個環境
界線，詳見 [Shell](shell.md)。

先在發生問題的環境執行 `appsrc <command>`。卸載前確認套件歸屬、相依套件、
服務、排程、明確指定的路徑及設定。不同 Git 發行版可能有不同的 system TLS／
credential 設定；OpenSSH 可能綁定服務。Chocolatey 獨有工具應先確認替代品可用。
本次實作不會自動清除這些安裝。
