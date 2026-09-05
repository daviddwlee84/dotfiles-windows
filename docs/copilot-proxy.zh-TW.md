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
| `copilot-proxy logs [N]` / `logs err` / `logs shim [err]` / `logs lifecycle` | 查看proxy/shim stdout、stderr或process lifecycle log |
| `copilot-proxy shim [on\|off]` | 切換 metrics/節流 shim（port 4142；預設 on） |
| `copilot-proxy limiter [status\|set\|reset]` | 檢查或暫時調整執行中 shim 的 adaptive concurrency limit |
| `copilot-proxy stats` / `events` | 查詢本機 metrics DB，process 停止時也可使用 |
| `copilot-proxy quota` | 顯示即時帳號 / 方案 / 額度 |
| `copilot-proxy bench --model ID` | 執行有界的真實 Responses benchmark（消耗 quota） |
| `copilot-proxy whoami` | 帳號 / 方案 / 額度 |
| `copilot-proxy reinstall` | 清掉並重裝目前 selection |
| `copilot-proxy update VERSION` | stage、驗證並選取 exact 2.3.4/2.3.0/2.1.0，不重啟 |
| `copilot-proxy rollback` | 離線切回上一個 verified package，不重啟 |
| `copilot-run <cmd...>` | 注入 proxy 環境變數後執行指令 |
| `claude-copilot [--fast]` | 開一次 Claude Code session；`--fast` 只為本 session 選 live-catalog sibling |
| `claude-copilot-once [--fast]` | 暫時釘住專案、執行一次、結束後還原 |
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
claude-copilot --fast             # session-only fast sibling，無法使用時警告並 fallback
codex-copilot                     # Codex；即時 OpenAI-first model selection

