# copilot-proxy

`copilot-proxy` 工具系列的原生 PowerShell 版本：它執行
[copilot-api](https://github.com/caozhiyuan/copilot-api) fork，讓 **GitHub Copilot
訂閱**可以當作 **Claude Code**（以及任何 Anthropic/OpenAI 相容 client）的後端。

以模組形式放在 `~/.config/powershell/modules/Copilot`，由 `$PROFILE` 自動匯入。
需要 `bun`（由 mise 安裝）與 Copilot 訂閱。

## 指令

| 指令 | 作用 |
|---|---|
| `copilot-proxy auth` | 一次性的 GitHub device 登入（儲存 token） |
| `copilot-proxy start` / `stop` / `restart` | 管理本機 proxy（port 4141） |
| `copilot-proxy status` | 是否啟動？有哪些模型？ |
| `copilot-proxy doctor [--live]` | 診斷前置需求 → 認證 → proxy → 模型權限 → 上游 |
| `copilot-proxy logs [N]` | 查看 proxy log |
| `copilot-proxy shim [on\|off]` | 切換節流 shim（port 4142） |
| `copilot-proxy whoami` | 帳號 / 方案 / 額度 |
| `copilot-run <cmd...>` | 帶著 proxy 環境變數執行指令 |
| `claude-copilot` | 在 proxy 上開一次性的 Claude Code session |
| `claude-copilot-once` | 釘住此專案、跑一次、自動取消釘選（連 Ctrl-C 也是） |
| `copilot-here [on\|off\|status]` | 用 `.claude/settings.local.json` 做專案層級的釘選 |
| `copilot-model [<id>\|-l\|-c]` | 切換釘選的模型 |
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

- **預設模型**是 `claude-opus-4-8[1m]`。`[1m]` 後綴是給 Claude Code 的 1M context
  提示；在對 proxy 驗證前會被去掉。
- **`copilot-here`** 只寫入被 gitignore 的 `.claude/settings.local.json`，絕不動到
  已提交的 `.claude/settings.json`，並加一筆 `.git/info/exclude`，讓釘選永遠不會被
  commit 進去。
- **`claude-copilot` / `claude-copilot-once`** 會以 `--dangerously-skip-permissions`
  執行 Claude Code —— proxy 這條是可信、免確認的流程，不會停下來問權限（純 `claude`
  不受影響；全域預設仍為 `auto`）。當 SpecStory CLI 在 `PATH` 上時，也會用
  `specstory run` 包住 session 以自動存檔逐字稿；Windows 上該 CLI 沒有官方 release，
  需透過 **SpecStory build** 初始化提問選用啟用。
- **節流 shim**（`copilot-throttle-shim.js`，以 Bun 執行）限制同時在途的請求數，
  並在 403/429 爆量時透明重試 —— 與 macOS/Linux 用的是同一份 JS，未經修改。
- 狀態放在 `~/.local/state/copilot-proxy/`；token 放在
  `~/.local/share/copilot-api/github_token`。

!!! warning "權限（entitlement）"
    有些 Copilot 方案不提供任何 Anthropic 模型 —— 這時每個請求都會回
    `400 model_not_supported`。`copilot-proxy doctor` 能區分這種帳號政策問題與
    模型快取過期。
