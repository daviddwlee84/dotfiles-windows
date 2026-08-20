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
| `copilot-proxy auth` | 一次性的 GitHub device 登入（執行 `copilot-api auth login --provider copilot`；儲存但不顯示 token） |
| `copilot-proxy start` / `stop` / `restart` | 管理本機 proxy（port 4141） |
| `copilot-proxy status` | 顯示 raw served 數量與 Claude 可用性 |
| `copilot-proxy doctor [--live]` | 診斷套件、認證、proxy、catalog、roles、上游與 Codex Apps |
| `copilot-proxy logs [N]` | 查看 proxy log |
| `copilot-proxy shim [on\|off]` | 切換節流 shim（port 4142） |
| `copilot-proxy whoami` | 帳號 / 方案 / 額度 |
| `copilot-proxy reinstall` | 清掉並重裝釘選套件 |
| `copilot-run <cmd...>` | 注入 proxy 環境變數後執行指令 |
| `claude-copilot` | 在 proxy 上開一次 Claude Code session |
| `claude-copilot-once` | 暫時釘住專案、執行一次、結束後還原 |
| `codex-copilot` / `codex-copilot-once` | 零持久化的 Codex Responses proxy session |
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
codex-copilot                     # Codex；即時 OpenAI-first model selection
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
Ready 判定會核對已安裝 `package.json` 的 name/version、verified stamp 與可執行的 launch
path，不會只看舊目錄或 binlink。安裝失敗不能重新蓋 stamp，也不能啟動 stale package。
`COPILOT_API_PKG` 接受 registry package spec（name 或 `@scope/name` 加 optional
version/tag/range）；npm alias 與 local/git/URL spec 會在 filesystem cleanup 前拒絕。
warm start 不需要套件網路。

公司 mirror 回 `ETARGET` 時，可能只是精確的公開版本尚未同步。刪掉仍可用的 prefix 前，
先確認 npm 實際使用的 registry：

```powershell
npm config get registry
npm view '@jeffreycao/copilot-api@2.1.0' version
# 公司政策允許直連 public npm 時，可做對照：
npm view '@jeffreycao/copilot-api@2.1.0' version --registry https://registry.npmjs.org/
```

若只有設定中的 mirror 缺少此版本，應等待／要求 mirror 同步，或以核准的 registry 執行
`copilot-proxy reinstall`。Windows module 也會自動 fallback 到 jsDelivr 上精確的 2.1.0
runtime files，逐檔核對內建 SHA-256，再只透過目前 npm registry 解析一般 dependencies。
這可處理 mirror 延遲同步，同時不放寬 pin，也不繞過核准 feed 取得 dependency tree。
不要把測過的精確 pin 改成 `latest`。

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
- Proxy 會定期刷新 model cache；restart 會強制立即刷新。`COPILOT_PROXY_START_TIMEOUT`
  預設 45 秒，因為 Clash/mihomo hop 可能讓首次 refresh 超過舊版的 20 秒。
- GitHub 會依帳號、組織政策、rollout 與 egress 改變 catalog。`/v1/models` 裡的 Claude
  ID 因此只是**被刊登的 alias**，不代表 inference 已獲授權。沒有 Claude ID 不等於
  proxy 壞掉；需要改選其他 served pin 時，明確執行 `copilot-model --auto`。請求失敗後
  不會自動從 Claude replay 到 OpenAI。
- `copilot-proxy doctor` 會比較 direct/proxied upstream catalog、驗證 main 與所有 role
  aliases，並找出 stale local pin。`--live` 也會比較遠端 ChatGPT `codex_apps`
  的 direct/proxied reachability，再對實際設定的 main model 送一個真實請求；只有該 pin
  不在 catalog 時才改用清楚標記的 catalog fallback。它不會失敗後再試另一個 model。
  只有 inference request 消耗 quota；timeout 與 TLS failure 會分開報告。
- HTTP 402 `billing_not_configured` 是 account-wide、不可 retry 的設定問題。請到
  <https://github.com/settings/copilot/features> 的 **Usage billed to** 選擇 organization
  或 enterprise。換 model、執行 `copilot-model --auto` 或切換 shim 都修不了這個帳號設定。
