# copilot-proxy

`copilot-proxy` 工具系列的原生 PowerShell 版本：它執行
[copilot-api](https://github.com/caozhiyuan/copilot-api) fork，讓 **GitHub Copilot
訂閱**可以當作 **Claude Code**（以及任何 Anthropic/OpenAI 相容 client）的後端。

以模組形式放在 `~/.config/powershell/modules/Copilot`，由 `$PROFILE` 自動匯入。
需要 `bun`（由 scoop 安裝）與 Copilot 訂閱。

## 指令

| 指令 | 作用 |
|---|---|
| `copilot-proxy auth` | 一次性的 GitHub device 登入（儲存 token） |
| `copilot-proxy start` / `stop` / `restart` | 管理本機 proxy（port 4141） |
| `copilot-proxy status` | 是否啟動？有哪些模型？ |
| `copilot-proxy doctor [--live]` | 診斷前置需求 → 套件 → 認證 → proxy → Claude 目錄 → 上游 |
| `copilot-proxy logs [N]` | 查看 proxy log |
| `copilot-proxy shim [on\|off]` | 切換節流 shim（port 4142） |
| `copilot-proxy whoami` | 帳號 / 方案 / 額度 |
| `copilot-proxy reinstall` | 清掉並重裝釘選的 copilot-api 套件 |
| `copilot-run <cmd...>` | 帶著 proxy 環境變數執行指令 |
| `claude-copilot` | 在 proxy 上開一次性的 Claude Code session |
| `claude-copilot-once` | 釘住此專案、跑一次、自動取消釘選（連 Ctrl-C 也是） |
| `copilot-here [on\|off\|status]` | 用 `.claude/settings.local.json` 做專案層級的釘選 |
| `copilot-model [<id>\|-l\|-c\|--auto]` | 切換釘選的模型 |
| `copilot-embed [TEXT\|-]` | 透過 proxy 的 `/v1/embeddings` 產生向量 |
| `semsearch index \| <QUERY>` | 對本機文字做語意搜尋 |

## 快速開始

```powershell
copilot-proxy auth        # 只需一次
copilot-proxy start
copilot-proxy doctor      # 驗證整條路徑
claude-copilot            # 以 Copilot 為後端的 Claude Code session
```

## 備註

- **預設模型**是 `claude-opus-5[1m]`。`[1m]` 後綴是給 Claude Code 的 1M context
  提示；在對 proxy 驗證前會被去掉。`copilot-model --auto` 會從線上實際提供的清單
  重新挑選（Claude > Codex > GPT > Gemini）—— 當釘選的模型已經過期時很有用。
- **釘選的套件只安裝一次**到 `~/.local/share/copilot-api/pkg`，之後直接執行它。
  `start` 刻意**不用** `bunx`：bunx 每次啟動都會重新解析套件，而 bun 透過 socks
  proxy 解析時可能無限期卡住，卡死的安裝程序又抓著 bun 的全域 cache lock，導致
  每次重試都以同樣方式卡死。現在暖啟動在綁 port 前完全不碰網路。調整
  `COPILOT_API_PKG` 會透過 `.installed-spec` 戳記自動重裝；`copilot-proxy reinstall`
  可強制重裝。
- **`COPILOT_HTTP_PROXY`**（`auto` | `always` | `never` | `http://127.0.0.1:PORT`）
  控制 Node 透過什麼路徑抓 GitHub 的模型目錄。`auto` 會讀 Windows 系統 Proxy
  （Clash Verge / mihomo / v2rayN 設定的那個）或 `HTTPS_PROXY`，並帶上 `--proxy-env`
  讓 Node 真的去用它 —— Node 自己不會理會系統 Proxy 設定。這點很關鍵，因為
  copilot-api 只在**啟動時抓一次** `/models`：在 GitHub 對 Claude 目錄做地區過濾的
  出口上，proxy 會把「沒有 Claude」的清單快取一整個 process 生命週期。
  `copilot-proxy doctor` 會 A/B 比較直連與經 proxy 的目錄，藉此和「帳號權限不足」
  區分開來。
- **`copilot-here`** 只寫入被 gitignore 的 `.claude/settings.local.json`，絕不動到
  已提交的 `.claude/settings.json`，並加一筆 `.git/info/exclude`，讓釘選永遠不會被
  commit 進去。`copilot-here status` 與 `claude-copilot-once` 會偵測既有釘選是否已
  偏離目前的預設值（模型升版、proxy 換位置、之後新增的 key），並詢問是否就地刷新。
- **`claude-copilot` / `claude-copilot-once`** 會以 `--dangerously-skip-permissions`
  執行 Claude Code —— proxy 這條是可信、免確認的流程，不會停下來問權限（純 `claude`
  不受影響；全域預設仍為 `auto`）。當 SpecStory CLI 在 `PATH` 上時，也會用
  `specstory run` 包住 session 以自動存檔逐字稿；Windows 上該 CLI 沒有官方 release，
  需透過 **SpecStory build** 初始化提問選用啟用。有傳入參數時，`-c` 的指令字串會從
  specstory 設定中的 `claude_cmd` 重建 —— `-c` 是**取代**該指令而非附加，寫死字串
  會默默丟掉它帶的旗標（`claude-copilot-once` 與 `claude-copilot-once --resume X`
  當初就是因此落在不同的權限模式）。
- **節流 shim**（`copilot-throttle-shim.js`，以 Bun 執行）限制同時在途的請求數，
  並在 403/429 爆量時透明重試 —— 與 macOS/Linux 用的是同一份 JS，未經修改。
- 狀態放在 `~/.local/state/copilot-proxy/`；token 放在
  `~/.local/share/copilot-api/github_token`。

!!! warning "權限（entitlement）"
    有些 Copilot 方案不提供任何 Anthropic 模型 —— 這時每個請求都會回
    `400 model_not_supported`。`copilot-proxy doctor` 能區分這種帳號政策問題與
    模型快取過期。
