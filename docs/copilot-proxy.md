# copilot-proxy

A native PowerShell port of the `copilot-proxy` tool series: it runs the
[copilot-api](https://github.com/caozhiyuan/copilot-api) fork so a **GitHub Copilot
subscription** can back **Claude Code** (and any Anthropic/OpenAI-compatible client).

Shipped as a module at `~/.config/powershell/modules/Copilot`, auto-imported by the
`$PROFILE`. Requires `bun` (installed via mise) and a Copilot subscription.

## Commands

| Command | What it does |
|---|---|
| `copilot-proxy auth` | one-time GitHub device login (stores a token) |
| `copilot-proxy start` / `stop` / `restart` | manage the local proxy (port 4141) |
| `copilot-proxy status` | is it up? which models? |
| `copilot-proxy doctor [--live]` | diagnose prereqs → auth → proxy → model entitlement → upstream |
| `copilot-proxy logs [N]` | tail the proxy log |
| `copilot-proxy shim [on\|off]` | toggle the throttle shim (port 4142) |
| `copilot-proxy whoami` | account / plan / quota |
| `copilot-run <cmd...>` | run a command with the proxy env injected |
| `claude-copilot` | one-off Claude Code session on the proxy |
| `claude-copilot-once` | pin this project, run once, auto-unpin (even on Ctrl-C) |
| `copilot-here [on\|off\|status]` | sticky per-project pin via `.claude/settings.local.json` |
| `copilot-model [<id>\|-l\|-c]` | switch the pinned model |
| `copilot-embed [TEXT\|-]` | embed text via the proxy's `/v1/embeddings` |
| `semsearch index \| <QUERY>` | semantic search over local text |

## Quick start

```powershell
copilot-proxy auth        # once
copilot-proxy start
copilot-proxy doctor      # verify the whole path
claude-copilot            # a Claude Code session backed by Copilot
```

## Notes

- **Default model** is `claude-opus-4-8[1m]`. The `[1m]` suffix is a Claude Code
  hint for the 1M-context window; it's stripped before validating against the proxy.
- **`copilot-here`** writes only the gitignored `.claude/settings.local.json`, never
  the committed `.claude/settings.json`, and adds a `.git/info/exclude` entry so the
  pin never lands in a commit.
- **`claude-copilot` / `claude-copilot-once`** run Claude Code with
  `--dangerously-skip-permissions` — the proxy path is the trusted, hands-off flow,
  so it never stops for permission prompts (plain `claude` is unaffected; the global
  default stays `auto`). When the SpecStory CLI is on `PATH` they also wrap the
  session in `specstory run` for auto-saved transcripts; on Windows that CLI has no
  official release, so it's opt-in via the **SpecStory build** init prompt.
- **The throttle shim** (`copilot-throttle-shim.js`, run under Bun) caps concurrent
  in-flight requests and transparently retries 403/429 bursts — it's the same JS used
  on macOS/Linux, unchanged.
- State lives under `~/.local/state/copilot-proxy/`; the token under
  `~/.local/share/copilot-api/github_token`.

!!! warning "Entitlement"
    Some Copilot plans serve no Anthropic models — every request then returns
    `400 model_not_supported`. `copilot-proxy doctor` distinguishes that
    account-policy case from a stale model cache.
