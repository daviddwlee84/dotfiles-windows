# Microsoft Organization profile

適用於 IT 會封鎖 Scoop 程式或 shim 的 Windows 工作機，需明確 opt-in。
使用來源清單中的 winget 套件與官方安裝程式，保留公司 npm/PyPI 政策；未核准的
來源列為待處理，不自動換下載管道。**不修改 App Control、Defender、execution
policy、TLS、認證或組織受管設定。**

## 選擇 profile

`organizationProfile = "none"`（缺少 key 也相同）維持一般 Scoop 流程；
`"microsoft"` 與 `role`、功能開關、`managedMachine` 分開。既有 managed machine
不會被自動遷移。新 Microsoft 初始化的 managedMachine 預設 true，既有明確答案
仍保留。公司套件操作需要這個開關；public fallback 仍獨立、預設關閉，且只處理
原本允許的暫時性錯誤。

### 全新 Microsoft 工作機：從內建 PowerShell 5.1 到全量 apply

不需要先手動安裝 pwsh，也不需要分次 apply。確認範圍後，在 **內建 Windows
PowerShell 5.1** 執行已檢查的本版本 bootstrap（已有 checkout 時帶 `-Source .`）：

```powershell
powershell.exe -NoProfile -File .\bootstrap.ps1 -Source . -OrganizationProfile microsoft
```

新機的非互動 workstation 模式也受支援；姓名與 email 請換成自己的值：

```powershell
powershell.exe -NoProfile -File .\bootstrap.ps1 -Source . `
  -OrganizationProfile microsoft -NonInteractive -Role workstation `
  -Name 'Your Name' -Email 'you@example.com'
```

若只有 bootstrap 檔、沒有 checkout，省略 `-Source .` 便會透過 chezmoi 取得 repo；
來源 branch 必須包含本功能。尚未推送的本機 commit 請用 checkout，不要誤用舊版遠端 main。
非 Microsoft 的 unattended 模式仍只允許明確的 `-Role minimal`。

Bootstrap 的順序是：

1. 找到 IT 允許的 App Installer/winget；除了 PATH，也讀取已註冊的 App Installer。
   全新 Windows 11 通常已提供它；若被 IT 移除／停用，先由 IT 配發，不另裝未核准的 manager。
2. 用 `Microsoft.PowerShell` 官方 WinGet package 安裝新版 pwsh，與內建 5.1 並存。
   保留 provider 的架構選擇，**不強制 x64、ZIP 或繞過簽章／政策**。
3. 在同一 session 重新解析穩定的 MSIX alias、MSI 安裝路徑／登錄資訊，驗證 Core >=7.4。
   PowerShell 7.6 的 WinGet 預設是 MSIX，不能假設只有 `Program Files\PowerShell\7`；
   也不把帶版本號的 WindowsApps package 目錄寫死到設定。
4. 在任何 config modifier 之前備妥並檢查 Git、chezmoi、uv、Bun、Python 與 7-Zip。
   新 Python 使用官方 `Python.Python.3.14` user-scope package（x64／ARM64）；
   沿用可用的既有 Python 時要求 >=3.11，排除會開 Microsoft Store 的內建假入口。
   Python 路徑保存為 `pythonExecutable`，供 Herdr 合併和 uv 使用。
5. 先初始化設定，確認 `organizationProfile=microsoft`、來源清單與 runtime 路徑
   確實保存，再 **全量 `chezmoi apply`**，不需要重開終端或手動補裝依賴。

「全量」代表完整部署所有設定和已核准、已選擇的工具；不是把所有選用開關強制打開，
也不把未核准插件變成已核准。待核准／尚無 adapter 的項目仍明列。
必要 runtime 安裝／執行被拒絕時，bootstrap 停在 apply 前，不換來源重試。
不初始化 Scoop、不改 execution policy；若組織要求簽署腳本，使用 IT 的簽署／部署管道。

**既有工作機**不要用完整 bootstrap/apply 當診斷。先使用 `appsrc` 與下面的唯讀
命令盤點，確認已有可用的非 Scoop PowerShell 與 chezmoi，再修改既有 chezmoi
`[data]` 區塊（不要增加重複區塊）：

```toml
organizationProfile = "microsoft"
managedMachine = true
allowPublicPackageFallback = false
powerShellExecutable = 'C:\path\to\approved\pwsh.exe'
nodeExecutable = ''
pythonExecutable = '' # 新機由 bootstrap 保存已選定的官方 runtime
organizationSourceApprovals = []
```

PowerShell 路徑必填，GUI terminal／no-profile 子程序不能 fallback 到 Scoop shim。
範例是佔位路徑，不可直接照抄。Node 優先採用 active NVM4W runtime，再找其他非
Scoop 候選；`nodeExecutable` 可明確指定一組完整的 Node/npm。無效或 Scoop
覆寫會報錯，不偷偷替換。不要複製／改名被封鎖的 binary 來執行。

