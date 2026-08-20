# Windows as a `fleet` worker — what this repo has to provide

**Status**: P? — design captured 2026-08-20; nothing implemented on either side. Blocked on a per-box reachability spike, not on effort.
**Effort**: S here (this repo mostly already ships the pieces; the work is a decision + docs). The runner change is L and lives in `daviddwlee84/dotfiles`.
**Related**: `scripts/enable-sshd.ps1` · `scripts/enable-wsl-ubuntu.ps1` · `scripts/bootstrap-wsl-dotfiles.ps1` · `.chezmoiscripts/run_onchange_after_40_openssh_server.ps1.tmpl` · `dot_ssh/private_config.d/create_private_00-defaults` · unix twin `daviddwlee84/dotfiles` → `backlog/fleet-windows-workers.md` · cross-repo note `dotfiles-all/docs/multi-machine-compute-plane.md`

## Context

2026-08. The user wants one machine to host every coding-agent session (the
*head*) and to push compute onto other Windows devboxes (*workers*), with the
laptop out of the loop because it is not always powered on.

`fleet` — the multi-host orchestrator (inventory, asyncssh fan-out, cross-host
pueue/tmux rollups) — lives entirely in the Unix repo and is called out as a
known gap here already (`backlog/herdr-windows-port-verification.md`: *"`fleet`
is a mac/linux-only tool in the parent repo; nothing to point at here"*).

**This repo does not need a `fleet` port.** The control plane stays on the head;
Windows only has to be a good *worker*. That asymmetry is deliberate — agent
credentials, session state and orchestration all stay on one machine.

The head itself may well be a Windows devbox: `installWslUbuntu` +
`wslUbuntuBootstrap` already provision a WSL Ubuntu with the cross-platform
dotfiles inside it, and that is a complete `fleet` host today. Nothing new is
needed for that case either.

## What a worker has to provide

| Requirement | Status here |
|---|---|
| Inbound SSH | `installSshServer` → `scripts/enable-sshd.ps1` (capability + service + firewall rule on 22) — **shipped** |
| Key-based auth from the head | `dot_ssh/` seeds the client side only; `authorized_keys` on the worker is manual today |
| A shell the runner can target | pwsh 7 is present; see the `DefaultShell` note below |
| Optional POSIX env | `installWslUbuntu` → Ubuntu-24.04 + cross-platform dotfiles — **shipped** |
| Queue | not recommended natively — see below |

## The `DefaultShell` question — and why it stops mattering

`scripts/enable-sshd.ps1:64` deliberately sets:

```powershell
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwsh
```

so an interactive `ssh devbox` lands in PowerShell 7 rather than cmd.exe. That is
good for humans and actively hostile to naive remote execution:
ansible-collections/community.general#11307 documents the WSL connection plugin
breaking on exactly this setting — pwsh mangles the backticks in a POSIX command
before bash sees it (`/bin/bash: -c: line 1: syntax error near unexpected token
')'`), and the reported fix is to set the default shell back to cmd.

**Do not change it.** The runner side solves this instead, by sending

```
pwsh -NoProfile -EncodedCommand <base64 UTF-16LE>
```

which is pure ASCII with no quotes, backticks or `$`, and therefore arrives
intact through either cmd.exe or pwsh. The consequence for this repo is that
`enable-sshd.ps1` needs **no change**, and a devbox someone else configured works
the same as one of ours. Rationale in full: the unix twin doc.

## WSL as the execution environment — the fragile option

A worker can execute either natively (pwsh) or inside its WSL distro. The WSL hop
is the *less* reliable of the two, contrary to intuition:

- microsoft/WSL#8072 — `Access is denied` opening `wsl.exe` from an SSH session
- microsoft/WSL#9373 — WSL does not start when connected over SSH
- microsoft/WSL#8889 — Windows executables give no output from an SSH session

If a WSL worker is wanted anyway, the payload shape is
`wsl.exe -d <distro> -u <user> -- bash -lc '<script>'` *inside* the encoded pwsh
command, so quoting never crosses the sshd boundary. `scripts/enable-wsl-ubuntu.ps1`
already carries the two encoding fixes that path needs
(`$OutputEncoding = [System.Text.UTF8Encoding]::new($false)` and
`$env:WSL_UTF8 = '1'`), plus the "pipe the bash script over stdin" idiom.

Upside of the WSL path: it is the only one where pueue behaves like it does on
the rest of the fleet.

## Queue: not on native Windows

pueue's README says Windows is *"fully supported and working fine for quite a
while"*, but Nukesor/pueue#344 records that `pueued` does not handle Windows
service events, so registering it as a service times out — it needs a
logon-triggered Scheduled Task. Tasks also execute **through PowerShell** on
Windows, so a queued string does not mean the same thing it means on a POSIX
host. Keep queues on POSIX/WSL; native Windows gets synchronous execution only.

## The blocker: `managedMachine` + Dev Box means possibly no route at all

This repo's own prompt text defines the constraint: *"Managed or corporate
machine (skip org-policy-blocked apps like **Tailscale** and Grammarly)"*. On a
managed box there is no overlay network. A Microsoft Dev Box additionally has no
public IP, and its supported connection paths are the Dev Box service (RDP /
browser / VS Code headless) — peer-to-peer inbound TCP/22 is not guaranteed.

Both closed at once means **no inbound transport exists** and no shell
engineering helps. The fallback is an outbound-dialing worker: `ssh -R` /
autossh reverse tunnel, a GitHub self-hosted runner (outbound-only, and this repo
already reaches Windows that way in CI), or a poll-based work pool. Recorded as a
tier; not built.

Lifecycle is easy once reachability is solved: `az devcenter dev dev-box
start|stop|list` (`devcenter` CLI extension, Azure CLI >= 2.75). `installIacTools`
already installs the Azure CLI.

## Key question for the spike

From the intended head, per box:

```
ssh <box> 'pwsh -NoProfile -Command "$PSVersionTable.PSVersion"'
```

If that succeeds, tier A (inbound SSH → native pwsh) is available and the rest is
runner-side work in the Unix repo. If it cannot succeed on the corporate boxes,
the whole design changes shape to an outbound-dialing worker and should be
re-scoped before any code is written.

## Decision (so far)

Nothing to implement here yet. When the spike passes, the likely additions to
this repo are small and additive: an `authorized_keys` provisioning path for the
head's key, and a docs page describing worker setup. Deliberately **not** doing:
porting `fleet`, changing `DefaultShell`, or running a queue natively.
