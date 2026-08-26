# 使用 Pester 測試 PowerShell

[Pester](https://pester.dev/) 是 PowerShell 的測試與 mock framework。它可以執行
PowerShell 測試檔、透過 `Should` 提供斷言 (assertion)，也能用 mock 替換指令，讓
腳本在不改動真實機器的情況下接受測試。本 repo 用它保護 PowerShell function、render
後的 template、merge 行為，以及只靠人工檢查很容易漏掉的 regression。

上游原始碼與完整參考資料請見
[Pester GitHub repository](https://github.com/pester/Pester) 與
[官方文件](https://pester.dev/docs/quick-start)。

## 安裝與執行

若目前使用者尚未安裝 Pester：

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser
```

在 repo 根目錄執行整套測試或單一檔案：

```powershell
# 全部測試
Invoke-Pester -Path ./tests

# 單一測試檔，顯示每個 test 的結果
Invoke-Pester -Path ./tests/GitConfig.Tests.ps1 -Output Detailed

# CI 使用的形式
Invoke-Pester -CI -Path . -Output Detailed
```

測試檔以 `*.Tests.ps1` 結尾並放在 `tests/`。Windows CI 會安裝 Pester，完成
chezmoi render 與 PowerShell parse 檢查後，再執行所有符合命名規則的測試。

## 測試的基本結構

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'gitconfig-merge.ps1')
}

Describe 'Merge-GitConfig' {
    Context 'empty live configuration' {
        It 'emits the managed baseline' {
            $result = Merge-GitConfig -BaselineText $baseline -LiveText ''

            $result | Should -Match 'autocrlf = input'
            $result | Should -Not -Match 'hooksPath'
        }
    }
}
```

主要 building blocks：

| 區塊 | 用途 |
|---|---|
| `Describe` | 把同一個 function、script 或行為的測試分成一組。 |
| `Context` | 在 `Describe` 內依 scenario 再分組；可省略。 |
| `It` | 定義一個可觀察行為及其預期結果。 |
| `BeforeAll` / `AfterAll` | 在目前 scope 只執行一次 setup 或 cleanup。 |
| `BeforeEach` / `AfterEach` | 在每個 `It` 前後執行 setup 或 cleanup。 |
| `BeforeDiscovery` | 準備 Pester discovery 階段需要的資料，例如 `-Skip` 判斷。 |

每個 `It` 應聚焦一個行為。測試名稱最好能接在「it …」後面讀成一句話，例如
「it preserves unmanaged keys」或「it does not rewrite an aligned file」。

## 使用 `Should` 斷言

Pester 把實際值經 pipeline 傳給 `Should`：

```powershell
$result.ExitCode | Should -Be 0
$text | Should -Match 'expected pattern'
$items | Should -HaveCount 2
$path | Should -Exist
{ Invoke-RiskyParser $text } | Should -Not -Throw
```

本 repo 常用的 assertions：

| Assertion | 檢查內容 |
|---|---|
| `Should -Be` | 值相等。 |
| `Should -BeExactly` | 字串完全相等，包含大小寫。 |
| `Should -Match` / `-Not -Match` | regular expression 是否匹配。 |
| `Should -Contain` | collection 是否包含指定項目。 |
| `Should -HaveCount` | collection 大小。 |
| `Should -BeTrue` / `-BeFalse` | Boolean 結果。 |
| `Should -Exist` | 檔案或目錄是否存在。 |
| `Should -Throw` / `-Not -Throw` | script block 是否丟出錯誤。 |

若 invariant 無法從 assertion 本身看懂，可加 `-Because`；失敗時這段原因會出現在
輸出中：

```powershell
$missing.Count | Should -Be 0 -Because 'every init prompt needs a CI flag'
```

## 用 mock 隔離外部副作用

Mock 只在測試 scope 內替換指令，可避免測試真的呼叫網路、service、installer 或 live
filesystem：

```powershell
Describe 'Start-WorkerIfNeeded' {
    BeforeEach {
        Mock Test-WorkerReady { $false }
        Mock Start-Sleep {}
        Mock Start-Worker {}
    }

    It 'starts the worker when it is not ready' {
        Start-WorkerIfNeeded

        Should -Invoke -CommandName Start-Worker -Times 1 -Exactly
    }
}
```

比起 mock 每個內部 function，更建議在 external program 外圍建立一個小 wrapper／seam
並 mock 那一層。本 repo 的 SSH 與 pueue 測試就採用這個方式：parser 與 state transition
仍執行真實邏輯，remote SSH、service、sleep 與 process 呼叫則由 mock 取代。

## 本 repo 採用的測試模式

### Dot-source 真實 implementation

在 `BeforeAll` 載入一般 `.ps1`，確保測試的是實際 shipping code：

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'gitconfig-merge.ps1')
}
```

若目標是 `.ps1.tmpl`，可優先把可重用邏輯抽到普通 `.ps1`，再由 template include。
這樣不需要真的在 Windows apply，也能直接測到相同 implementation。

### 以文字檢查 render policy

有些測試會把 template 或 config 讀成 raw text，再檢查不可破壞的規則。這很適合
驗證 gate、package list，或原本需要真實 Windows host 才能觀察的設定：

```powershell
$template = Get-Content -Raw $templatePath
$template | Should -Match 'Start-PueuedIfNeeded -InstallService'
$template | Should -Not -Match 'core\.hooksPath'
```

### 使用暫存 fixture

在獨立的 temporary directory 建立測試檔案，並於 `AfterEach` 移除。不要把開發者真實
的 `$HOME`、registry、credential、SSH config 或 application settings 當成 fixture。

```powershell
BeforeEach {
    $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
}

AfterEach {
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}
```

### 將重複案例參數化

如果行為相同，只有輸入與預期輸出不同，可使用 `-TestCases`：

```powershell
It 'parses <Input>' -TestCases @(
    @{ Input = 'host:22'; Host = 'host'; Port = '22' }
    @{ Input = 'alias';   Host = 'alias'; Port = '' }
) {
    param($Input, $Host, $Port)

    $result = Split-Target $Input
    $result.Host | Should -BeExactly $Host
    $result.Port | Should -BeExactly $Port
}
```

Pester 一律把 test name 裡的 angle brackets 當作 data placeholder。只有名稱確實是
`-TestCases` key 時才使用；`<->`、`<T>` 或 `<div>` 這類文字可能被當成無效 placeholder
執行，導致整個 test block 在 assertion 開始前就失敗。

!!! note "Discovery 早於 test execution"
    用來建立 test 或判斷 `-Skip` 的值必須在 discovery 階段就存在，因此應放在
    `BeforeDiscovery`，不要放在 `BeforeAll`。Dot-source implementation 等 runtime
    setup 則屬於 `BeforeAll`。

## 新增 regression test

修 bug 時，加入能重現舊錯誤的最小測試：

1. 新增或擴充 `tests/<Feature>.Tests.ps1`。
2. 在 `BeforeAll` 載入 production implementation。
3. 準備 deterministic fixture，只 mock 外部副作用。
4. 呼叫待測行為。
5. Assertion 同時涵蓋預期結果與重要的 negative condition。
6. 先執行單檔，再執行 `Invoke-Pester -Path ./tests`。

若變更也涉及 template，最後仍要跑本 repo 的 isolated chezmoi render/parse validation。
兩者作用不同：render 確認生成的 PowerShell 語法有效；Pester 則確認行為與 invariants
仍然正確。
