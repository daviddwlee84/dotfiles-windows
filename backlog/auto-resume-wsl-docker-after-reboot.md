# Auto-resume WSL/Docker setup after the required reboot

**Status**: P?
**Effort**: M
**Related**: `TODO.md` · `scripts/enable-wsl.ps1` · `.chezmoiscripts/run_onchange_after_45_wsl.ps1.tmpl` · `pitfalls/wsl-install-no-action-reboot-required.md`

## Context

2026-07, surfaced while adding the `installWsl` toggle so Docker Desktop's WSL2
backend gets provisioned automatically. The install path is automated end-to-end
*up to* the reboot: a non-elevated `chezmoi apply` self-elevates (one UAC
prompt), runs `wsl --install --no-distribution`, and prints a "restart required"
notice. What's **not** automated is everything after the reboot — the user must
manually reboot, then launch Docker Desktop for its first-run WSL2 integration.

This was a deliberate scope cut, not an oversight: auto-rebooting from inside an
apply is destructive, and resuming across a reboot needs a persistence mechanism
the repo doesn't have today.

## Investigation

The gap, concretely:

1. `wsl --install` enables `VirtualMachinePlatform` + `Microsoft-Windows-Subsystem-Linux`
   and installs the kernel — none of which is live until a reboot (see
   `pitfalls/wsl-install-no-action-reboot-required.md` for the upstream
   WONTFIX). So the backend simply isn't usable in the same session.
2. `run_onchange` is content-hash gated, so it won't re-fire on the next apply
   after reboot unless the script content changed. There's no "run once more
   after reboot" hook.
3. Docker Desktop's first run (accept terms, enable WSL2 integration) is an
   interactive GUI step that isn't scriptable-clean anyway (see docker/roadmap#307).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Document the manual reboot (current) | Zero new machinery; honest about the one manual step | User has to remember to reboot + launch Docker |
| B. `RunOnce` registry key written by the elevated install → runs a verify script on next logon | Native Windows resume; fires exactly once post-reboot | Needs admin to write HKLM RunOnce (we're already elevated at that point); adds a logon-time script surface; must no-op if WSL already healthy |
| C. Scheduled task (`Register-ScheduledTask`) that self-deletes after verifying `wsl --status` | Survives reboot; can wait for network; self-cleaning | Heavier; scheduled-task lifecycle + cleanup is fiddly; still can't drive Docker's GUI first-run |
| D. Prompt-and-`Restart-Computer` (opt-in) at the end of the elevated install | Fully hands-off if the user consents | Rebooting mid-`chezmoi apply` is hostile; risks interrupting other apply steps / unsaved work |

## Current blocker / open questions

- Is post-reboot auto-resume actually wanted, or is a clear "reboot, then start
  Docker Desktop" message (Option A) good enough? Need user preference.
- If B/C: what does "done" mean to verify against — `wsl --status` exit 0 +
  default version 2? Docker Desktop service running? The latter depends on the
  user completing Docker's GUI first-run, which we can't automate.
- Anything we schedule must be idempotent and self-removing so it doesn't
  linger on machines where WSL is already healthy.

## Decision (if any)

None yet — shipped Option A (manual reboot, documented). Logged here so the
resume-automation trade-offs don't need re-deriving if we revisit.

## References

- `scripts/enable-wsl.ps1` (the self-elevating installer)
- `pitfalls/wsl-install-no-action-reboot-required.md` (reboot/elevation upstream refs)
- WSL reboot-required (WONTFIX): https://github.com/microsoft/WSL/issues/4743
- Docker unattended first-run limits: https://github.com/docker/roadmap/issues/307
