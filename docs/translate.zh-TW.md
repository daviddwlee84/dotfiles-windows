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

## 翻譯 herdr pane {#herdr-pane}

裝了 [herdr](https://herdr.dev)（`installHerdr`）之後，`prefix + t` 會把焦點 pane 的
內容送進 `translate -2 --bilingual-mode doc`，並把結果顯示在一個暫時的 command pane
裡：原文逐行保留，每個區塊的譯文以 `  ↳ …` 交錯在下方。`prefix + y`（herdr-plus Quick
Actions）另外提供三個變體——範圍選單、目標語言輸入，以及複製到剪貼簿。

Helper：`~\.config\herdr\pane-translate.ps1`，是母 repo `pane-translate.sh` 的
PowerShell 移植版。兩者行為保持一致；共用的擷取規則寫在 superproject 的
[`docs/herdr-pane-capture.md`](https://github.com/daviddwlee84/dotfiles-all/blob/main/docs/herdr-pane-capture.md)，
面向使用者的完整說明則在母 repo 的
[herdr 文件](https://daviddwlee84.github.io/dotfiles/zh-TW/tools/herdr/#translate-pane)。

**範圍是畫面上這一頁，而這是誠實的答案、不是偷懶。** 跑在 alternate screen 上的 agent
pane（Claude Code）**沒有** scrollback：它回報 `scroll.max_offset_from_bottom: 0`，而
`herdr pane read --source recent --lines 1000` 剛好只回傳 `viewport_rows` 行——與
`--source visible` 完全相同。離開 alternate screen 的行永遠不會進入 herdr 的 host
scrollback，所以再大的 `--lines` 也救不回來。而因為 `--source visible` 呈現的是你在 app
**內部**捲到的位置，「當前頁」是精確的。`prefix+y` 上的 `recent:200/500/1000` 只在
shell、log、codex 這類 pane 才有意義；1000 是 herdr 每次讀取的硬上限，而且沒有分頁可以
再往回翻。無論選哪個模式，`HERDR_TRANSLATE_MAX_CHARS`（預設 12000）都會在區塊邊界裁切，
並把裁切結果寫在標頭上。

句子被切斷的問題由兩層處理：`recent:N` 擷取會做上緣邊界對齊，更重要的是 `--instructions`
會告訴模型這是終端機節錄、可能從句中開始或結束，且不得自行補完。

不花任何 LLM 呼叫就能檢查上述行為：

```powershell
pwsh -NoProfile -File "$HOME\.config\herdr\pane-translate.ps1" recent:500 --dry-run
```

**Windows 特有差異。** `prefix + t` 是 `type = "pane"`，不是 unix 端的 `popup`——Windows
preview 不接受 `popup`。它也不傳 `"$HERDR_ACTIVE_PANE_ID"` 參數，因為 herdr 在這個平台
不會展開命令字串裡的 `$VAR`；helper 改讀 herdr 注入的環境變數。`prefix+y` 的變體需要
herdr-plus plugin，而它在 Windows 上要從原始碼建置（因此需要 Go），至今尚未在真實 Windows
主機上驗證過——`prefix + t` 才是不依賴它也能用的路徑。參見
[`backlog/herdr-windows-port-verification.md`](https://github.com/daviddwlee84/dotfiles-windows/blob/main/backlog/herdr-windows-port-verification.md)。

環境變數：`HERDR_TRANSLATE_MAX_CHARS`（12000）、`HERDR_TRANSLATE_TO`（預設目標語言；未設定
時由 translate 自己的 `[general]` 設定決定）、`HERDR_RUN_HOLD`。

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
