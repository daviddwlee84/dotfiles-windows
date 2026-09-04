# Make the full Windows Pester gate portable

**Status**: P2 — reproduced on a real Traditional Chinese Windows host
**Effort**: M
**Related**: `TODO.md` · `tests/ClaudeSettings.Tests.ps1` · `tests/CodexConfig.Tests.ps1` · `tests/Copilot.Tests.ps1` · `justfile` · `.github/workflows/windows.yml`

## Context

A 2026-09-04 minimal-bootstrap dogfood run on Windows 11 exposed several independent assumptions in the full Pester gate. The feature-focused bootstrap/OpenSSH/Pueue/profile set passed on the same host, so these failures should remain a separate test-infrastructure item rather than block or blur those results.

Test host: Windows 11 x64, Traditional Chinese locale, PowerShell 7.6.5, Pester 6.1.0, PSScriptAnalyzer 1.25.0, Bun 1.4.0.

## Investigation

`Invoke-Pester -Path .\tests` produced:

```text
Tests Passed: 572, Failed: 21, Skipped: 3, NotRun: 0
```

Failures by file:

| File | Count | Observed failure class |
|---|---:|---|
| `ClaudeSettings.Tests.ps1` | 1 | The Microsoft Store `bash.exe` app-execution alias exists but cannot be started from this session. |
| `CodexConfig.Tests.ps1` | 18 | The child-process harness decodes bytes through the host code page instead of an explicit encoding. |
| `Copilot.Tests.ps1` | 2 | A fixture assumes an older Bun zstd API; a process-survival fixture also loses its downstream marker. |

Representative errors, preserved verbatim:

```text
Exception calling "Start" with "0" argument(s): "An error occurred trying to start process 'C:\Users\david\AppData\Local\Microsoft\WindowsApps\bash.exe' with working directory 'C:\Users\david'. The file cannot be accessed by the system."
```

```text
Exception calling "GetString" with "1" argument(s): "Unable to translate bytes [A1] at index 250 from specified code page to Unicode."
```

```text
TypeError: Bun.zstdCompressSync is not a function. (In 'Bun.zstdCompressSync((new TextEncoder()).encode(source))', 'Bun.zstdCompressSync' is undefined)
```

```text
error: connection closed before fixture-downstream-fast-abort
```

The same source passed the changed-feature gate on the real host:

```text
Bootstrap + EnableSshd + InitPrompts + Pueue + PowerShell profile:
164 passed, 0 failed, 0 skipped
PSScriptAnalyzer: 0 errors
```

A separate older issue also remains relevant: `Invoke-Pester -CI` enables coverage and has broken Copilot mocks. The current `just test` and Windows workflow should not be called reliable until both that coverage behavior and the newly measured locale/runtime failures are addressed.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| Make test process I/O explicitly UTF-8 | Fixes Codex tests across system locales and mirrors the workflow's template-render encoding setup | Requires auditing each child-process capture rather than only setting the parent console |
| Feature-detect Bun compression APIs in fixtures | Keeps tests valid across supported Bun releases | Must decide the oldest/newest Bun contract and avoid weakening zstd coverage |
| Resolve a real runnable bash, or skip only when no runnable bash exists | Avoids trusting an inaccessible WindowsApps alias | Needs a clear precedence among Git Bash, WSL bash, and app aliases |
| Drop `-CI` or scope coverage away from mocked Copilot modules | Restores the documented non-coverage test semantics | Gives up broad implicit coverage unless a deliberate coverage job is added |

## Current blocker / open questions

- Decide the supported Bun range and replacement for `Bun.zstdCompressSync` in the fixture.
- Identify every Codex child-process boundary that relies on an implicit Windows code page.
- Decide whether Git Bash is required in CI or the Claude status-line case should skip after a real launch probe fails.
- Separate correctness tests from an explicitly configured coverage job; do not rely on `-CI` defaults.

## Decision

2026-09-04 deferred from the PowerShell/OpenSSH dogfood session. Keep the focused changed-feature gate green and repair the full-suite infrastructure as one dedicated P2/M batch.

## References

- [`../docs/powershell-testing.md`](../docs/powershell-testing.md)
- [`../pitfalls/codex-modify-config-empty-key-line-1-col-0.md`](../pitfalls/codex-modify-config-empty-key-line-1-col-0.md)
