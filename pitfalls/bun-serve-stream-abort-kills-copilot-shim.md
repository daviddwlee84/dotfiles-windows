# Codex stream disconnect leaves the Copilot shim down

**Symptoms** (grep this section): `stream disconnected before completion: error sending request for url (http://localhost:4142/responses)`, `shim: ON but DOWN`, lifecycle `unexpected_exit`, shim exit code `3`, port 4141 still healthy while port 4142 refuses connections

**First seen**: 2026-08-27
**Affects**: Windows, Bun 1.3.14, `copilot-throttle-shim.js`, streamed Codex/Responses clients
**Status**: contained locally; bounded shim-only recovery added; relevant Bun fixes exist upstream after 1.3.14

## Symptom

A Codex turn can begin streaming and then report:

```text
stream disconnected before completion: error sending request for url (http://localhost:4142/responses)
```

Afterward:

```text
copilot-proxy: RUNNING on http://localhost:4141
  shim:   ON but DOWN (managed clients fail closed; break glass: copilot-proxy shim off)
```

The lifecycle journal captured a real process death rather than a bad health probe:

```json
{"component":"shim","event":"unexpected_exit","port":4142,"exit_code":3}
```

The independent port-4141 proxy remained alive. Shim stderr may be empty because the fatal rejection is reported by Bun's internal response-stream pump, not by the application's normal request error path.

## Root cause

Bun 1.3.14 predates two directly relevant `Bun.serve` fixes:

- [`80729349`](https://github.com/oven-sh/bun/commit/80729349a71adac9dcc4dbaae26441db3d2910bf): an error from a streamed `Response` body must not become an unhandled rejection that terminates the server.
- [`3da09633`](https://github.com/oven-sh/bun/commit/3da09633125a1dc63bd3e602e27ccf1b39c44356): when the peer aborts mid-stream, mark the internal `readableStreamCancel()` Promise as handled.

The shim exposed the same class of failure in three ways:

1. Its `ReadableStream` sources call `controller.error()` for a genuinely truncated upstream body.
2. Its fast and post-keepalive downstream `cancel()` callbacks discarded the Promise returned by `reader.cancel()`; synchronous `try/catch` cannot catch a later Promise rejection.
3. SQLite metric initialization/finalization could throw from inside a stream callback.

The production exit code and timing are consistent with Bun's fatal `unhandledRejection` policy. The raw TCP truncation/abort fixture did **not** make this exact Bun 1.3.14 build exit, so it does not prove which individual production callback supplied the fatal rejection. A deterministic child-process rejection probe is retained alongside the realistic network cases to verify the process-level containment without overstating that distinction.

This is separate from a startup race or a foreign process owning port 4142. Those have different lifecycle timing and are covered by [`copilot-proxy-shim-port-held-by-another-process.md`](copilot-proxy-shim-port-held-by-another-process.md).

## Fix and recovery

The canonical parent/Windows shim now:

- installs one `startServer()`-scoped `unhandledRejection` compatibility guard while leaving CLI command failures fatal;
- funnels body/reader cancellation through a helper that consumes synchronous throws and rejected Promises;
- treats metrics database open/write failures as best-effort;
- catches request-body assembly failures when a client disappears during a large Codex tools upload;
- preserves real stream failure semantics and endpoint-native terminal events instead of pretending a truncated stream completed.

Windows adds a second layer. A per-port named mutex serializes shim startup, and the detached watcher restarts only a shim that had previously reached `ready`. Recovery requires all of:

- persisted shim state is not `off`;
- port 4141 still answers health;
- port 4142 is still unhealthy;
- shutdown had no deliberate-stop intent.

Quick failures receive at most three attempts after 1s, 5s, and 30s. Five minutes of stable uptime resets that budget. Startup failures, deliberate stops, and port-4141 exits never trigger this recovery; managed clients remain fail-closed.

Inspect evidence before manually restarting:

```powershell
copilot-proxy logs lifecycle 40
copilot-proxy logs shim err 80
copilot-proxy events --limit 40 --json
copilot-proxy status
```

A source-file apply does not reload an already-running Bun process. Wait for active agent turns to drain, then explicitly restart the shim/proxy when operationally safe.

## Prevention

- Keep the parent and Windows shim files byte-identical and pin the exact parent commit/SHA-256 in `tests/Copilot.Tests.ps1`.
- Run `tests/fixtures/copilot-shim-process-survival.mjs` against the supported Bun version. It verifies upstream truncation, fast and post-keepalive downstream aborts, post-completion closes, a fatal-rejection discriminator, and subsequent health on the same process.
- Keep rejecting-cancellation and throwing-metrics-backend cases in `copilot-shim-hardening.mjs`.
- Do not replace `settleCancellation()` with bare `reader.cancel()` inside a synchronous `try/catch`.
- Do not broaden recovery to the port-4141 proxy or remove the ready/intent/state/health gates.

## Related

- [`docs/copilot-proxy.md`](../docs/copilot-proxy.md)
- [`copilot-proxy-shim-port-held-by-another-process.md`](copilot-proxy-shim-port-held-by-another-process.md)
- Parent canonical commit `2799866e2074da080a6afd115578ab3350847aa9`