# 單次 planning preset；Codex TUI 開啟後仍需輸入 `/plan`。
codex-copilot -c 'plan_mode_reasoning_effort="ultra"' -c 'service_tier="fast"'
claude-copilot-once --fast --permission-mode plan --settings '{"ultracode":true}'
```

Claude 指令不要再加 `--effort`：啟動時的 effort pin 會阻止 session-only
`ultracode` 生效。Codex 0.151.0 沒有啟動時指定 collaboration mode 的公開 flag，
所以套用 override 後仍需輸入 `/plan`。

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

預設套件是 `@jeffreycao/copilot-api@2.3.4`。GPT id 會走 Responses translation，
包括把 Claude Code 的 `output_config.effort` 轉成 `reasoning.effort`。GPT-5.6 與
Claude Code `ultracode` 需要這條路徑；舊 `1.13.14` 可能用 hard-coded fallback 蓋掉
client 指定的 effort。

套件只安裝一次到 `~/.local/share/copilot-api/pkg`。Windows 優先用 `npm.cmd`，因為它
能使用 `~/.npmrc` 裡的 Azure Artifacts credential provider；Bun 仍作為 fallback/runtime。
Ready 判定會核對已安裝 `package.json` 的 name/version、verified stamp 與可執行的 launch
path，不會只看舊目錄或 binlink。安裝失敗不能重新蓋 stamp，也不能啟動 stale package。
`COPILOT_API_PKG` 接受 registry package spec（name 或 `@scope/name` 加 optional
version/tag/range）；npm alias 與 local/git/URL spec 會在 filesystem cleanup 前拒絕。
warm start 不需要套件網路。Selection precedence 是 `COPILOT_API_PKG` → persisted
`$XDG_STATE_HOME/copilot-proxy/package.json` → 內建 2.3.4。已驗證的既有 2.1.0/2.3.0
install 會先寫成 persisted selection，因此套用新 module 不會暗中連網升級。

執行 `copilot-proxy update 2.3.4` 才會 stage 並驗證新 release、把舊 tree 保留成
`pkg.previous`，且不重啟目前 proxy；之後再明確 restart。`copilot-proxy rollback` 可離線
交換兩個 verified tree；exact `update 2.3.0`、`update 2.1.0` 仍支援。2.3.4 對應 source
commit `a51553569ba071e0c9a8329f8f5ccac2482a3945`、npm SHA-1
`643f59e0c257db613954738f02300c0a7ceebfeb`，以及 SRI
`sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ==`。

公司 mirror 回 `ETARGET` 時，可能只是精確的公開版本尚未同步。刪掉仍可用的 prefix 前，
先確認 npm 實際使用的 registry：

```powershell
npm config get registry
npm view '@jeffreycao/copilot-api@2.3.4' version
# 公司政策允許直連 public npm 時，可做對照：
npm view '@jeffreycao/copilot-api@2.3.4' version --registry https://registry.npmjs.org/
```

若只有設定中的 mirror 缺少此版本，應等待／要求 mirror 同步，或以核准的 registry 執行
`copilot-proxy reinstall`。Windows module 也會自動 fallback 到 jsDelivr 上精確的 2.3.4
runtime files，逐檔核對內建 SHA-256，再只透過目前 npm registry 解析一般 dependencies。
這可處理 mirror 延遲同步，同時不放寬 pin，也不繞過核准 feed 取得 dependency tree。
不要把測過的精確 pin 改成 `latest`。

## 模型選擇與 role profile

`copilot-model --auto` 必須讀到 live `/v1/models`，並在後續 inference request
發生**之前**選好 profile。自動候選會排除 policy-disabled、picker-hidden 與
embedding-only entries；raw 列表與明確手動選擇仍保留給使用者 override。它會先選 served
Claude 家族（`Fable > Opus > Sonnet > Haiku`），再使用與 Codex launcher 相同的命名
OpenAI tier 順序：

```text
Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini > Gemini
```

Luna 雖是 5.6 世代，但屬於輕量 tier，所以排在舊旗艦後面。只有上面所有命名的 OpenAI
tier 都不存在時，才會考慮未知的 future GPT id。這個角色意圖依照 OpenAI 的
[current model guidance](https://developers.openai.com/api/docs/guides/latest-model)。
一般沒有 Claude 的 Copilot catalog 會產生：

| Claude Code role | Copilot model |
|---|---|
| Main / Fable / Opus | `gpt-5.6-sol` |
| Sonnet | `gpt-5.6-terra` |
| Haiku / background / legacy small-fast | `gpt-5.6-luna` |

若手動選另一個 OpenAI main，Main/Fable/Opus 會保留該主模型；只有 served 且 selectable
的 Terra/Luna 才會供較低 role 使用。缺少或被 policy veto 的 tier 會退回主模型，不會寫入
不存在的硬編碼 id。原生 Claude profile 也只會在每個家族中挑 selectable alternative。

`[1m]` 是只給 Claude Code 的 context 提示；helper 依 live
`max_context_window_tokens >= 1,000,000` 決定。Raw API client 必須用 plain id。離線時仍
提供手動 discovery 清單，但 `--auto` 會拒絕寫入可能過期的 pin。

Auto-compact 與完整 context 提示分開設定。Launcher 會用 live `max_prompt_tokens`
（缺少時才用 context 減 maximum output）注入 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`，並保留
Claude Code 約 95% 的預設觸發比例。這可避免 client 以 1M 計算，卻超過 provider 實際
922k prompt ceiling。`copilot-model -c` 與 `copilot-here status` 都會顯示生效值。

### Selection、retry 與 failover 是不同概念

- **Catalog auto-selection** 會在 launch/inference 前排序 eligible models：
  `copilot-model --auto` 寫入 Claude Code profile，而 `codex-copilot` 為該次啟動選一個
  model。這裡 ranking 中的「fallback」只代表下一個 catalog candidate，不代表失敗後重播。
- **Same-model transport retry** 是 shim 在尚未把 upstream output 暴露給 client 前，遇到
  eligible transient failure 時，以相同 `model` 重送同一份 buffered request。
