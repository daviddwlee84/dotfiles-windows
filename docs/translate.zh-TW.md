# translate

[`translate`](https://github.com/daviddwlee84/translate) 是一個終端機翻譯工具 ——
可以在 shell 裡一次性翻譯，也可以進互動式 TUI；背後是一條 fallback 鏈，串起本機
LLM provider、免費的網頁 API，以及離線雙語辭典。

跨平台的 [dotfiles](https://github.com/daviddwlee84/dotfiles) 在 macOS（Homebrew tap）
與 Linux（`go install`）都已經裝了同一個工具，這個 repo 從 Scoop bucket 裝它。

用 **translate** 這個 init 提問開啟（`workstation` role 預設開）。

## 安裝方式

從作者自己的 Scoop bucket 安裝 —— 預先編譯好的執行檔，幾秒鐘就好，不需要 Go
toolchain：

```powershell
scoop bucket add daviddwlee84 https://github.com/daviddwlee84/scoop-bucket
scoop install daviddwlee84/translate
```

打開 **translate** 開關後，`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
會替你做完這兩步。

- 上游 repo 的 release workflow 每打一個 tag 就交叉編譯 **windows/amd64** 與
  **windows/arm64**（它是純 Go —— `modernc.org/sqlite`，不需要 cgo），再由
  GoReleaser 把 manifest 推到 bucket。
- 執行檔會以一般的 scoop shim 形式出現在 `PATH` 上（`~\scoop\shims\translate.exe`）。
- 這個 repo 裡**不再有版本號要手動更新**。

!!! warning "從舊的 go install 版本遷移"
    2026-08 之前，這個 repo 是用 `go install` 從原始碼編到 `~\.local\bin`，而
    `~\.local\bin` 在 `PATH` 上**排在** `~\scoop\shims` **前面**。所以殘留的
    `~\.local\bin\translate.exe` 會永遠遮蔽 scoop 那份：`scoop update translate`
    顯示成功，但 `translate --version` 印的還是舊的。packages 腳本會自動移除舊檔
    —— 但只在 scoop shim 確實存在之後才動手，這樣就算安裝失敗也不會讓你連
    `translate` 都沒得用。可以這樣確認：

    ```powershell
    Get-Command translate -All | Select-Object -ExpandProperty Source
    ```

!!! tip "升級"
    跟這個 repo 的其他東西一樣，安裝與升級是分開的：

    ```powershell
    just upgrade-translate      # scoop update translate
    ```

    裝好之後 `just upgrade-scoop` 也會一併升級它。

## 快速開始

```powershell
translate init                        # 引導式設定；會偵測哪些 provider 活著
translate "hola mundo" --to en        # 一次性翻譯
echo bonjour | translate --to en      # 管線
translate                             # 互動式 TUI
translate define ephemeral            # 查字典
translate history                     # 最近的翻譯紀錄
```

## 檔案放在哪

`translate` 會讀 XDG base-dir 變數，而這個 repo 在 session 內
（`profile.d/00_env.ps1`）與 **User** 環境變數
（`.chezmoiscripts/run_onchange_after_03_xdg_env.ps1`）都設好了 —— 所以 Windows
的路徑配置和 macOS/Linux 完全一致：

| 內容 | 路徑 |
|---|---|
| 設定 | `%USERPROFILE%\.config\translate\config.toml` |
| 歷史紀錄 | `%USERPROFILE%\.local\share\translate\history.jsonl` |
| 辭典資料 | `%USERPROFILE%\.local\share\translate\dict\` |
| 上次語言配對狀態 | `%USERPROFILE%\.local\state\translate\state.json` |
| TUI debug log | `%USERPROFILE%\.local\state\translate\debug.log` |

設定檔**不由 chezmoi 管理**（和母 repo 的選擇相同）：這個工具會自己改寫它，要調整
請用 `translate init`。用 `translate config path` 可以確認它實際解析到哪裡。

## 引擎

`--engine auto` 會依 `chain.order` 逐一嘗試，並在**吐出第一個 token 之前**就完成
failover：

| 引擎 | Endpoint | 說明 |
|---|---|---|
| copilot-proxy | `http://localhost:4141/v1` | 就是這個 repo 已經在跑的本機 proxy —— 見 [copilot-proxy](copilot-proxy.zh-TW.md)。啟動它（`copilot-proxy start`）後 translate 不需要任何 API key 就能用。 |
| Ollama | `http://localhost:11434/v1` | 離線；用「Local LLM tools」init 提問安裝 |
| Google | — | 免費、免金鑰；同時會回報偵測到的來源語言 |

`smartauto`（`translate init` 推薦的選項）依輸入形態分流：單一單字走辭典，句子片語
走 LLM。

!!! warning "Copilot 使用條款"
    用 Copilot 訂閱去驅動非 GitHub 的工具可能違反 Copilot 的服務條款。若在意這點，
    請調整 `chain.order`（拿掉 `copilot`，改讓 `ollama`/`google` 排前面）。

## 離線辭典

辭典層（zh→en 用 CC-CEDICT、en→zh 用 ECDICT）需要**一次性約 67 MB 的下載**，
刻意*不*在 apply 時做：

```powershell
translate dict update all      # 下載並建置到 ~\.local\share\translate\dict
translate dict reindex         # 用既有的下載重建 SQLite 索引（不用網路）
```

在那之前，英文查詢會退回 dictionaryapi.dev，中文查詢則會提示你先執行更新。

## TUI 按鍵

| 按鍵 | 動作 |
|---|---|
| `Enter` | 翻譯 |
| `Tab` | 在輸入框與結果框之間切換焦點 |
| `Ctrl+Y` | 複製結果 |
| `Ctrl+L` | 切換 live（延遲自動翻譯） |
| `Ctrl+E` | 切換引擎 |
| `Ctrl+T` | 目標語言 |
| `Ctrl+P` | 模型 |
| `Ctrl+O` | 提示風格 |
| `Ctrl+G` | 切換 pair（雙向）模式 |
| `Ctrl+R` | 歷史紀錄 |
| `Ctrl+U` | 清空 |
| `Alt+Enter` | 換行 |
| `Ctrl+C` / `Esc` | 離開 |

## Shell 整合

- **Tab 補全** —— `profile.d/10_tools.ps1` 會把 `translate completion powershell`
  快取到 `~\.cache\pwsh-init\translate.ps1`（與 starship/zoxide/tv 相同的
  `Import-CachedInit` 待遇）。升級後會自動重新產生。
- **`tv translate`** —— 一個瀏覽翻譯歷史的 Television channel：

    | 按鍵 | 動作 |
    |---|---|
    | `Enter` | 複製譯文 |
    | `Ctrl+Y` | 複製原文 |
    | `Ctrl+S` | 朗讀譯文（Windows SAPI，失敗時退回 Google） |

    只有開關打開時才會部署（見 `.chezmoiignore`）。

## 其他前端

兩者在 Windows 上都可用，不需要額外設定：

```powershell
translate serve       # loopback HTTP API，127.0.0.1:4155，Swagger UI 在 /docs
translate mcp         # 走 stdio 的 MCP server（translate / define / history 三個 tool）
```

要把 MCP server 註冊給 agent，就指向 `translate` 並帶單一參數 `mcp`。這個 repo
**不會**替你寫進 `~/.claude/settings.json`。

## 備註

- `translate speak` 離線使用 **Windows SAPI** 語音，失敗時退回 Google。tv channel
  的 `Ctrl+S` 用的是同一個後端。
- `--debug` 會記錄路由決策；一次性 CLI 寫到 stderr，TUI 則寫到
  `~\.local\state\translate\debug.log`（它的 alt-screen 會蓋掉 stderr）。
- 完整的旗標／設定參考在工具自己的
  [README](https://github.com/daviddwlee84/translate)。
