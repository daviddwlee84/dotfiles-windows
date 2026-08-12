# copilot-proxy global apply mode for Claude Code and Codex

**Status**: deferred (2026-08-12)
**Effort**: L
**Related**: `TODO.md` · `dot_config/powershell/modules/Copilot/Copilot.psm1`

## Context

A user-wide mode would make ordinary `claude` and `codex` convenient, but also
couple both to a local daemon and mutate runtime-owned settings. Today the
one-shot launchers are intentionally zero-persistence.

## Investigation

Proposed command: `copilot-global on|off|status claude|codex|all`. `on` must
require a healthy login-start supervisor, snapshot exact files/keys with hashes,
write validated temp files atomically, and mark ownership. Claude receives the
full role profile; Codex preserves all unrelated TOML. `off` restores exactly
but stops on manual drift. Operations must be idempotent and crash-safe.

Test fresh/existing config, repeated cycles, interruption between stages,
malformed input, manual drift, state migration, and supervised-proxy failure.
Keep the Windows implementation native PowerShell.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| Keep one-shot/project launchers | Safe and shipped | Repeated opt-in |
| Chezmoi-managed permanent provider | Declarative | Fights runtime state; dead-daemon risk |
| Stateful global switch | Good UX with exact restore | Requires supervisor, transactions and ownership semantics |

## Current blocker / open questions

Windows has no login-start, auto-restarting proxy supervisor yet. A global
config without that prerequisite can strand both CLIs after reboot.

## Decision (if any)

2026-08-12 deferred. Keep one-shot launchers as the supported path; implement
only after supervisor/service work lands on both platforms.

## References

- `docs/copilot-proxy.md`
- Parent repo: `backlog/copilot-proxy-global-apply-mode.md`
