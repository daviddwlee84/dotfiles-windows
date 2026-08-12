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
| `copilot-proxy auth` | one-time GitHub device login (stores a token) |
| `copilot-proxy start` / `stop` / `restart` | manage the local proxy (port 4141) |
| `copilot-proxy status` | show raw served count and Claude availability |
| `copilot-proxy doctor [--live]` | diagnose package, auth, proxy, catalog, roles, upstream and Codex Apps |
| `copilot-proxy logs [N]` | tail the proxy log |
| `copilot-proxy shim [on\|off]` | toggle the throttle shim (port 4142) |
| `copilot-proxy whoami` | account / plan / quota |
| `copilot-proxy reinstall` | wipe and reinstall the pinned package |
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

The default package is `@jeffreycao/copilot-api@2.1.0`. For GPT ids it translates
Claude Code requests to Responses, including `output_config.effort` to
`reasoning.effort`. This is required for GPT-5.6 and Claude Code's `ultracode`
effort setting; the old `1.13.14` path could replace the requested effort with a
hard-coded fallback.

The package is installed once under `~/.local/share/copilot-api/pkg`. Windows
uses `npm.cmd` first because it understands the Azure Artifacts credential
provider in `~/.npmrc`; Bun remains the fallback/runtime. A package-version stamp
makes the 2.1.0 bump reinstall automatically. Warm starts do no package network
work.

## Model selection and role profile

`copilot-model --auto` requires the live `/v1/models` catalog. It prefers served
Claude families (`Fable > Opus > Sonnet > Haiku`), then ranks OpenAI by capability:

```text
Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini > Gemini
```

Luna follows the older flagships because it is the lightweight tier. This role
intent follows OpenAI's [current model guidance](https://developers.openai.com/api/docs/guides/latest-model).
For the normal Claude-less Copilot catalog, the generated profile is:

| Claude Code role | Copilot model |
|---|---|
| Main / Fable / Opus | `gpt-5.6-sol` |
| Sonnet | `gpt-5.6-terra` |
| Haiku / background / legacy small-fast | `gpt-5.6-luna` |

A manually selected OpenAI main remains Main/Fable/Opus; Terra and Luna are used
for the lower roles when served. Missing tiers fall back to the selected main,
never to an unserved hard-coded id. Native Claude profiles select the strongest
served model in each Claude family.

The `[1m]` suffix is a Claude Code-only context hint. It is derived from each
model's live `max_context_window_tokens` metadata when the value is at least one
million. Raw API clients must use the plain id. Offline manual discovery remains
available, but offline `--auto` refuses to write a potentially stale pin.

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
| `ultracode` | Yes on 2.1.0 | It is xhigh effort plus dynamic workflows, not a separate model. |
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
- The model catalog is fetched once at proxy startup. `COPILOT_PROXY_START_TIMEOUT`
  defaults to 45 seconds because a Clash/mihomo hop can make that refresh exceed
  the old 20-second budget.
- GitHub can vary the catalog by account, organization policy, rollout and egress.
  No Claude models is therefore a warning when a served OpenAI fallback exists;
  it is not by itself a broken proxy.
- `copilot-proxy doctor` compares direct and proxied upstream catalogs, validates
  the main model plus every role alias, and reports stale local pins. `--live`
  also compares direct/proxied reachability of remote ChatGPT `codex_apps`, then
  sends one real inference request. Only the latter consumes quota; timeout and
  TLS failures are reported separately.
- `copilot-here` writes only the gitignored `.claude/settings.local.json`, never
  committed project settings. `off` removes every env key owned by the helper and
  preserves unrelated settings.
- `claude-copilot` and `claude-copilot-once` retain the Windows port's trusted
  `--dangerously-skip-permissions` and optional SpecStory behavior. Plain `claude`
  is unaffected.
- The throttle shim remains byte-identical to the macOS/Linux copy and retries
  403/429 bursts while limiting concurrent requests.

State lives under `~/.local/state/copilot-proxy/`; the GitHub token is stored at
`~/.local/share/copilot-api/github_token`.

## Codex through the gateway

`codex-copilot` and its identical `codex-copilot-once` alias start the local
gateway/shim and pass a `copilot_api` Responses provider through one-invocation
Codex `-c` overrides. They do not edit user or project Codex config, so plain
`codex` is unaffected. An explicit `-m` / `--model` wins; otherwise the live raw
catalog is ranked OpenAI/Codex first (`Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3
Codex > Luna > mini`), then Claude, Gemini and other chat models. Disabled and
embedding models are excluded.

This is a separate picker from Claude Code's `copilot-model --auto`: that path
remains Claude-first, while only the Codex launcher is OpenAI-first.

SpecStory is automatic when installed. The wrapper preserves the effective
`codex_cmd` (project config > user config > bare `codex`) before appending
provider/model/user arguments; `--no-specstory` runs Codex directly. Claude and
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