- **Request-time cross-model failover** 則是把同一個失敗的 logical request 改送另一個
  model。目前 proxy **沒有**實作此行為；inference 失敗不會改寫 persisted profile，也不會
  靜默切換模型。

`copilot-run` 與 `copilot-here on` 會注入同一組變數：

```text
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_FABLE_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_AUTO_COMPACT_WINDOW
```

刻意不設定 `CLAUDE_CODE_SUBAGENT_MODEL`，讓 workflow/frontmatter routing 保持最高優先。
切換 profile 後需重開 Claude Code。
Helper 也刻意不設定 `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`；只有想更早 compact 時才自行設定。
Live metadata 不可用時，相同模型的離線 pin 會保留 last-known ceiling 並警告；離線換模型則
移除舊 ceiling，避免套到錯的模型。

## Claude Code 功能相容性

關鍵分界是本機編排與 Anthropic cloud service：

| 功能 | 透過 Copilot + GPT | 說明 |
|---|---|---|
| CLI、tools、hooks、skills、memory、plugins、MCP、checkpoints、sandboxing | 可以 | 都是本機功能；GPT 收到轉譯後的 prompt/tool schema，行為可能不同。 |
| subagents、dynamic workflows | 可以 | 提供 role variables，但不蓋掉 workflow-specific subagent routing。見 [workflows](https://code.claude.com/docs/en/workflows)。 |
| `ultracode` | 2.3.4 可以 | 它是 xhigh effort + dynamic workflows，不是獨立模型。 |
| thinking/reasoning | 轉譯後可用 | GPT 使用 Responses reasoning，不是 Anthropic-native thinking semantics。 |
| Fast inference | catalog 有提供時可用 | Codex `/fast` 轉成 Copilot 的獨立 `-fast` sibling；Claude Code 使用 `claude-copilot --fast`。沒有 sibling 時會警告並退回 standard。 |
| Web Search、auto mode、MCP tool search | 依 provider | 取決於 Copilot endpoint 與 gateway translation。 |
| Ultrareview、Remote Control、Chrome、cloud Code Review、routines、web/mobile/Slack session | 不可以 | 需要 Claude.ai auth/cloud identity，local gateway 無法提供。 |

官方參考：[feature availability](https://code.claude.com/docs/en/feature-availability)、
[model configuration](https://code.claude.com/docs/en/model-config)、
[gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol)、
[Ultrareview](https://code.claude.com/docs/en/ultrareview)。

### Fast routing

OpenAI Responses API 以 `service_tier="fast"`（歷史上也用 `priority`）表示 Fast Mode，
但目前釘選的 Copilot fork 會移除這個欄位；GitHub Copilot 則把 fast inference advertise
成另一個 model id。共用 shim 每五分鐘 refresh `/v1/models`，由 eligible model 推導
`<standard>` → `<standard>-fast` pair，把 Codex `/fast` request 改寫到 sibling，再於轉送前
移除不支援的 tier。參考 OpenAI
[Fast Mode guide](https://developers.openai.com/api/docs/guides/fast-mode)。

Claude Code 原生 `/fast` 無法經這個 custom Anthropic gateway 使用；
`claude-copilot --fast` 會讀相同 routing map，並加上 session-only `--model` override。
Discovery 失敗時保留 last-good map；沒有 eligible sibling 時會警告並退回 standard。
Status 與 doctor 會顯示 routing state。關閉 shim 也會關閉這項轉譯，且不會自動送出會
消耗 quota 的 inference probe。

## 網路、entitlement 與診斷

- `COPILOT_HTTP_PROXY=auto` 會讀 Windows System Proxy 或明確的 proxy env，僅注入 child
  process 並帶 `--proxy-env`。Node 自己不會讀 WinINET system setting。
- Proxy 會定期刷新 model cache；restart 會強制立即刷新。`COPILOT_PROXY_START_TIMEOUT`
  預設 45 秒，因為 Clash/mihomo hop 可能讓首次 refresh 超過舊版的 20 秒。
- GitHub 會依帳號、組織政策、rollout 與 egress 改變 catalog。`/v1/models` 裡的 Claude
  ID 因此只是**被刊登的 alias**，不代表 inference 已獲授權。沒有 Claude ID 不等於
  proxy 壞掉；需要替後續 request 改選其他 served pin 時，明確執行
  `copilot-model --auto`。這是 pre-request catalog selection，不是 failed-request replay。
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
- **Managed client 對啟用中的 shim 一律 fail closed。** `copilot-run`、
  `claude-copilot*` 與 `codex-copilot*` 全部經過 `Assert-CopilotShim`；shim 已啟用但起不來時
  它們會直接放棄，而不是默默退回 `localhost:4141`。繞過 shim 會同時失去 SSE keepalive
  **與** Responses tool-description 正規化，所以那種靜默 fallback 等於把一個已記錄在案的
  `400` 重新放回來，而且哪裡都不會有訊息。`copilot-proxy shim off` 是唯一刻意的 direct-mode 路徑。
- **Identity 只接受 `/_shim/health`；ownership 仍由 OS 判定。**
  `Test-CopilotShimAlive` 要求該 endpoint 回 `{ok:true}`；`Start-CopilotShim` 另以
  `Get-NetTCPConnection` + `Win32_Process` 判斷 port owner，只回收 stale 的
  `copilot-throttle-shim.js`，其他 process 會具名拒絕。required spawn 失敗也會 reap；不要用
  generic `/v1/models` 回應推論 identity。詳見
  [pitfalls/copilot-proxy-shim-port-held-by-another-process.md](https://github.com/daviddwlee84/windows-dotfiles/blob/main/pitfalls/copilot-proxy-shim-port-held-by-another-process.md)。
- Metrics/throttle shim 與 Unix implementation byte-for-byte 相同。它會從 live catalog 推導
  Fast sibling route；任何 upstream body 尚未暴露前，network error 或 HTTP
  403/429/500/502/503/504 會以**相同 buffered request 與 effective model**重試。上游讀取
  buffered body 時回 `408 user_request_timeout` 最多只重播一次；HTTP 402、bare 401 與
  policy 422 只通過一次。
- `422 cyber_policy` 是 provider 的內容政策判定；shim 不 retry、不改寫，也不嘗試繞過。
- Admission 從 `COPILOT_SHIM_MIN=4` 起步，只在持續且乾淨的queue pressure下往
  `COPILOT_SHIM_MAX=8` 增加；403/429 會立刻降回floor並cooldown五分鐘。
  `copilot-proxy limiter status`、`limiter set --min 4 --max 8 --limit 6`、`limiter reset`
  只改目前process；要持久化range，請在restart前設定 `COPILOT_SHIM_MIN/MAX`。
- Bun 1.3.14 尚未包含stream-body/peer-abort上游修復 `80729349` 與 `3da09633`。Server會安裝
  compatibility rejection guard、吸收同步與非同步 cancellation failure，並讓SQLite metrics
  write保持best-effort，避免單一Codex stream斷線就終止整個4142 process。
- `stream:true` 經 grace period 後會收到 keepalive comment；成功 body 必須是 SSE，late
  failure 依 endpoint 送 Anthropic `error` 或 Responses `response.failed`。關掉 ping 不會
  關掉 stall watchdog。Timing/token rows 位於 `$XDG_STATE_HOME/copilot-proxy/metrics.sqlite`
  與 `$XDG_DATA_HOME/copilot-api/copilot-api.sqlite`，`stats`/`events` 可離線讀取。`bench`
  限制 1–10 runs、32–2048 max output、concurrency 1–4，但仍會送真實 inference、消耗 quota。

狀態放在 `~/.local/state/copilot-proxy/`；device login 會把 GitHub token 存在
`~/.local/share/copilot-api/github_token`，預設不印出內容。Detached watcher 會把spawn、ready、
startup failure、exit code、package/version/PID/port，以及deliberate或unexpected shutdown
append到`lifecycle.jsonl`。曾經ready後意外退出的shim最多會在1s/5s/30s後重啟三次，而且僅限
shim仍啟用、4141健康且4142仍down；穩定運行五分鐘會重置budget。Startup failure與deliberate
stop不會重啟，watcher也不會重啟4141或fail open。Recovery另記錄`restart_scheduled`、
`restart_succeeded`、`restart_failed`、`restart_suppressed`、`restart_exhausted`。

用`copilot-proxy logs lifecycle`查看journal；request-level attempts與stream failure仍由
`stats`/`events`查詢。Proxy與shim的stdout/stderr各自保留三代；即使stdout存在，`logs err`與
`logs shim err`仍可直接查看stderr。套用新的shim檔不會reload已在記憶體中的Bun process；等
active turn結束後仍需明確restart。

## Codex 走 gateway

`codex-copilot` 與完全相同的 `codex-copilot-once` alias 會啟動本機
gateway/shim，並用本次啟動的 Codex `-c` overrides 傳入 `copilot_api`
Responses provider。該 provider 自行提供 authentication，因此 launcher 不要求
Codex/ChatGPT login；既有 login 也不會被移除或改寫。它們不改 user/project Codex
config，所以 plain `codex` 不受影響。明確 `-m` / `--model` 永遠優先；否則從即時 catalog 依序選
OpenAI/Codex（`Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini`），
再退到 Claude、Gemini 與其他 chat model；automatic selection 會排除 policy-disabled、
picker-hidden 與 embedding-only entries。

Codex 一律走 `localhost:4142` shim，即使持久化的 throttling 開關是 off。
這一層除了限流，也會正規化 Codex `mcp_list_tools` Responses item 裡的空白
description。MCP server 與原生 Codex path 可以省略描述，但 GitHub Copilot 會以
`Invalid 'input[0].tools[0].description': empty string` 拒絕請求。shim 只補這些
tool definition 欄位，不改 prompt、schema 或 tool name。
目前 Codex 會以 zstd 壓縮這些請求；shim 只解壓需要修補的 Responses body，改以
普通 JSON 轉送，並移除已不適用的 `content-encoding` header。不需要 tool-description
修補的 zstd body 對 stream classifier 仍是不透明資料，因此會走 transparent、沒有
pre-header keepalive 的路徑；same-model transport retry 仍會套用。

這是與 Claude Code `copilot-model --auto` 分開的 picker：後者保持
Claude-first，只有 Codex launcher 是 OpenAI-first。

有安裝 SpecStory 時自動整合。啟動 watcher 前，wrapper 會在 `CODEX_HOME`（或
`~/.codex`）下建立 `sessions` 目錄；若初始化失敗，會在啟動任一 child process 前以
明確錯誤停止。Wrapper 會保留生效的 `codex_cmd`（project config > user config > 裸
`codex`），再附加 provider/model/user arguments；`--no-specstory` 直接執行 Codex。
SpecStory 自身的 sync policy 仍會套用；自動整合可能把 session history 上傳到
SpecStory Cloud，並更新 project 的 `.specstory/statistics.json`。Claude/Gemini fallback
經 Responses Lite，不支援
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

### 登入代理疑難排解

`copilot-proxy auth` 會將 `COPILOT_HTTP_PROXY` 套用至登入程序。Fork 的
`--proxy-env` 只支援 `start`，因此登入使用 Node preload 載入已安裝套件的
Undici proxy dispatcher。登入成功或失敗都會還原環境變數。更新 token 時出現
`Bad credentials` 需要重新進行裝置登入；重啟無法修復被拒絕的 GitHub 憑證。
使用 `copilot-proxy logs err` 查看啟動錯誤。
