# PowerShell 維護筆記

這份筆記記錄 2026 年 9 月的 runtime／scope 檢查，以及後續腳本應遵守的契約。
這仍是 Windows dotfiles repo，不保證每支腳本都能在 Unix 執行；Unix 編輯流程
透過隔離 render 與測試驗證。

## 兩個執行環境界線

| 範圍 | 契約 |
|---|---|
| `bootstrap.ps1` | 語法與 API 相容 Windows PowerShell 5.1；chezmoi 前先探測目標 pwsh |
| profile、helper、modifier、run-script、tests | PowerShell 7.4+ Core |
| module manifest | `PowerShellVersion = '7.4'`、`CompatiblePSEditions = @('Core')` |
| vendored／產生的第三方程式、外部 hook 命令 | 依原本契約，不機械式批次改寫 |

新的第一方腳本應加入以下 guard；有 shebang 時放在其後：

```powershell
#Requires -Version 7.4
#Requires -PSEdition Core
```

7.4 統一了 .NET 8 與新版 native argument 行為的基準，避免功能無意間依賴
開發者剛好安裝的版本。bootstrap 沿用原安裝政策，只安裝缺少的 pwsh，不默默
升級已存在的安裝；版本低於 7.4 時會拒絕交棒並提供升級提示。

`#Requires` 檢查目前 host，**不會啟動另一個 interpreter**。Windows 的 `.ps1`
副檔名與 Unix shebang 也不會替你選 pwsh。舊 parser 可能先拒絕新語法，例如
5.1 在 7.4 guard 底下仍會回報 `&&` 無效。因此 bootstrap 本身必須完整保持
5.1 可解析，現代腳本則明確透過 pwsh 啟動。
[Microsoft：about_Requires](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_requires)。

### 模板嵌入

同一支解析後的腳本有多個 `#Requires -PSEdition` 會造成 parse error。
可獨立執行的來源保留 guard；外層腳本只移除嵌入文字的 edition directive：

```text
{{ include "scripts/example.ps1" | replace "#Requires -PSEdition Core" "# Core edition is required by the enclosing script." }}
```

純 template 片段（例如 package-source policy）繼承外層的 edition guard。
如果腳本是以**字串資料**嵌入、稍後才執行，則保留自己的 guard。
務必 render 後 parse 最終結果，不能只檢查各個來源檔。

## Scope 也是介面的一部分

在函式裡 dot-source，不會讓載入的函式自動變成 global。`reload`、`cas`、
`cau` 都會從函式 scope 載入 profile，因此公開 helper 與依賴函式必須明確
存活於該 scope 之外，或放在保留的 module 中。基本 aliases／Git helpers
已改為明確的 global 定義。

快取的 tv／dev-cli／translate／pia initializer 包含一般 helper 與 callback
依賴的 `$script:` 狀態，現在每個工具使用一個保留的具名 module，global import；
reload 只替換對應的受管 module。已自行管理 global hook 的 prompt 整合維持
原路徑，不以 regex 改寫任意 upstream 初始化程式。

測試必須在**載入函式返回後**呼叫 helper、實際完成一次補全，再重載一次；
只驗證環境變數會漏掉這類問題。PSReadLine 的 edit-mode reset 必須早於最後
的 key-handler 註冊。不在使用者 shell 全域開啟 StrictMode／Stop，保留 apply
腳本遇到單一錯誤仍繼續的設計。

## Native 參數與子程序環境

`& $exe @argv` 與 `Start-Process -ArgumentList $argv` 不等價；後者會把陣列
序列化成一段字串。需要控制原生 `.exe` 子程序時，優先考慮
`ProcessStartInfo.ArgumentList`；`.cmd`／`.bat` 與 shell expression 要另外
定義契約。新版 PowerShell 的 native argument 處理仍存在 Windows batch／
legacy 例外。[Microsoft：about_Parsing](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing)。

要選擇一個執行檔時，明確取 `Get-Command -CommandType Application` 的第一個
結果；這台多份安裝的主機上，即使不加 `-All` 也回傳了多個候選。不要將整個
`.Source` 陣列轉成單一程序檔名；LazyGit 的回歸測試已覆蓋此情況。

WSL 自我提權現在替腳本路徑加引號，並用目前 pwsh 的絕對路徑。隱藏的子程序
以 unattended 模式運行，不等待看不見的鍵盤輸入；父程序提供狀態／重試指引。
測試使用 mock，不真的提權。

Herdr server 是原生執行檔，不是 PowerShell host。一般 pane 使用設定的 pwsh；
Windows custom command 則透過 `cmd /d /c`，繼承 server 狀態。`prefix+G`
現在只載入受管環境，再以繼承的 terminal I/O 啟動 LazyGit；失敗時保留 cwd、
執行檔路徑與退出碼。不要只為更新 PATH 就停止 server，因為這會結束 pane
程序。可先用 [appsrc](appsrc.md) 比較安裝來源，而不執行候選程式。

## 本次結果與暫緩項目

- 已實作：runtime／manifest 契約、補全 scope 保留、基本 helper reload scope、
  WSL 引號、LazyGit 環境與錯誤界線，以及唯讀來源診斷。
- 依選擇暫緩：`run-for` 仍透過 Start-Process 序列化參數，超時只終止直接子程序。
  改動前應分別定義 `.exe`、`.ps1`、batch shim、退出碼與 process tree 行為，
  覆蓋空格、內嵌引號、空參數及超時清理。
- 其他含私有 `script:` helper 的大型 profile 片段，應先補隔離的 reload 測試，
  再考慮 scope 重構；這次沒有全面轉成 module。
- 不自動移除套件、遷移 registry／PATH、更換 terminal emulator，或臆測性地
  改寫成 .NET／追求效能；保留暖啟動的初始化快取。

驗證包含 `PowerShellRuntime`、`PowerShellInitCache`、`AppSource`、`Bootstrap`、
`GitAliases`、`HerdrLazyGit` Pester 測試、既有完整 suite、PSScriptAnalyzer、
隔離 chezmoi render／parse 與嚴格雙語 docs build。CI 除一般 current-pwsh job，
另驗證 7.4 maintenance release。