- `copilot-here` 只寫入 gitignored `.claude/settings.local.json`，不碰 committed project
  settings；`off` 只移除 helper 擁有的 env keys，保留其他設定。
- `claude-copilot` / `claude-copilot-once` 保留 Windows port 的 trusted
  `--dangerously-skip-permissions` 與 optional SpecStory 行為。走 SpecStory 時會先解析
  project/user `claude_cmd` 作為 base、強制只留一個 bypass flag、逐一 quote 使用者參數，
  並一律把完整 command 交給 `specstory run claude -c`（包含零參數 session）。只建立一次的
  `~/.specstory/cli/config.toml` 仍由使用者擁有；直接執行 `specstory run claude` 仍遵循該
  user/project config。純 `claude` 不受影響。
- Throttle shim 仍與 macOS/Linux 版本 byte-identical，會限制並行並重試暫時性的
  403/429 burst。它刻意讓 HTTP 402 只通過一次；billing 設定不是 throttle failure。

狀態放在 `~/.local/state/copilot-proxy/`；device login 會把 GitHub token 存在
`~/.local/share/copilot-api/github_token`，預設不印出內容。

## Codex 走 gateway

`codex-copilot` 與完全相同的 `codex-copilot-once` alias 會啟動本機
gateway/shim，並用本次啟動的 Codex `-c` overrides 傳入 `copilot_api`
Responses provider。它們不改 user/project Codex config，所以 plain `codex` 不受影響。
明確 `-m` / `--model` 永遠優先；否則從即時 raw catalog 依序選
OpenAI/Codex（`Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini`），
再退到 Claude、Gemini 與其他 chat model；disabled/embedding model 會排除。

Codex 一律走 `localhost:4142` shim，即使持久化的 throttling 開關是 off。
這一層除了限流，也會正規化 Codex `mcp_list_tools` Responses item 裡的空白
description。MCP server 與原生 Codex path 可以省略描述，但 GitHub Copilot 會以
`Invalid 'input[0].tools[0].description': empty string` 拒絕請求。shim 只補這些
tool definition 欄位，不改 prompt、schema 或 tool name。
目前 Codex 會以 zstd 壓縮這些請求；shim 只解壓需要修補的 Responses body，改以
普通 JSON 轉送，並移除已不適用的 `content-encoding` header。

這是與 Claude Code `copilot-model --auto` 分開的 picker：後者保持
Claude-first，只有 Codex launcher 是 OpenAI-first。

有安裝 SpecStory 時自動整合。Wrapper 會保留生效的 `codex_cmd`（project config >
user config > 裸 `codex`），再附加 provider/model/user arguments；
`--no-specstory` 直接執行 Codex。Claude/Gemini fallback 經 Responses Lite，不支援
Responses `tool_search`，因此 native Responses OpenAI models 排在 Anthropic 前。
Launcher 也會啟用 gateway-backed remote compaction，並排除依賴不可用
`tool_search` 的 `mcp__codex_apps__sites` namespace；後續明確傳入的 `-c`
仍可在單次呼叫覆寫這兩項。

`codex_apps` 本身不是 localhost service，也不是 Apple-Silicon-only Codex Desktop
bridge；它是 `https://chatgpt.com/backend-api/wham/apps` 的遠端 MCP。因此即使
`localhost:4142` inference 正常，它仍可能啟動失敗。保留 Apps 啟用，並以
`copilot-proxy doctor --live` 獨立診斷這條路由。

刻意不做 Codex 版 `copilot-here`：project `.codex/config.toml` 不能覆寫 provider
definition、provider selection 或 auth metadata。顯式 launcher 能提供 project/session
scope，同時不改 user-wide default。

### 實驗性 direct 設定

Direct `model_providers.copilot-enterprise` 範例只記錄在 macOS/Linux 完整指南，
不會安裝。它不是 localhost proxy 路徑，而且貼文中的 `gh auth token` flow 不具可攜性：
本次 EMU 帳號實測回 `421`/`403`；`copilot-proxy auth` 保存的 credential 加正常短效
Copilot token exchange 則可用。因此正式 launcher 使用已認證的本機 gateway。