先預覽 diff、檢查選中／待核准項目，再只 apply 預期的 target。注意 diff 也可能
執行 config modifier；Microsoft 模式關閉未核准的隱式 Python 下載，Herdr 缺少
parser 時保留原設定。

## 來源清單與核准

`.chezmoidata/windows-tool-sources.json` 是 Microsoft adapter、templates 與診斷
共用的完整分類。功能開關表示「想要什麼」，不等於核准它所有插件或 compiler。

| 類別 | 行為 |
|---|---|
| 列入清單的 winget CLI／GUI | 使用精確 ID/source；由 provider 選相容 installer，下載前先查 metadata；無對應或架構不支援會回報。 |
| Herdr 官方安裝程式 | 重用既有已驗證 helper。 |
| Oh My Pi（`omp`） | 與 Oh My Posh 不同；目前僅審視 Windows x64 artifact。 |
| Pi／Python dependencies | 保留公司來源 runner；Pi 關閉 lifecycle scripts 與 npm bin links。Python distribution 是另一個來源。 |
| Git externals、插件、個人 releases、npm native payload chains | 預設 pending-approval，逐一審視後才核准。 |
| 尚無相容實作（Pueue 遷移、compiler、字型、部分個人工具） | 維持 pending／unsupported，不 fallback 到 Scoop 或 source build。核准不會自動產生缺少的 installer。 |

核准使用個別已知 catalog ID，例如 `yazi-plugins`，沒有 wildcard。**確認來源及
下游下載符合 IT 政策之後**，才把 ID 加進 `organizationSourceApprovals`。
未知 ID 會拒絕。Hash 只證明完整性，不證明 IT 核准；公司 registry 也不代表其
postinstall 下載已獲核准。部分來源只完成盤點，尚無自動 adapter，即使核准也會
回報 `unsupported-adapter`。

尚未核准時：Neovim 使用內建功能，不啟動插件/build graph；Yazi 不下載插件；
不抓取 Pi-agents external；Claude 的 repo-owned settings/HUD merger 不新增
marketplaces/hooks，保留 live 設定。這**不會**停用已由使用者或 IT 設定的插件。
Copilot provisioning 需要獨立核准，Microsoft 模式失敗後不換 proxy／CDN 重試。

此 profile 不自動啟用 OS features、WSL distro、sshd/service/firewall。
既有手動管理命令仍是需要明確授權的獨立操作。來源清單不是 sandbox，無法管制
所有第三方 self-updater、其他位置已設定的插件、使用者腳本或 WSL 內的工具。

## Ownership 與遷移

- 不刪 Scoop／Chocolatey 檔案，不改 persisted PATH。Microsoft shell／installer
  只從自己的 process PATH 排除 Scoop roots，包含自訂 `SCOOP`／`SCOOP_GLOBAL`。
  本機 override 若重新加回路徑，應先盤點。
- 不切換 NVM 版本、不搬其他 npm globals。新的 repo-owned npm agents 使用
  `%LOCALAPPDATA%\dotfiles\npm`。已辨識的既有 Pi 可沿用原 prefix 執行，但不
  接管升級；需要時另行確認遷移 ownership。
- 已有其他 owner 的工具不重複安裝；這可能需要先明確遷移，才能讓新 profile 管理更新。
- 不自動搬移 Pueue service／queue、不改 Herdr saved-session path、不卸載 Scoop、
  不換 prompt、不編輯 environment.local 檔案。
- 切換 profile 後開新 approved PowerShell／GUI session；執行中的 Herdr server
  仍保有舊環境與 saved shell 絕對路徑。

## 診斷與升級

```powershell
just organization-doctor
just organization-doctor -OrganizationProfile microsoft -Json # 不改設定的預覽
just organization-doctor -Json
just organization-doctor -Tool pwsh -Probe
just upgrade
```

預設 doctor 使用 `Get-AppSourceReport` metadata，不執行被檢查的程式。
`-Probe` 明確要求有 timeout 的版本檢查，僅支援小範圍、有來源證據的 native commands；
不安裝、不改 PATH、不開服務。Access denied 通常列 launch-failed，只有 OS 明確
表示政策封鎖才列 policy-blocked。版本探測成功不等於完整應用程式測試。

`just upgrade`／`upgrade-winget` 只更新 selected、installed、approved 的項目；
不安裝 missing packages。Component commands 保留 owner，未支援 adapter 會回報。
Microsoft 模式拒絕 `upgrade-scoop` 與 Scoop 字型 installer；winget 失敗時不改
scope/source 重試。

Run-script 報表分開列 installed-unverified、existing-owner-preserved、pending、
unsupported、needs-administrator-session、failed。Apply 非致命完成，不等於所有
選中的工具都已能執行。
