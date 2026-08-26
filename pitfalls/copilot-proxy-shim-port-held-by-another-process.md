# Managed Copilot clients run against the bare proxy, or the shim never comes up on a busy port

**Symptoms** (grep this section):
- `copilot-run <cmd>` works, but the Responses tool-description normalization is
  clearly not applied — Codex-style calls come back
  `400 ... tool description ... empty`, the exact failure
  [`codex-copilot-empty-mcp-tool-description-400.md`](codex-copilot-empty-mcp-tool-description-400.md)
  says the shim fixes. Nothing warns you.
- Long OpenAI reasoning turns go silent again and get reaped, as if the SSE
  keepalive were not there — because it isn't; the shim was bypassed.
- `copilot-proxy status` says `shim: ON but DOWN` while clients keep working.
  That combination is the tell: they are talking to `:4141` directly.
- Or the opposite failure: `copilot-proxy: shim did not come up — check
  ...\copilot-shim-4142.log`, with `EADDRINUSE` / `Failed to start server. Is
  port 4142 in use?` only inside that log.
- After `Start-CopilotShim` runs once, `$env:COPILOT_SHIM_UPSTREAM` is set in
  your session forever and every later `bun copilot-throttle-shim.js` inherits it.

**First seen**: 2026-08-26
**Affects**: `dot_config/powershell/modules/Copilot/Copilot.psm1`
**Status**: fixed 2026-08-26

## Root cause

`Test-CopilotShimAlive` is a **reachability** probe, not an identity probe:

```powershell
Invoke-WebRequest -Uri "$(Get-CopilotShimBase)/v1/models" -TimeoutSec 2 -SkipHttpErrorCheck
```

`-SkipHttpErrorCheck` means a `404` or `500` counts as alive, and the Unix shim's
`/_shim/health` route does not exist in this build (the shim here is pinned to
Unix commit `ee5612c`, one generation before the metrics layer — see the SHA-256
contract in `tests/Copilot.Tests.ps1`). So the probe answers *"something on this
port speaks HTTP"* and nothing more. Three separate bugs grew out of trusting it:

**1. Fail-open routing.** `Get-CopilotClientBase` returned the bare proxy when
the shim was enabled but not alive, and `copilot-run` discarded the start result
outright:

```powershell
if ((Get-CopilotShimEnabled) -and -not (Test-CopilotShimAlive)) { Start-CopilotShim | Out-Null }
```

A down shim therefore degraded silently instead of failing. On Unix the same
situation is a hard fault (`managed client refused to bypass the enabled metrics
shim`) — and the degradation matters more here than the name "metrics" suggests,
because the shim also carries the keepalive **and** the tool-description
normalization.

**2. A foreign listener passed as the shim.** Any unrelated HTTP server on 4142
answers the probe, so it silently became the gateway every managed client used.

**3. "Not alive" was read as "port free".** An older or stale
`copilot-throttle-shim.js` that does not answer the probe made
`Start-CopilotShim` spawn a replacement that died instantly with `EADDRINUSE` —
ten one-second retries, then failure, with the reason only ever written to a
detached log file.

Separately, `$env:COPILOT_SHIM_PORT = ...` inside `Start-CopilotShim` is
**process-wide** in PowerShell — function scope does not apply to `$env:` — so
it leaked into the caller's session permanently.

## Fix

- `Get-CopilotPortOwner -Port` classifies the port as `free` / `ours` /
  `foreign` / `unknown` via `Get-NetTCPConnection` + `Win32_Process.CommandLine`.
  `unknown` (no `Get-NetTCPConnection`) degrades to the old behaviour rather
  than falsely accusing a squatter.
- `Start-CopilotShim` refuses on `foreign` (naming PID + process), reclaims on
  `ours`, and only then spawns. Failure tails 5 lines of both log files inline.
- `Get-CopilotClientBase` returns the shim base whenever the shim is *enabled*,
  and `Assert-CopilotShim` (mirroring Unix `_copilot_require_shim`) is the gate
  every managed client goes through. `copilot-run` now returns instead of
  bypassing.
- `COPILOT_SHIM_*` is set, spawned against, and restored in a `finally`.

`Assert-CopilotShim` deliberately calls `Start-CopilotShim` directly rather than
short-circuiting on `Test-CopilotShimAlive`: liveness cannot prove identity here,
and the starter is idempotent and returns fast when the shim is already ours.

## Generalisable

**A reachability probe must never decide port state, and must never decide
identity.** When "is it healthy?" is weaker than "is the port mine?", every gap
between the two becomes either a silent bypass (probe too permissive) or an
unrecoverable `EADDRINUSE` wedge (probe too strict). Read the port from the OS
and the owner from the process table; keep the HTTP probe for what it can
actually answer.

**In PowerShell, `$env:X = ...` is not scoped.** Any helper that sets one for a
child process must save and restore it, exactly as `copilot-run` already did for
the `ANTHROPIC_*` block.

## See also

- [`codex-copilot-empty-mcp-tool-description-400.md`](codex-copilot-empty-mcp-tool-description-400.md) — what a bypassed shim silently reintroduces
- Unix counterpart: `pitfalls/copilot-proxy-shim-eaddrinuse-stale-build.md` in the parent dotfiles repo
