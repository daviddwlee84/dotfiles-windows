# Windows as a `fleet` worker — what this repo has to provide

**Status**: P? — local laptop passed on 2026-09-04; managed/corporate boxes still need per-box reachability spikes.
**Effort**: S here. The runner-side work is L and lives in `daviddwlee84/dotfiles`.
**Related**: `scripts/enable-sshd.ps1` · `scripts/enable-wsl-ubuntu.ps1` · `.chezmoiscripts/run_onchange_after_40_openssh_server.ps1.tmpl` · `dot_ssh/private_config.d/create_private_00-defaults`

**The design and its rationale live outside this repo — do not restate them here:**

- `dotfiles-all/docs/multi-machine-compute-plane.md` — the cross-platform decision: head/worker split, transport ladder, what does not cross over.
- `daviddwlee84/dotfiles` → `backlog/fleet-windows-workers.md` — the runner design, the wire format, and the evidence behind it.

This doc is only the **Windows-side checklist**: what a box here must provide,
and what is still missing.

## Context

2026-08. The user wants one machine to host every coding-agent session (the
*head*) and to push compute onto other Windows devboxes (*workers*).

`fleet` — the multi-host orchestrator — lives entirely in the Unix repo and is
already noted as a gap here (`backlog/herdr-windows-port-verification.md`:
*"`fleet` is a mac/linux-only tool in the parent repo; nothing to point at
here"*). **That gap is the design, not a defect.** The control plane stays on
the head so agent credentials and session state live on exactly one machine;
Windows only has to execute.

Note the head may itself be a Windows devbox: `installWslUbuntu` +
`wslUbuntuBootstrap` provision a WSL Ubuntu carrying the cross-platform
dotfiles, which is a complete `fleet` host. Nothing new is needed for that case.

## What a worker must provide

| Requirement | Status here |
|---|---|
| Inbound SSH | `installSshServer` → `scripts/enable-sshd.ps1` (capability + service + firewall rule on 22) — **shipped** |
| Key-based auth from the head | `dot_ssh/` seeds the **client** side only; `authorized_keys` on the worker is manual — **the one real gap** |
| A shell the runner can target | pwsh 7 — **shipped** |
| Optional POSIX env | `installWslUbuntu` → Ubuntu-24.04 + cross-platform dotfiles — **shipped** |
| Queue | not recommended natively; queues stay on POSIX/WSL hosts |

## Decisions that bind files in this repo

**Keep `DefaultShell = pwsh`.** `scripts/enable-sshd.ps1:64` sets it so an
interactive `ssh devbox` lands in PowerShell 7. That setting breaks naive remote
execution of POSIX command strings, but the runner side sends a base64
`-EncodedCommand` payload that survives either default shell, so this repo needs
no change. Do not "fix" `enable-sshd.ps1` for remote-execution reasons.

**`scripts/enable-wsl-ubuntu.ps1` already carries the encoding fixes** any WSL
execution path needs (`$OutputEncoding = [System.Text.UTF8Encoding]::new($false)`,
`$env:WSL_UTF8 = '1'`, and the feed-bash-over-stdin idiom). Reuse them rather
than re-deriving.

**Native execution is preferred over the WSL hop** on a worker. Reasons and
issue references are in the Unix-side doc.

## Key question for the spike

From the intended head, per box:

```
ssh <box> 'pwsh -NoProfile -Command "$PSVersionTable.PSVersion"'
```

If it succeeds, everything remaining is runner-side work in the Unix repo. If it
cannot succeed on the corporate boxes, the design flips to an outbound-dialing
worker and must be re-scoped before any code is written.

The repo-local constraint that makes this uncertain: `managedMachine` is defined
here as *"Managed or corporate machine (skip org-policy-blocked apps like
**Tailscale** and Grammarly)"* — so a managed box has no overlay network, and a
Dev Box has no public IP either.

## 2026-09-04 local laptop spike

A local Windows laptop passed the transport spike from a macOS head after a real
minimal bootstrap:

- Microsoft OpenSSH **MSI 9.5** was already running from
  `C:\Program Files\OpenSSH\sshd.exe`; the Windows capability reported
  `NotPresent`. The helper preserved the usable, Authenticode-valid MSI instead
  of installing a competing capability.
- The active Wi-Fi profile was Private. The existing inbound TCP/22 rule was
  Private and executable-scoped to that sshd, but `RemoteAddress=Any`; setup
  preserved it and reported the broader-than-`LocalSubnet` warning.
- `administrators_authorized_keys` already existed with only SYSTEM and
  Administrators ACL entries, so BatchMode key authentication worked. This was
  pre-existing per-box state, not automatic provisioning by the repo.
- Before setup, command mode launched `cmd.exe`. After bootstrap installed
  PowerShell **7.6.5** and the helper set `DefaultShell`, new connections launched
  the real Scoop-current `pwsh.exe`; `DefaultShellCommandOption` remained absent.
- Raw PowerShell command mode, separate Traditional Chinese UTF-8 stdout/stderr,
  remote `exit 23`, explicit UTF-16LE `-EncodedCommand`, and a no-command
  interactive pseudo-TTY login all passed from the head.
- The registry setting is machine-wide but its current executable is user-scoped
  under `%USERPROFILE%\scoop`. The enabling account passed end to end;
  a multi-account worker should install a machine-wide PowerShell 7 or separately
  prove every SSH account can execute the selected path.

This proves the existing inbound design on one trusted local-network laptop. It
does **not** answer whether a managed Dev Box permits inbound 22 or has an overlay
route; run the same spike per managed box before changing the transport design.

## Decision (so far)

Keep the runner-side encoded-command design and native pwsh execution. The
remaining worker-specific addition is still small and additive: an
`authorized_keys` provisioning path for the head's key, plus a worker-setup docs
page. Deliberately **not** doing: porting `fleet`, changing queue placement, or
assuming this local-network result applies to managed boxes.
