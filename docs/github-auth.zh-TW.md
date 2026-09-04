# GitHub 登入與代理

使用 Clash 時，若瀏覽器或 Git 能連線，但 `gh auth login` 失敗，請在
**即將執行 `gh` 的 PowerShell 視窗**設定代理、完成瀏覽器授權，再讓 Git
使用 GitHub CLI 的憑證。

## 透過 Clash 登入

請使用 Clash 實際的 **HTTP 或 mixed port**。這次驗證使用 `7891`；
它是範例，不是所有 Clash 安裝的預設埠號。

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7891'
$env:HTTP_PROXY = $env:HTTPS_PROXY

gh auth login --hostname github.com --git-protocol https --web
```

詢問是否讓 Git 使用 GitHub 憑證時選 **Yes**，接著在瀏覽器輸入新產生的
一次性代碼並完成授權。看到 `Authentication complete` 後執行：

```powershell
gh auth setup-git --hostname github.com
gh auth status
```

回到要操作的 repo 重試 `git pull`。`gh auth setup-git` 會讓 GitHub 的
credential helper 使用 `gh`，但它本身不會替你登入。
`--hostname github.com` 將設定範圍限定為這個 host。見
[官方指令說明](https://cli.github.com/manual/gh_auth_setup-git)。

即使變數叫 `HTTPS_PROXY`，代理網址仍以 **`http://`** 開頭，因為它指向
Clash 的 HTTP 代理接聽埠，HTTPS 連線透過它建立 tunnel。這兩個變數只影響
目前 shell 及其子程序；若未另行設定，新開終端仍需重新設定。若既有
`NO_PROXY` 將 GitHub 排除，請先調整對應項目再重試。這些指令不會修改
Windows 系統代理，也不會開啟 TUN。

**2026-09-04 Windows 實測：**上述步驟完成登入；`gh auth status` 顯示
active account、憑證存於 keyring、Git protocol 為 HTTPS，後續 `git pull`
已進入接收 Git objects 的階段。

## 為什麼瀏覽器能連，gh 卻失敗？

以下代理機制各自獨立：

| 機制 | 使用範圍 |
|---|---|
| Windows 系統代理 | 遵循 Windows 代理設定的應用程式，包含一般瀏覽器設定。 |
| Git `http.proxy` | Git 的 HTTP(S) 傳輸；不會設定 `gh` 的 OAuth／API 請求。 |
| `HTTP_PROXY`／`HTTPS_PROXY`／`NO_PROXY` | `gh` 使用的 Go HTTP transport。 |
| Clash TUN | 啟用且路由正確時，透過虛擬網卡接管應用程式流量。 |

`gh` 使用 Go 的預設 HTTP transport，其代理查找讀取環境變數，不會直接
沿用 Git 設定或 Windows 系統代理。見
[gh HTTP client 原始碼](https://github.com/cli/go-gh/blob/trunk/pkg/api/http_client.go)及
[Go 代理查找文件](https://pkg.go.dev/net/http#ProxyFromEnvironment)。

這次檢查發現 Windows 系統代理與 Git 代理都指向 Clash，但代理環境變數
尚未設定。當時沒有啟用中的 Clash TUN 網卡，前往 GitHub 的路由走 Wi-Fi
與區域網路閘道，因此既有設定沒有讓 `gh` 的連線經過 Clash。

失敗的是送往 `https://github.com/login/oauth/access_token` 的 POST，
錯誤尾端為：

```text
wsarecv: An established connection was aborted by the software in your host machine.
```

這表示連線中斷，不能據此判定 GitHub 密碼有誤，或指定某個防火牆就是原因。
Microsoft 的
[Winsock 錯誤說明](https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2)
也列出逾時或協定錯誤等可能原因。診斷時短暫的直連請求能成功，並未重現
原本的中斷；後續確認有效的解法是明確設定代理。

若要確認 TUN 是否實際接管路由：

```powershell
Get-NetAdapter -IncludeHidden | Select-Object Name, InterfaceDescription, Status
$githubIPv4 = Resolve-DnsName github.com -Type A |
    Where-Object IPAddress | Select-Object -First 1 -ExpandProperty IPAddress
Find-NetRoute -RemoteIPAddress $githubIPv4
```

檢查選用的網卡與 next hop。錯誤訊息出現公網目的 IP，本身不足以證明繞過
TUN；TUN 的運作層級低於應用程式的 HTTP 代理設定。

## 換了 Git 之後出現 CredentialHelperSelector

`CredentialHelperSelector` 是 Git for Windows 的憑證管理器選擇視窗。
Portable Git 可能預設使用 `helper-selector`，另一套 Git 則已使用
`manager`。因此 PATH 順序改變後，即使以前沒見過，也可能開始出現這個視窗。

```powershell
Get-Command git -All | Select-Object Source
git --version
git config --show-origin --show-scope --get-all credential.helper
```

這次機器上的 `Program Files` Git 2.40 使用 `manager`，Scoop Git 2.55
則使用 `helper-selector`。Scoop 的
[Git 套件說明](https://github.com/ScoopInstaller/Main/blob/master/bucket/git.json)
也有記錄 Portable Git 的 Git Credential Manager 設定方式。

| 選項 | 行為 |
|---|---|
| `manager` | Git Credential Manager：支援 GitHub 瀏覽器登入、MFA 與安全憑證儲存。 |
| `wincred` | 在 Windows 儲存提供給它的憑證，不提供完整的 GitHub 瀏覽器登入流程。 |
| `<no helper>` | 不透過 credential helper 取得或儲存憑證。 |

選擇一般 Git credential helper 時，建議選 **`manager`** 並勾選
**Always use this from now on**。見
[GCM 文件](https://github.com/git-ecosystem/git-credential-manager)。
對 GitHub 而言，上方 `gh auth setup-git` 會設定 host 專屬的 helper，
使用已完成的 `gh` 登入。單純選擇 `manager` 不會讓獨立的 GitHub CLI
應用程式也登入。

若 Git 回報 `Invalid username or token` 以及
`Password authentication is not supported for Git operations`，代表沒有
取得有效 token。請完成上述登入與 helper 設定；GitHub 帳號密碼不能用來
驗證 HTTPS Git 操作。chezmoi 的 Git 疊加設定會保留這些憑證設定；見
[Git 設定](setup.zh-TW.md#git)。
