# copilot-proxy

A native PowerShell port of the `copilot-proxy` tool series. It runs the
[`@jeffreycao/copilot-api`](https://www.npmjs.com/package/@jeffreycao/copilot-api)
fork so a **GitHub Copilot subscription** can back **Claude Code** and other
Anthropic/OpenAI-compatible clients.

The module is deployed to `~/.config/powershell/modules/Copilot` and imported by
the PowerShell profile. It requires Bun **1.4.0 or newer**, Node/npm and a
Copilot subscription. `chezmoi apply` narrowly upgrades an installed older Bun;
it does not restart a running shim.

## Commands

| Command | What it does |
|---|---|
| `copilot-proxy auth` | one-time GitHub device login (`copilot-api auth login --provider copilot`; stores but does not display the token) |
| `copilot-proxy start` / `stop` / `restart` | manage the local proxy (port 4141) |
| `copilot-proxy status` | show raw served count and Claude availability |
| `copilot-proxy doctor [--live]` | diagnose package, auth, proxy, catalog, roles, upstream and Codex Apps |
| `copilot-proxy logs [N]` / `logs err` / `logs shim [err] [N] [generation]` / `logs lifecycle` | tail proxy stdout/stderr, current or rotated shim stdout/stderr (generation 0–3), or process-lifecycle logs |
| `copilot-proxy shim [on\|off]` | toggle the metrics/throttle shim (port 4142; default on) |
| `copilot-proxy limiter [status\|set\|reset]` | inspect or temporarily tune the running shim's adaptive concurrency limit |
| `copilot-proxy stats` / `events` | query the local metrics databases, including while processes are down |
| `copilot-proxy quota` | show live account / plan / quota |
| `copilot-proxy bench --model ID` | run bounded real Responses benchmarks (consumes quota) |
| `copilot-proxy whoami` | account / plan / quota |
| `copilot-proxy reinstall` | wipe and reinstall the selected package |
| `copilot-proxy update VERSION` | stage, verify and select exact 2.5.2/2.3.4/2.3.0/2.1.0 without restarting |
| `copilot-proxy rollback` | restore the previous package, selection and transport settings offline, while stopped |
| `copilot-run <cmd...>` | run a command with the proxy env injected |
| `claude-copilot [--fast]` | one-off Claude Code session; `--fast` selects a live-catalog sibling for this session |
| `claude-copilot-once [--fast]` | pin this project, run once, then restore it |
| `codex-copilot` / `codex-copilot-once` | zero-persistence Codex session on the Responses proxy |
| `copilot-here [on\|off\|status]` | sticky project pin in `.claude/settings.local.json` |
| `copilot-model [<id>\|-l\|-L\|-c\|--auto [--why]\|--why\|--json]` | switch, inspect or explain the complete role profile |
| `copilot-embed [TEXT\|-]` | embed text through `/v1/embeddings` |
| `semsearch index \| <QUERY>` | semantic search over local text |

## Quick start

```powershell
copilot-proxy auth                 # once
copilot-proxy start
copilot-model --why              # explain automatic selection; write nothing
copilot-model -L                   # inspect live tier/price/context/plan metadata
copilot-model --auto              # select from the live catalog
copilot-model -c                   # inspect Main/Fable/Opus/Sonnet/Haiku
copilot-here on                    # sticky project; or use claude-copilot-once
claude-copilot --fast             # session-only fast sibling, with warned fallback
codex-copilot                     # Codex; live OpenAI-first model selection

# One-shot planning presets. Codex still needs `/plan` after the TUI opens.
codex-copilot -c 'plan_mode_reasoning_effort="ultra"' -c 'service_tier="fast"'
claude-copilot-once --fast --permission-mode plan --settings '{"ultracode":true}'
```

Do not add `--effort` to the Claude command: a launch-effort pin prevents the
session-only `ultracode` switch from taking effect. Codex 0.151.0 has no public
startup collaboration-mode flag, so its overrides are followed by `/plan`.

Existing global and project pins are deliberately not migrated by `chezmoi
apply`. After deploying this fix and reloading the PowerShell profile, run
`copilot-model --auto` again to recover a previous `gpt-5-mini` selection; no
settings or state files need to be deleted. It selects Astra when Astra is the
best selectable live candidate, regardless of the old pin. When `copilot-here`
is active, that command refreshes the local role set; otherwise it updates the
global one-line main-model state.

## How routing works

```text
Claude Code --Anthropic /v1/messages--> copilot-api (localhost:4141)
                                          | Claude: native Messages path
                                          | GPT: Anthropic -> Responses translation
                                          v
                                  GitHub Copilot API
```

The default package is `@jeffreycao/copilot-api@2.5.2`. For GPT ids it translates
Claude Code requests to Responses, including `output_config.effort` to
`reasoning.effort`. This is required for GPT-5.6 and Claude Code's `ultracode`
effort setting; the old `1.13.14` path could replace the requested effort with a
hard-coded fallback.

The package is installed once under `~/.local/share/copilot-api/pkg`. Windows
uses `npm.cmd` first because it understands the Azure Artifacts credential
provider in `~/.npmrc`; Bun remains the fallback/runtime. Readiness is based on
the installed `package.json` name/version, a verified stamp, and a runnable launch
path—not merely an old directory or binlink. A failed install cannot restamp or
launch stale package contents. `COPILOT_API_PKG` accepts registry package specs
(name or `@scope/name` with an optional version/tag/range); npm aliases and
local/git/URL specs are rejected before filesystem cleanup. Warm starts do no
package network work. Selection precedence is `COPILOT_API_PKG` → persisted
`$XDG_STATE_HOME/copilot-proxy/package.json` → built-in 2.5.2. A verified existing
2.1.0/2.3.0/2.3.4 install is persisted before the built-in is considered, so applying
this module never performs an implicit network upgrade.

Use `copilot-proxy update 2.5.2` to stage and verify the reviewed release, preserve
the old tree as `pkg.previous`, and select it without restarting the running
proxy. Restart deliberately afterward. The 2.5.2 package is tied to source commit
[`6c1117c`](https://github.com/caozhiyuan/copilot-api/commit/6c1117c974d9b7261fc4ab4420bfbe23ae25d4d2)
and archive SRI
`sha512-bMVpuniekbKKq0LMtmZZJKjDVpaOODAHs19akwkP/hyGfgcx+YK0X22jfB46lQb0p9EoywDrJMyTcAfLr18jEQ==`.
For 2.5.2 and 2.3.4, all 19 installed runtime files are compared with hashes from
the reviewed archive, including after normal registry installation. Older exact
2.3.0/2.1.0 selections retain their existing metadata/dependency checks.

Rollback requires `copilot-proxy stop` first, then `copilot-proxy rollback`.
The transaction restores package/selection and the previous presence/values of
`responsesTransport` and `upstreamTransport` in the backend config. It preserves
newer credentials, usage databases and unrelated settings. The previous generation
stays recoverable until promotion succeeds. Deployment snapshots under
`pkg.previous/.copilot-rollback/` (under `pkg/` after rollback) retain the wrapper
and shim that were deployed at update time; review them and restore the matched
source/deployed files separately, reload the module, then start. Applying new
dotfiles before `update` means these snapshots already contain the new wrapper;
retain a pre-apply deployment bundle for a complete rollout rollback. A legacy
previous tree without a transport snapshot requires that manual bundle.

On a corporate mirror, `ETARGET` can mean the exact public version has not synced
yet. Check the registry that npm is actually using before deleting the working
prefix:

```powershell
npm config get registry
npm view '@jeffreycao/copilot-api@2.5.2' version
# Optional comparison where direct public npm is permitted:
npm view '@jeffreycao/copilot-api@2.5.2' version --registry https://registry.npmjs.org/
```

If only the configured mirror is missing the version, wait/request mirror sync or
use an approved registry for `copilot-proxy reinstall`. The Windows module also
falls back automatically to the reviewed exact runtime files on jsDelivr, verifies a
baked SHA-256 for every file, then resolves only its ordinary dependencies through
the configured npm registry. This handles a lagging mirror without weakening the
pin or bypassing the approved feed for the dependency tree. Do not replace the
tested exact pin with `latest`.

## Model selection and role profile

`copilot-model --auto` requires the live `/v1/models` catalog and chooses a
profile **before any later inference request**. Automatic candidates exclude
policy-disabled, picker-hidden, embedding-only, and `-fast` entries; raw listing
and explicit manual selection remain available as user overrides. Vendor order is
Claude > OpenAI > grok > Gemini. Inside each vendor, it reads Copilot's own
`model_picker_category` (`powerful > versatile > lightweight`) and compares
model generations only inside the winning tier. A curated allowlist wins for
known ids and unknown same-generation siblings; an unknown newer flagship can
win without waiting for a module update. Missing category metadata falls back to
the historical allowlist rather than guessing. Each automatic selection ranks
that invocation's live catalog independently of previous state, environment model
overrides, or project pins. It does not infer an account tier from the old model
or compare `billing.restricted_to` plan sets; those fields are diagnostic only.
The current model still controls the current marker and normal launch precedence,
and an active project pin still determines where `--auto` writes.

OpenAI generation and capability tier are independent: Astra succeeds Sol as the
flagship while Terra and Luna remain on 5.6. Therefore `gpt-6-astra` outranks
`gpt-5.6-sol`, but a hypothetical lightweight `gpt-6-luna` would not. This follows
OpenAI's [current model guidance](https://developers.openai.com/api/docs/guides/latest-model).
The current Copilot catalog restricts Astra to `pro_plus` / Business / Enterprise /
Max and exposes a 1,000,000-token context with an 872,000-token prompt ceiling
(smaller than Sol's 1,050,000 / 922,000); it starts at `reasoning_effort=low`, with
no `none` mode. The backward-compatible offline fallback stays
`gpt-5.6-sol[1m]`; that is not an entitlement guarantee. The live PLANS column
in `copilot-model -L` and raw `billing.restricted_to` in `--json` describe the
catalog, not proof of the active account/billing target/organization's entitlement.
The gateway enforces actual access; a later entitlement rejection still requires
choosing another served model manually.
The generated profile is:

| Claude Code role | Copilot model |
|---|---|
| Main / Fable / Opus | selected main (`gpt-6-astra` when it is the best selectable live candidate) |
| Sonnet | `gpt-5.6-terra` |
| Haiku / background / legacy small-fast | `gpt-5.6-luna` |

`-l` remains the pipeable bare-id list. `-L` / `--details` exposes tier,
price category, context/output limits, reasoning range, fast sibling, advertised
plans, and picker state; `*` marks the current model and `->` the authoritative
automatic pick. Rows are grouped by tier/generation for comparison; display order
does not replace vendor/allowlist policy.
`--why` is a no-write dry run, `--auto --why` explains and then writes, and
`--json` returns the raw catalog. That live HTTP payload is separate from the
shim's `/_shim/fast-routing` endpoint and Codex's generated on-disk model catalog.

A manually selected OpenAI main remains Main/Fable/Opus; Terra and Luna are used
for the lower roles only when served and selectable. Missing or policy-vetoed tiers
fall back to the selected main, never to an unserved hard-coded id. Native Claude
profiles likewise choose only selectable alternatives in each Claude family.

The `[1m]` suffix is a Claude Code-only context hint. It is derived from each
model's live `max_context_window_tokens` metadata when the value is at least one
million. Raw API clients must use the plain id. Offline manual discovery remains
available, but offline `--auto` refuses to write a potentially stale pin.

Auto-compact is configured separately from the full context hint. The launchers
set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from live `max_prompt_tokens` (or context
minus maximum output when that field is absent), then leave Claude Code's default
roughly-95% threshold unchanged. This prevents a 1M-class client window from
crossing a smaller provider prompt ceiling such as 922k. `copilot-model -c` and
`copilot-here status` display the effective value.

For `gpt-6-astra` and `gpt-6-astra-fast`, the default compact budget is now 70% of
the live prompt ceiling: 610,400 for an 872,000-token ceiling. Configure
`$env:COPILOT_ASTRA_COMPACT_RATIO='0.70'` with a decimal greater than zero and at
most one; `1` restores the full prompt budget. The result is rounded down and
must meet Claude's 100,000-token minimum (Codex requires a positive budget).
The actual context window and `[1m]` hint remain unchanged. A valid explicit
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` or Codex `-c model_auto_compact_token_limit=...`
takes precedence. Existing sessions and project pins are not rewritten; refresh
managed pins and restart clients deliberately. This is a conservative experiment
to reduce large compact uploads, not a claimed fix for remote body-read 408s.

### Selection, retry and failover are different

- **Catalog auto-selection** ranks eligible models before launch/inference:
  `copilot-model --auto` persists a Claude Code profile, while `codex-copilot`
  chooses one model for that invocation. “Fallback” in those rankings means the
  next catalog candidate, not replaying a failed request.
- **Same-model transport retry** is the shim resending the same buffered request
  with the same `model` after an eligible transient failure, before upstream output
  has been exposed.
- **Request-time cross-model failover** would replay one failed logical request on
  a different model. This proxy does **not** implement that behavior; a failed
  inference never changes the persisted profile or silently moves to another model.

Both `copilot-run` and `copilot-here on` inject the same variables:

```text
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_FABLE_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_AUTO_COMPACT_WINDOW
```

`CLAUDE_CODE_SUBAGENT_MODEL` is intentionally left unset so workflow/frontmatter
routing remains authoritative. Restart Claude Code after changing the profile.
The helper deliberately does not set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`; set it
yourself only to compact earlier. If live metadata is unavailable, an unchanged
offline pin keeps its last-known ceiling with a warning, while an offline model
change drops the stale value.

## Claude Code feature compatibility

The useful boundary is local orchestration versus Anthropic cloud services:

| Feature | Through Copilot + GPT | Notes |
|---|---|---|
| CLI, tools, hooks, skills, memory, plugins, MCP, checkpoints, sandboxing | Yes | Local Claude Code features; GPT behavior may differ after prompt/tool translation. |
| Subagents and dynamic workflows | Yes | Role variables are provided without overriding workflow-specific subagent routing. See [workflows](https://code.claude.com/docs/en/workflows). |
| `ultracode` | Yes on 2.3.4 | It is xhigh effort plus dynamic workflows, not a separate model. |
| Thinking/reasoning | Translated | GPT uses Responses reasoning rather than Anthropic-native thinking semantics. |
| Fast inference | Yes when catalogued | Codex `/fast` is translated to Copilot's separate `-fast` sibling; Claude Code uses `claude-copilot --fast`. No sibling means a warned standard fallback. |
| Web search, auto mode, MCP tool search | Provider-dependent | Availability depends on the Copilot endpoint and gateway translation. |
| Ultrareview, Remote Control, Chrome, cloud Code Review, routines, web/mobile/Slack sessions | No | These require Claude.ai authentication/cloud identity; a local API gateway cannot provide it. |

See Claude Code's [feature availability](https://code.claude.com/docs/en/feature-availability),
[model configuration](https://code.claude.com/docs/en/model-config),
[gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol), and
[Ultrareview](https://code.claude.com/docs/en/ultrareview) references.

### Fast routing

OpenAI's Responses API expresses Fast Mode with `service_tier="fast"` (and
historically `priority`), but the pinned Copilot fork removes that field.
GitHub Copilot instead advertises fast inference as a separate model id. The
shared shim refreshes `/v1/models` every five minutes, derives eligible
`<standard>` → `<standard>-fast` pairs, rewrites Codex `/fast` requests to the
sibling and removes the unsupported tier before forwarding. See OpenAI's
[Fast Mode guide](https://developers.openai.com/api/docs/guides/fast-mode).

Claude Code's native `/fast` is unavailable through this custom Anthropic
gateway. `claude-copilot --fast` uses the same routing map and appends a
session-only `--model` override. Failed discovery retains the last-good map; no
eligible sibling falls back to the standard model with a warning. Status and
doctor report routing state. Turning the shim off disables the translation, and
no automatic paid inference probe is performed.

## Network, entitlement and diagnostics

- `COPILOT_HTTP_PROXY=auto` reads the Windows System Proxy or an explicit proxy
  environment variable, scopes it to the child and passes `--proxy-env`. Node
  otherwise ignores the WinINET system setting.
- The proxy refreshes its model cache periodically; a restart forces an immediate
  refresh. `COPILOT_PROXY_START_TIMEOUT` defaults to 45 seconds because a
  Clash/mihomo hop can make the initial refresh exceed the old 20-second budget.
- GitHub can vary the catalog by account, organization policy, rollout and egress.
  Claude IDs in `/v1/models` are therefore **advertised aliases**, not proof that
  inference is authorized. No Claude IDs is not by itself a broken proxy; use
  `copilot-model --auto` when you explicitly want to select another served pin for
  later requests. That is pre-request catalog selection, not failed-request replay.
- `copilot-proxy doctor` compares direct and proxied upstream catalogs, validates
  the main model plus every role alias, and reports stale local pins. `--live`
  also compares direct/proxied reachability of remote ChatGPT `codex_apps`, then
  sends one real request to the effective configured main model (or a clearly
  labeled catalog fallback when that pin is absent). It never retries another
  model. Only this inference request consumes quota; timeout and TLS failures are
  reported separately.
- HTTP 402 with `billing_not_configured` is account-wide and nonretryable. Select
  an organization or enterprise under **Usage billed to** at
  <https://github.com/settings/copilot/features>. Model changes,
  `copilot-model --auto`, and shim toggles cannot repair that account setting.
- `copilot-here` writes only the gitignored `.claude/settings.local.json`, never
  committed project settings. `off` removes every env key owned by the helper and
  preserves unrelated settings.
- `claude-copilot` and `claude-copilot-once` retain the Windows port's trusted
  `--dangerously-skip-permissions` and optional SpecStory behavior. The raw path yields to explicit permission modes. On the SpecStory path an
  explicit mode replaces the repo-seeded bypass. A custom `claude_cmd` is never
  rewritten: without an alternate mode the wrapper appends its default bypass,
  while embedded permission flags remain the command owner's responsibility. On
  the SpecStory path they resolve the project/user `claude_cmd` as the base,
  quote all user arguments, and always pass the complete
  command through `specstory run claude -c` (including zero-argument sessions). The
  create-seeded `~/.specstory/cli/config.toml` remains user-owned, and direct
  `specstory run claude` still follows that user/project configuration. Plain
  `claude` is unaffected.
- **Managed clients fail closed on an enabled shim.** `copilot-run`, the
  `claude-copilot*` launchers and `codex-copilot*` all pass through
  `Assert-CopilotShim`; if the shim is enabled and cannot be started, they refuse
  rather than quietly falling back to `localhost:4141`. Bypassing the shim drops
  the SSE keepalive *and* the Responses tool-description normalization, so a
  silent fallback reintroduces a documented `400` with no message anywhere.
  `copilot-proxy shim off` is the only intentional direct-mode route.
- **Identity comes only from `/_shim/health`; ownership still comes from the OS.**
  `Test-CopilotShimAlive` requires `{ok:true}` from that endpoint, while
  `Start-CopilotShim` classifies port ownership with `Get-NetTCPConnection` +
  `Win32_Process`: a stale `copilot-throttle-shim.js` of ours is reclaimed, any
  other process is named and refused. A failed required spawn is reaped. Move a
  foreign listener with `COPILOT_SHIM_PORT`; never infer identity from a generic
  `/v1/models` response. See
  [pitfalls/copilot-proxy-shim-port-held-by-another-process.md](https://github.com/daviddwlee84/windows-dotfiles/blob/main/pitfalls/copilot-proxy-shim-port-held-by-another-process.md).
- The metrics/throttle shim is shared byte-for-byte with Unix. It derives Fast
  routes from the live catalog and permits at most one replay of the same
  buffered request/model before output: completed 500/502/503, a recognized nested
  `408 user_request_timeout`, 429 or explicitly classified throttle 403. It honors
  `Retry-After`; waits beyond 300 seconds return the error rather than shortening
  the requested delay. Unknown 408, 504, permission 403, 400/401/402 and policy 422
  pass through once. A local watchdog, broken backend connection, or blocked
  error-body read leaves execution unknown and is not replayed.
  Queue/backoff cancellation releases promptly; after dispatch, cancellation
  drains the backend while retaining admission. The 330-second shim watchdog
  follows the backend's 300-second headers/inactivity deadlines; none is an
  absolute generation deadline. Incompatible overrides are diagnosed.
- A `422 cyber_policy` response is the provider's content-policy decision. The
  shim does not retry, rewrite, or attempt to bypass it.
- Admission starts at `COPILOT_SHIM_MIN=4` and grows toward
  `COPILOT_SHIM_MAX=8` only under sustained clean queue pressure. A 403/429 returns
  it to the floor for a five-minute cooldown. `copilot-proxy limiter status`,
  `limiter set --min 4 --max 8 --limit 6`, and `limiter reset` change only the
  running process; set `COPILOT_SHIM_MIN/MAX` before restart to persist a range.
- Bun 1.3.14 has an upstream `Bun.serve` use-after-free: a completed streaming
  response can retain a stale `onAborted` callback that is invoked on a later
  keep-alive disconnect. Bun commit
  [`df4fe1e7`](https://github.com/oven-sh/bun/commit/df4fe1e7b609099d5fa6264e36c37a64932ee3ca)
  fixes the `RequestContext` lifetime, and Bun 1.4.0 is the supported floor.
  Shim start, offline shim CLI commands, `status`, and `doctor` all enforce or
  report this floor. The JavaScript cancellation guards and best-effort SQLite
  writes remain necessary defense in depth; an exception handler cannot repair
  native memory corruption.
- For literal `stream:true`, the shim emits keepalive comments after the grace period,
  requires successful upstream bodies to be SSE, and translates late failures to
  Anthropic `error` or Responses `response.failed` terminal events. The stall
  watchdog remains active when pings are disabled. Timing and token rows live in
  `$XDG_STATE_HOME/copilot-proxy/metrics.sqlite` and
  `$COPILOT_API_HOME/copilot-api.sqlite` (API home defaults to
  `~/.local/share/copilot-api`); `COPILOT_SHIM_METRICS_DB` and
  `COPILOT_API_SQLITE_DB_PATH` override those locations. `stats`/`events` read them offline.
  `bench` is bounded to 1–10 runs, 32–2048 max output tokens and concurrency 1–4,
  but still sends real inference and consumes quota. Responses completion requires
  `response.completed`: failed/incomplete/missing terminal events do not count as
  success merely because HTTP status was 200. Metrics record kind/size, attempts,
  timeout owner and drain outcome, not request/response bodies or credentials.

State lives under `~/.local/state/copilot-proxy/`; device login stores the GitHub
token at `~/.local/share/copilot-api/github_token` without printing it by default.
A detached watcher appends process lifecycle records to `lifecycle.jsonl`: spawn,
ready, startup failure, exit code, package/version/PID/port, and whether shutdown
was deliberate or unexpected. Before recovery rotates the logs, an unexpected
shim exit also copies only safe Bun native-crash markers (version, OS, panic,
crash banner and `bun.report` URL) from current stderr into `crash_summary`; it
never copies requests, prompts, tools, tokens or arbitrary stderr. If the journal
cannot be appended after retries, the same structured row goes to
`watcher-failures.jsonl`. A shim that had reached ready and then exits unexpectedly
on a legacy backend is restarted at most three times after 1s/5s/30s, only while the shim
remains enabled, port 4141 is healthy, and port 4142 is still down. Five minutes of
stable uptime resets the budget. Startup failures and deliberate stops never
restart; the watcher never restarts port 4141 and never fails open to it. Recovery
adds `restart_scheduled`, `restart_succeeded`, `restart_failed`,
`restart_suppressed`, or `restart_exhausted` rows.

For backend 2.5.2 or newer (and unknown versions), a ready shim crash emits
`recovery_required` and does not trigger an automatic shim-only restart. Backend
work may still exist. The shared shim persists an admission barrier next to its
metrics database (`metrics.sqlite.admission.json`); an orphaned/corrupt barrier
blocks new inference while health stays inspectable. Inspect active/draining/
unknown work, then use a controlled `copilot-proxy restart` of both processes.
Only a confirmed full stop clears that barrier; a failed stop or shim-only
restart preserves it. The wrapper never automatically restarts the backend.

Inspect the journal with `copilot-proxy logs lifecycle`; request-level attempts and
stream failures remain in `stats`/`events`. Proxy and shim stdout/stderr rotate
independently for three sessions. `logs shim err 80` reads current stderr, while
`logs shim err 80 1` reads the previous generation (up to generation 3); stdout
uses the same syntax without `err`. Applying a new shim file or upgrading Bun does
not reload the already-running process; restart it deliberately after active turns
drain.

## Codex through the gateway

`codex-copilot` and its identical `codex-copilot-once` alias start the local
gateway/shim and pass a `copilot_api` Responses provider through one-invocation
Codex `-c` overrides. That provider supplies its own authentication, so the
launcher does not require a Codex/ChatGPT login; an existing login is neither
removed nor changed. They do not edit user or project Codex config, so plain
`codex` is unaffected. An explicit `-m` / `--model` wins; otherwise the live raw
catalog uses the same tier-aware policy in OpenAI/Codex-first order, then Claude,
grok, Gemini and other chat models. Policy-disabled, picker-hidden, embedding-only,
and `-fast` main candidates are excluded from automatic selection. This choice
is independent of any previous model state or Claude project pin; raw model id
and context/prompt limits come from the same catalog snapshot, without persisting
the selection.

Codex uses the enabled shim on `localhost:4142`; explicit `copilot-proxy shim off`
uses the backend directly. With the shim enabled, Codex request/stream retries
default to `0/0`, leaving replay ownership with the shim. Direct mode retains
`3/1`; later explicit `-c` arguments retain precedence in direct and SpecStory
launches. Besides throttling, the shim boundary normalizes blank
descriptions in Codex `mcp_list_tools` Responses items. GitHub Copilot rejects
those with `Invalid 'input[0].tools[0].description': empty string`, while MCP
servers and the native Codex path may omit them. The shim fills only those tool
definition fields and leaves prompts, schemas, and tool names unchanged.
Codex currently zstd-compresses these requests; the shim decodes only a Responses
body it must repair, forwards ordinary JSON, and removes the stale
`content-encoding` header. A zstd body that needs no tool-description repair remains
opaque to stream classification and therefore stays on the transparent,
no-pre-header-keepalive path; same-model transport retries still apply.

This is a separate picker from Claude Code's `copilot-model --auto`: that path
remains Claude-first, while only the Codex launcher is OpenAI-first.

SpecStory is automatic when installed. Before starting its watcher, the wrapper
creates the Codex `sessions` directory under `CODEX_HOME` (or `~/.codex`); if
that initialization fails, it stops with an actionable error before launching
either child process. A first run therefore cannot reach SpecStory with a missing
watch root. The wrapper preserves the effective `codex_cmd` (project config >
user config > bare `codex`) before appending provider/model/user arguments;
`--no-specstory` runs Codex directly. SpecStory's own sync policy still applies
to automatic sessions and may upload captured history to SpecStory Cloud and
update the project's `.specstory/statistics.json`. Claude and
Gemini fallback through Responses Lite, which does not support Responses
`tool_search`, so native Responses OpenAI models stay ahead of Anthropic.
The launcher also enables gateway-backed remote compaction and excludes the
`mcp__codex_apps__sites` namespace that depends on unavailable `tool_search`;
later explicit `-c` arguments can override either setting per invocation.

`codex_apps` itself is not a localhost service and not an Apple-Silicon-only
Codex Desktop bridge. It is a remote MCP at
`https://chatgpt.com/backend-api/wham/apps`, so startup can fail even while
Copilot inference on `localhost:4142` works. Keep Apps enabled and use
`copilot-proxy doctor --live` to diagnose that route independently.

There is deliberately no Codex equivalent of `copilot-here`: project
`.codex/config.toml` cannot override provider definitions, provider selection or
auth metadata. The explicit launcher provides project/session scope without
changing the user-wide default.

### Experimental direct configuration

The direct `model_providers.copilot-enterprise` example is documented in the
macOS/Linux guide rather than installed. It is not the localhost proxy path, and
the pasted `gh auth token` flow is not portable: on the tested EMU account it
returned `421`/`403`, while the credential stored by `copilot-proxy auth` plus
the normal short-lived Copilot token exchange worked. The supported launcher
therefore uses the authenticated local gateway.

### Login proxy troubleshooting

`copilot-proxy auth` applies `COPILOT_HTTP_PROXY` to the login process. The fork
supports `--proxy-env` only on `start`, so login uses a Node preload with the
installed package's Undici proxy dispatcher. Environment variables are restored
on success or failure. `Bad credentials` during token refresh requires a new
device login; restarting cannot repair a rejected GitHub credential. Inspect
startup errors with `copilot-proxy logs err`.
