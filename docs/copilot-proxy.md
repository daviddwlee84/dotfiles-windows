# copilot-proxy

A native PowerShell port of the `copilot-proxy` tool series. It runs the
[`@jeffreycao/copilot-api`](https://www.npmjs.com/package/@jeffreycao/copilot-api)
fork so a **GitHub Copilot subscription** can back **Claude Code** and other
Anthropic/OpenAI-compatible clients.

The module is deployed to `~/.config/powershell/modules/Copilot` and imported by
the PowerShell profile. It requires Bun, Node/npm and a Copilot subscription.

## Commands

| Command | What it does |
|---|---|
| `copilot-proxy auth` | one-time GitHub device login (`copilot-api auth login --provider copilot`; stores but does not display the token) |
| `copilot-proxy start` / `stop` / `restart` | manage the local proxy (port 4141) |
| `copilot-proxy status` | show raw served count and Claude availability |
| `copilot-proxy doctor [--live]` | diagnose package, auth, proxy, catalog, roles, upstream and Codex Apps |
| `copilot-proxy logs [N]` | tail the proxy log |
| `copilot-proxy shim [on\|off]` | toggle the metrics/throttle shim (port 4142; default on) |
| `copilot-proxy stats` / `events` | query the local metrics databases, including while processes are down |
| `copilot-proxy quota` | show live account / plan / quota |
| `copilot-proxy bench --model ID` | run bounded real Responses benchmarks (consumes quota) |
| `copilot-proxy whoami` | account / plan / quota |
| `copilot-proxy reinstall` | wipe and reinstall the selected package |
| `copilot-proxy update VERSION` | stage, verify and select exact 2.3.4/2.3.0/2.1.0 without restarting |
| `copilot-proxy rollback` | swap to the previous verified package offline, without restarting |
| `copilot-run <cmd...>` | run a command with the proxy env injected |
| `claude-copilot` | one-off Claude Code session on the proxy |
| `claude-copilot-once` | pin this project, run once, then restore it |
| `codex-copilot` / `codex-copilot-once` | zero-persistence Codex session on the Responses proxy |
| `copilot-here [on\|off\|status]` | sticky project pin in `.claude/settings.local.json` |
| `copilot-model [<id>\|-l\|-c\|--auto]` | switch or inspect the complete role profile |
| `copilot-embed [TEXT\|-]` | embed text through `/v1/embeddings` |
| `semsearch index \| <QUERY>` | semantic search over local text |

## Quick start

```powershell
copilot-proxy auth                 # once
copilot-proxy start
copilot-model --auto              # select from the live catalog
copilot-model -c                   # inspect Main/Fable/Opus/Sonnet/Haiku
copilot-here on                    # sticky project; or use claude-copilot-once
codex-copilot                     # Codex; live OpenAI-first model selection
```

Existing global and project pins are deliberately not migrated by `chezmoi
apply`. Run `copilot-model --auto` once after this upgrade. When `copilot-here`
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

The default package is `@jeffreycao/copilot-api@2.3.4`. For GPT ids it translates
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
`$XDG_STATE_HOME/copilot-proxy/package.json` → built-in 2.3.4. A verified existing
2.1.0/2.3.0 install is persisted before the built-in is considered, so applying
this module never performs an implicit network upgrade.

Use `copilot-proxy update 2.3.4` to stage and verify the reviewed release, preserve
the old tree as `pkg.previous`, and select it without restarting the running
proxy. Restart deliberately afterward. `copilot-proxy rollback` swaps the two
verified trees offline; exact `update 2.3.0` and `update 2.1.0` remain supported.
The 2.3.4 package is tied to source commit `a51553569ba071e0c9a8329f8f5ccac2482a3945`,
npm SHA-1 `643f59e0c257db613954738f02300c0a7ceebfeb`, and SRI
`sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ==`.

On a corporate mirror, `ETARGET` can mean the exact public version has not synced
yet. Check the registry that npm is actually using before deleting the working
prefix:

```powershell
npm config get registry
npm view '@jeffreycao/copilot-api@2.3.4' version
# Optional comparison where direct public npm is permitted:
npm view '@jeffreycao/copilot-api@2.3.4' version --registry https://registry.npmjs.org/
```

If only the configured mirror is missing the version, wait/request mirror sync or
use an approved registry for `copilot-proxy reinstall`. The Windows module also
falls back automatically to the exact 2.3.4 runtime files on jsDelivr, verifies a
baked SHA-256 for every file, then resolves only its ordinary dependencies through
the configured npm registry. This handles a lagging mirror without weakening the
pin or bypassing the approved feed for the dependency tree. Do not replace the
tested exact pin with `latest`.

## Model selection and role profile

`copilot-model --auto` requires the live `/v1/models` catalog and chooses a
profile **before any later inference request**. Automatic candidates exclude
policy-disabled, picker-hidden and embedding-only entries; raw listing and explicit
manual selection remain available as user overrides. It prefers served Claude
families (`Fable > Opus > Sonnet > Haiku`), then uses the same named OpenAI tier
order as the Codex launcher:

```text
Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini > Gemini
```

Luna follows the older flagships because it is the lightweight tier. Unknown future
GPT ids are considered only after every named OpenAI tier above is absent. This role
intent follows OpenAI's [current model guidance](https://developers.openai.com/api/docs/guides/latest-model).
For the normal Claude-less Copilot catalog, the generated profile is:

| Claude Code role | Copilot model |
|---|---|
| Main / Fable / Opus | `gpt-5.6-sol` |
| Sonnet | `gpt-5.6-terra` |
| Haiku / background / legacy small-fast | `gpt-5.6-luna` |

A manually selected OpenAI main remains Main/Fable/Opus; Terra and Luna are used
for the lower roles only when served and selectable. Missing or policy-vetoed tiers
fall back to the selected main, never to an unserved hard-coded id. Native Claude
profiles likewise choose only selectable alternatives in each Claude family.

The `[1m]` suffix is a Claude Code-only context hint. It is derived from each
model's live `max_context_window_tokens` metadata when the value is at least one
million. Raw API clients must use the plain id. Offline manual discovery remains
available, but offline `--auto` refuses to write a potentially stale pin.

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
```

`CLAUDE_CODE_SUBAGENT_MODEL` is intentionally left unset so workflow/frontmatter
routing remains authoritative. Restart Claude Code after changing the profile.

## Claude Code feature compatibility

The useful boundary is local orchestration versus Anthropic cloud services:

| Feature | Through Copilot + GPT | Notes |
|---|---|---|
| CLI, tools, hooks, skills, memory, plugins, MCP, checkpoints, sandboxing | Yes | Local Claude Code features; GPT behavior may differ after prompt/tool translation. |
| Subagents and dynamic workflows | Yes | Role variables are provided without overriding workflow-specific subagent routing. See [workflows](https://code.claude.com/docs/en/workflows). |
| `ultracode` | Yes on 2.3.4 | It is xhigh effort plus dynamic workflows, not a separate model. |
| Thinking/reasoning | Translated | GPT uses Responses reasoning rather than Anthropic-native thinking semantics. |
| Web search, fast/auto mode, MCP tool search | Provider-dependent | Availability depends on the Copilot endpoint and gateway translation. |
| Ultrareview, Remote Control, Chrome, cloud Code Review, routines, web/mobile/Slack sessions | No | These require Claude.ai authentication/cloud identity; a local API gateway cannot provide it. |

See Claude Code's [feature availability](https://code.claude.com/docs/en/feature-availability),
[model configuration](https://code.claude.com/docs/en/model-config),
[gateway protocol](https://code.claude.com/docs/en/llm-gateway-protocol), and
[Ultrareview](https://code.claude.com/docs/en/ultrareview) references.

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
  `--dangerously-skip-permissions` and optional SpecStory behavior. On the
  SpecStory path they resolve the project/user `claude_cmd` as the base, enforce
  one bypass flag, quote all user arguments, and always pass the complete command
  through `specstory run claude -c` (including zero-argument sessions). The
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
- The metrics/throttle shim is pinned byte-for-byte to parent commit `b205a2a`.
  It limits concurrent requests and retries the **same buffered request and model**
  on network errors or HTTP 403/429/500/502/503/504 before any upstream body is
  exposed. HTTP 402 and bare 401 pass through once; no request-time model substitution
  occurs. Queue/backoff cancellation releases permits promptly.
- For literal `stream:true`, the shim emits keepalive comments after the grace period,
  requires successful upstream bodies to be SSE, and translates late failures to
  Anthropic `error` or Responses `response.failed` terminal events. The stall
  watchdog remains active when pings are disabled. Timing and token rows live in
  `$XDG_STATE_HOME/copilot-proxy/metrics.sqlite` and
  `$XDG_DATA_HOME/copilot-api/copilot-api.sqlite`; `stats`/`events` read them offline.
  `bench` is bounded to 1–10 runs, 32–2048 max output tokens and concurrency 1–4,
  but still sends real inference and consumes quota.

State lives under `~/.local/state/copilot-proxy/`; device login stores the GitHub
token at `~/.local/share/copilot-api/github_token` without printing it by default.

## Codex through the gateway

`codex-copilot` and its identical `codex-copilot-once` alias start the local
gateway/shim and pass a `copilot_api` Responses provider through one-invocation
Codex `-c` overrides. That provider supplies its own authentication, so the
launcher does not require a Codex/ChatGPT login; an existing login is neither
removed nor changed. They do not edit user or project Codex config, so plain
`codex` is unaffected. An explicit `-m` / `--model` wins; otherwise the live raw
catalog is ranked OpenAI/Codex first (`Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3
Codex > Luna > mini`), then Claude, Gemini and other chat models. Policy-disabled,
picker-hidden and embedding-only entries are excluded from automatic selection.

Codex always uses the shim on `localhost:4142`, even when the persisted
throttling toggle is off. Besides throttling, that boundary normalizes blank
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
