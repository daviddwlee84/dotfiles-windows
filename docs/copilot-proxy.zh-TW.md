# copilot-proxy

`copilot-proxy` 工具系列的原生 PowerShell 版本。它執行
[`@jeffreycao/copilot-api`](https://www.npmjs.com/package/@jeffreycao/copilot-api)
fork，讓 **GitHub Copilot 訂閱**可作為 **Claude Code** 與其他 Anthropic/OpenAI
相容 client 的後端。

模組部署在 `~/.config/powershell/modules/Copilot`，由 PowerShell profile 自動匯入。
需要 Bun、Node/npm 與 Copilot 訂閱。

## 指令

| 指令 | 作用 |
|---|---|
| `copilot-proxy auth` | 一次性的 GitHub device 登入（儲存 token） |
| `copilot-proxy start` / `stop` / `restart` | 管理本機 proxy（port 4141） |
| `copilot-proxy status` | 顯示 raw served 數量與 Claude 可用性 |
| `copilot-proxy doctor [--live]` | 診斷套件、認證、proxy、catalog、roles 與上游 |
| `copilot-proxy logs [N]` | 查看 proxy log |
| `copilot-proxy shim [on\|off]` | 切換節流 shim（port 4142） |
| `copilot-proxy whoami` | 帳號 / 方案 / 額度 |
| `copilot-proxy reinstall` | 清掉並重裝釘選套件 |
| `copilot-run <cmd...>` | 注入 proxy 環境變數後執行指令 |
| `claude-copilot` | 在 proxy 上開一次 Claude Code session |
| `claude-copilot-once` | 暫時釘住專案、執行一次、結束後還原 |
| `copilot-here [on\|off\|status]` | 在 `.claude/settings.local.json` 做 sticky pin |
| `copilot-model [<id>\|-l\|-c\|--auto]` | 切換或檢查完整 role profile |
| `copilot-embed [TEXT\|-]` | 透過 `/v1/embeddings` 產生向量 |
| `semsearch index \| <QUERY>` | 對本機文字做語意搜尋 |

## 快速開始

```powershell
copilot-proxy auth                 # 只需一次
copilot-proxy start
copilot-model --auto              # 從 live catalog 選模型
copilot-model -c                   # 查看 Main/Fable/Opus/Sonnet/Haiku
copilot-here on                    # 固定本專案；或用 claude-copilot-once
```

`chezmoi apply` 不會偷偷遷移既有 global/project pin。升級後請手動執行一次
`copilot-model --auto`。若 `copilot-here` 已開，它會刷新 local role set；否則只更新
global 的單行 main-model state。

## Routing 原理

```text
Claude Code --Anthropic /v1/messages--> copilot-api (localhost:4141)
                                          | Claude：native Messages
                                          | GPT：Anthropic -> Responses 轉譯
                                          v
                                  GitHub Copilot API
```

預設套件是 `@jeffreycao/copilot-api@2.1.0`。GPT id 會走 Responses translation，
包括把 Claude Code 的 `output_config.effort` 轉成 `reasoning.effort`。GPT-5.6 與
Claude Code `ultracode` 需要這條路徑；舊 `1.13.14` 可能用 hard-coded fallback 蓋掉
client 指定的 effort。

套件只安裝一次到 `~/.local/share/copilot-api/pkg`。Windows 優先用 `npm.cmd`，因為它
能使用 `~/.npmrc` 裡的 Azure Artifacts credential provider；Bun 仍作為 fallback/runtime。
版本戳記會讓 2.1.0 升級自動重裝，warm start 不需要套件網路。

## 模型選擇與 role profile

`copilot-model --auto` 必須讀到 live `/v1/models`。先選 served Claude 家族
（`Fable > Opus > Sonnet > Haiku`），沒有 Claude 時依能力排序：

```text
Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini > Gemini
```

Luna 雖是 5.6 世代，但屬於輕量 tier，所以排在舊旗艦後面。這個角色意圖依照 OpenAI 的
[current model guidance](https://developers.openai.com/api/docs/guides/latest-model)。
一般沒有 Claude 的 Copilot catalog 會產生：

| Claude Code role | Copilot model |
|---|---|
| Main / Fable / Opus | `gpt-5.6-sol` |
| Sonnet | `gpt-5.6-terra` |
| Haiku / background / legacy small-fast | `gpt-5.6-luna` |

若手動選另一個 OpenAI main，Main/Fable/Opus 會保留該主模型；有 served Terra/Luna 時
分別供較低 role 使用。缺少 tier 時退回主模型，不會寫入不存在的硬編碼 id。原生 Claude
profile 則在每個 Claude 家族中選最強 served model。

`[1m]` 是只給 Claude Code 的 context 提示；helper 依 live
`max_context_window_tokens >= 1,000,000` 決定。Raw API client 必須用 plain id。離線時仍
提供手動 discovery 清單，但 `--auto` 會拒絕寫入可能過期的 pin。

`copilot-run` 與 `copilot-here on` 會注入同一組變數：

```text
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_FABLE_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_SMALL_FAST_MODEL
```

刻意不設定 `CLAUDE_CODE_SUBAGENT_MODEL`，讓 workflow/frontmatter routing 保持最高優先。
切換 profile 後需重開 Claude Code。

## Claude Code 功能相容性

關鍵分界是本機編排與 Anthropic cloud service：

| 功能 | 透過 Copilot + GPT | 說明 |
|---|---|---|
| CLI、tools、hooks、skills、memory、plugins、MCP、checkpoints、sandboxing | 可以 | 都是本機功能；GPT 收到轉譯後的 prompt/tool schema，行為可能不同。 |
| subagents、dynamic workflows | 可以 | 提供 role variables，但不蓋掉 workflow-specific subagent routing。見 [workflows](https://code.claude.com/docs/en/workflows)。 |
| `ultracode` | 2.1.0 可以 | 它是 xhigh effort + dynamic workflows，不是獨立模型。 |
| thinking/reasoning | 轉譯後可用 | GPT 使用 Responses reasoning，不是 Anthropic-native thinking semantics。 |
| Web Search、fast/auto mode、MCP tool search | 依 provider | 取決於 Copilot endpoint 與 gateway translation。 |
| Ultrareview、Remote Control、Chrome、cloud Code Review、routines、web/mobile/Slack session | 不可以 | 需要 Claude.ai auth/cloud identity，local gateway 無法提供。 |

官方參考：[feature availability](https://code.claude.com/docs/en/feature-availability)、
[model configuration](https://code.claude.com/docs/en/model-config)、
[gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)、
[Ultrareview](https://code.claude.com/docs/en/ultrareview)。

## 網路、entitlement 與診斷

- `COPILOT_HTTP_PROXY=auto` 會讀 Windows System Proxy 或明確的 proxy env，僅注入 child
  process 並帶 `--proxy-env`。Node 自己不會讀 WinINET system setting。
- Model catalog 只在 proxy 啟動時抓一次。`COPILOT_PROXY_START_TIMEOUT` 預設 45 秒，因為
  Clash/mihomo hop 可能讓 refresh 超過舊版的 20 秒。
- GitHub 會依帳號、組織政策、rollout 與 egress 改變 catalog。因此在仍有 served OpenAI
  fallback 時，「沒有 Claude」是 warning，不代表 proxy 本身壞掉。
- `copilot-proxy doctor` 會比較 direct/proxied upstream catalog、驗證 main 與所有 role
  aliases，並找出 stale local pin。`--live` 會送一個真實請求並消耗 quota。
- `copilot-here` 只寫入 gitignored `.claude/settings.local.json`，不碰 committed project
  settings；`off` 只移除 helper 擁有的 env keys，保留其他設定。
- `claude-copilot` / `claude-copilot-once` 保留 Windows port 的 trusted
  `--dangerously-skip-permissions` 與 optional SpecStory 行為，純 `claude` 不受影響。
- Throttle shim 仍與 macOS/Linux 版本 byte-identical，會限制並行並重試 403/429 burst。

狀態放在 `~/.local/state/copilot-proxy/`；GitHub token 放在
`~/.local/share/copilot-api/github_token`。
