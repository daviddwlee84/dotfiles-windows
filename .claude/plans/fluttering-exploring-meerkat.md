# Harden Codex Copilot Shim Process Survival

## Context

A real production outage was recorded: shim PID 74860 became ready at `2026-08-27T11:16:04Z`, exited unexpectedly at `11:48:12Z` with exit code 3, while the independent port-4141 proxy remained alive. The machine runs Bun 1.3.14, predating upstream `Bun.serve` fixes `80729349` (stream-body errors must not terminate the server) and `3da09633` (handle the internal cancel promise when a peer aborts a response). The shared shim uses custom response streams and currently discards two `reader.cancel()` promises; metric finalization can also throw from a stream callback.

The initial raw-TCP fixture now present at `tests/fixtures/copilot-shim-process-survival.mjs` passes all four network scenarios on Bun 1.3.14, so it does not by itself prove which internal rejection caused the observed exit. The implementation will retain those realistic cases and add a deterministic fatal-rejection discriminator. The intended outcome is that one canceled or failed Codex SSE request cannot kill port 4142, and an unrelated future shim-only crash is recovered a bounded number of times without failing open to port 4141.

## Implementation

### 1. Lock down deterministic process-survival coverage

- Complete `tests/fixtures/copilot-shim-process-survival.mjs` and wire it into the Windows and parent test entry points.
- Keep the existing ephemeral-port/raw-TCP cases for upstream truncation, fast downstream abort, post-keepalive abort, and post-completion close.
- Add a child-process probe that starts the real shim server, deliberately creates an unhandled rejection after startup, and verifies the same process still answers `/_shim/health`. This must fail before the server-runtime guard and pass afterward; no Copilot endpoint or quota is used.
- Add focused tests for a rejecting/throwing reader cancellation and a throwing SQLite metric backend so cleanup paths are proven non-fatal rather than merely covered by ordinary HTTP bodies.

### 2. Fix the canonical shared shim in the parent repository first

Use the clean parent checkout at `C:\Users\hanruzhou\src\dotfiles-release\parent`, after synchronizing it normally and reading its repo contract.

Modify the canonical `dot_config/shell/copilot-throttle-shim.js` and parent fixture/Bats coverage:

- Install one server-scoped `unhandledRejection` compatibility guard from `startServer()`. It must log a sanitized reason and keep the long-running Bun server alive, must not affect CLI subcommands, and must not register duplicate handlers when tests start multiple servers. Reference upstream Bun fixes `80729349` and `3da09633` in the compatibility comment.
- Centralize best-effort stream cancellation so both synchronous throws and rejected Promises are consumed. Reuse it from `pumpStep`, `streamThrough`, `keepaliveThenForward`, `boundedErrorDetail`, and response cleanup.
- Make metric tracker creation and `finalize()` best-effort. SQLite open/write/close failures may be logged but cannot escape `pull()` or `cancel()` callbacks.
- Catch request-body read failures at the fetch-handler boundary so an aborted Codex upload is classified and logged without rejecting the entire Bun handler.
- Preserve current protocol behavior: genuine truncated bodies remain errors; already-committed Anthropic streams still end with `event: error`, Responses streams with `event: response.failed`; same-body/model/trace retries and fail-closed routing remain unchanged.

Run the parent fixture and focused `tests/unit/copilot_proxy.bats`, then create the previously authorized parent-only commit without pushing it.

### 3. Mirror the canonical artifact into Windows

- Copy the committed parent shim byte-for-byte to `dot_config/powershell/copilot-throttle-shim.js`.
- Mirror the process-survival fixture and test invocation in `tests/Copilot.Tests.ps1`.
- Update the `UnixSourceCommit` and SHA-256 contract only after the parent commit exists; assert both files have identical SHA-256 values.

### 4. Add race-safe bounded Windows shim recovery

Modify `dot_config/powershell/modules/Copilot/Copilot.psm1` and `dot_config/powershell/copilot-process-watch.ps1`:

- Serialize `Start-CopilotShim` per port with a local named mutex and re-check port ownership plus `/_shim/health` after acquiring it.
- Set deliberate-stop intent before every intentional shim termination, including stale-owned listener reclamation and startup-timeout cleanup.
- Pass the module manifest, proxy base, shim state path, start timestamp, and recovery-attempt count to the detached watcher.
- After recording `unexpected_exit`, recover only when all are true: component is `shim`, persisted shim state is not `off`, port 4141 is healthy, and port 4142 is still unhealthy.
- Use at most three quick-failure attempts with 1s, 5s, and 30s backoff. A run lasting at least five minutes resets the attempt budget. Recovery invokes an internal `copilot-proxy shim recover` path that preserves persisted on/off state and funnels through the mutex-protected starter.
- Record `restart_scheduled`, `restart_succeeded`, `restart_failed`, `restart_suppressed`, and `restart_exhausted` lifecycle events with attempt/uptime details. Never auto-restart the 4141 proxy and never route clients directly to it.

Add deterministic Pester coverage for successful recovery, deliberate-stop suppression, disabled-shim/proxy-down suppression, crash-loop exhaustion, stable-uptime reset, stale-process stop intent, and concurrent start serialization. Tests use isolated state paths and mocked health/process functions; they must not touch live ports 4141/4142.

### 5. Document the operational contract

- Update `docs/copilot-proxy.md` and `docs/copilot-proxy.zh-TW.md` with the Bun compatibility guard, bounded shim-only recovery, new lifecycle events, and the requirement to explicitly restart an in-memory shim after deployment.
- Update `.chezmoitemplates/dotfiles-windows-skill.md` only if its lifecycle summary would otherwise be inaccurate.
- Add `pitfalls/bun-serve-stream-abort-kills-copilot-shim.md` and its `pitfalls/README.md` entry. Record the observable symptom (`shim: ON but DOWN`, `unexpected_exit`, code 3, stream disconnect), upstream fixes, local containment, and regression tests without prompts, request bodies, tokens, or private transcript text.
- Do not modify or commit `.specstory/**`, `.claude/plans/**`, statistics, transcripts, or other recorder artifacts.

## Verification

1. Run the deterministic process-survival fixture directly with Bun 1.3.14 and through both parent Bats and Windows Pester entry points.
2. Run focused cancellation, metric-failure, mutex, stop-intent, and recovery tests.
3. Run all `tests/Copilot.Tests.ps1`, parent `tests/unit/copilot_proxy.bats`, PSScriptAnalyzer on the module/watcher, and each repository's relevant lint/test commands.
4. Build documentation with the repositories' existing docs commands.
5. Verify parent and Windows shim SHA-256 values are identical and the Windows contract names the exact new parent commit.
6. Validate recovery only on isolated ports/state paths: terminate the isolated shim without intent, require `unexpected_exit -> restart_scheduled -> spawned -> ready`, then deliberately stop it and require no restart.
7. Do not send real inference, use SpecStory, deploy, or restart the production 4141/4142 pair in this implementation pass. Report the tested source state and request separate authorization before any production interruption.

The VS Code Copilot `Responsible AI Service` filtering message is a separate Microsoft service-policy response; this work will not attempt to bypass or weaken it.