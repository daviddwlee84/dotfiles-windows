# copilot-proxy

A native PowerShell port of the `copilot-proxy` tool series: it runs the
[copilot-api](https://github.com/caozhiyuan/copilot-api) fork so a **GitHub Copilot
subscription** can back **Claude Code** (and any Anthropic/OpenAI-compatible client).

Shipped as a module at `~/.config/powershell/modules/Copilot`, auto-imported by the
`$PROFILE`. Requires `bun` (installed via scoop) and a Copilot subscription.

## Commands

| Command | What it does |
|---|---|
| `copilot-proxy auth` | one-time GitHub device login (stores a token) |
| `copilot-proxy start` / `stop` / `restart` | manage the local proxy (port 4141) |
| `copilot-proxy status` | is it up? which models? |
| `copilot-proxy doctor [--live]` | diagnose prereqs → package → auth → proxy → Claude catalog → upstream |
| `copilot-proxy logs [N]` | tail the proxy log |
| `copilot-proxy shim [on\|off]` | toggle the throttle shim (port 4142) |
| `copilot-proxy whoami` | account / plan / quota |
| `copilot-proxy reinstall` | wipe + re-install the pinned copilot-api package |
| `copilot-run <cmd...>` | run a command with the proxy env injected |
| `claude-copilot` | one-off Claude Code session on the proxy |
| `claude-copilot-once` | pin this project, run once, auto-unpin (even on Ctrl-C) |
| `copilot-here [on\|off\|status]` | sticky per-project pin via `.claude/settings.local.json` |
| `copilot-model [<id>\|-l\|-c\|--auto]` | switch the pinned model |
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

- **Default model** is `claude-opus-5[1m]`. The `[1m]` suffix is a Claude Code
  hint for the 1M-context window; it's stripped before validating against the proxy.
  `copilot-model --auto` re-picks from the live served catalog
  (Claude > Codex > GPT > Gemini) — useful when a sticky pin has gone stale.
- **The pinned package is installed once** into `~/.local/share/copilot-api/pkg`
  and run from there. `start` deliberately does **not** use `bunx`, which re-resolves
  the package on every launch: bun can stall indefinitely resolving through a socks
  proxy, and the wedged installer keeps bun's global cache lock so every retry hangs
  the same way. A warm start now does zero network before binding the port. Bumping
  `COPILOT_API_PKG` re-installs via the `.installed-spec` stamp;
  `copilot-proxy reinstall` forces it.
- **`COPILOT_HTTP_PROXY`** (`auto` | `always` | `never` | `http://127.0.0.1:PORT`)
  controls how Node fetches GitHub's model catalog. `auto` picks up the Windows
  System Proxy (what Clash Verge / mihomo / v2rayN set) or `HTTPS_PROXY`, and passes
  `--proxy-env` so Node actually uses it — Node ignores the system setting on its
  own. This matters because copilot-api caches `/models` **once at startup**: on an
  egress where GitHub geo-filters the Claude catalog, the proxy would otherwise
  cache a Claude-less list for its whole lifetime. `copilot-proxy doctor` A/Bs the
  direct and via-proxy catalogs to tell that apart from an entitlement problem.
- **`copilot-here`** writes only the gitignored `.claude/settings.local.json`, never
  the committed `.claude/settings.json`, and adds a `.git/info/exclude` entry so the
  pin never lands in a commit. `copilot-here status` and `claude-copilot-once` report
  when an existing pin has drifted from current defaults (model bump, proxy moved,
  a key added since) and offer to refresh it in place.
- **`claude-copilot` / `claude-copilot-once`** run Claude Code with
  `--dangerously-skip-permissions` — the proxy path is the trusted, hands-off flow,
  so it never stops for permission prompts (plain `claude` is unaffected; the global
  default stays `auto`). When the SpecStory CLI is on `PATH` they also wrap the
  session in `specstory run` for auto-saved transcripts; on Windows that CLI has no
  official release, so it's opt-in via the **SpecStory build** init prompt. When args
  are passed through, the `-c` command string is rebuilt from specstory's configured
  `claude_cmd` — `-c` *replaces* that command rather than appending to it, so a
  hardcoded string would silently drop its flags (that is how `claude-copilot-once`
  and `claude-copilot-once --resume X` ended up in different permission modes).
- **The throttle shim** (`copilot-throttle-shim.js`, run under Bun) caps concurrent
  in-flight requests and transparently retries 403/429 bursts — it's the same JS used
  on macOS/Linux, unchanged.
- State lives under `~/.local/state/copilot-proxy/`; the token under
  `~/.local/share/copilot-api/github_token`.

!!! warning "Entitlement"
    Some Copilot plans serve no Anthropic models — every request then returns
    `400 model_not_supported`. `copilot-proxy doctor` distinguishes that
    account-policy case from a stale model cache.
