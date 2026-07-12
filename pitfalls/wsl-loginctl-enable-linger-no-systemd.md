# WSL dotfiles bootstrap fails on `loginctl enable-linger` — "System has not been booted with systemd"

**Symptoms** (grep this section): the in-WSL cross-platform dotfiles bootstrap
(from `installWslUbuntu` / `just wsl-dotfiles` / `just enable-wsl-ubuntu`) fails in
the ansible **docker** role:
```
docker : Enable user linger so rootless daemon survives logout (Debian/Ubuntu)
loginctl enable-linger <user>
System has not been booted with systemd as init system (PID 1). Can't operate.
Failed to connect to bus: Host is down
```
ansible then reports `failed=1`, `chezmoi: .chezmoiscripts/global/20_ansible_roles.sh: exit status 2`, and the wrapper retries 3× hitting the **same** task each time (the "likely a proxy/GFW reset" warning is misleading here — it's not the network).
**First seen**: 2026-07
**Affects**: WSL2 Ubuntu distro provisioned by `scripts/enable-wsl-ubuntu.ps1`
running the cross-platform dotfiles' `ubuntu_server` profile (docker role); any WSL
distro without `[boot] systemd=true` in `/etc/wsl.conf`.
**Status**: fixed — `enable-wsl-ubuntu.ps1` now writes `[boot] systemd=true`.

## Symptom

`ok=323 changed=136 failed=1` — everything installs *except* the one docker task
above, but because that task isn't marked non-fatal, the whole ansible play exits
2 and the WSL bootstrap loop re-runs into the identical failure until it gives up.

## Root cause

WSL does **not** run systemd by default; you must opt in per-distro with
`/etc/wsl.conf`:
```ini
[boot]
systemd=true
```
`scripts/enable-wsl-ubuntu.ps1` wrote `/etc/wsl.conf` with only `[user] default=`,
so the distro booted with the plain WSL init (PID 1 is `/init`, not systemd). The
cross-platform dotfiles' **docker** role sets up *rootless* Docker and runs
`loginctl enable-linger <user>` so the daemon survives logout — but `loginctl`
talks to the systemd bus, which doesn't exist, so it errors and (lacking a
`failed_when: false`) aborts the play. Requires a modern WSL (store WSL ≥ 0.67.6 /
recent Windows) for systemd support — Windows 11 24H2 has it.

## Workaround

Fix the **already-registered** distro (the repo fix only affects *new*
registrations), then re-run the bootstrap:

```powershell
# 1. enable systemd in the existing distro (append [boot] if absent)
wsl -d Ubuntu-24.04 -u root -- bash -c "grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null || printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf; cat /etc/wsl.conf"
wsl --terminate Ubuntu-24.04                      # re-read wsl.conf on next start

# 2. confirm systemd is PID 1
wsl -d Ubuntu-24.04 -- bash -lc 'ps -p 1 -o comm= ; systemctl is-system-running || true'

# 3. re-run the bootstrap (unconditional retry path; NOT `just enable-wsl-ubuntu`,
#    which short-circuits once ~/.local/share/chezmoi exists)
just wsl-dotfiles
```

## Prevention

`scripts/enable-wsl-ubuntu.ps1` now writes `[user] default=` **and**
`[boot] systemd=true` into `/etc/wsl.conf`, applied by the existing
`wsl --terminate`. New WSL provisions boot systemd, so `loginctl enable-linger`
succeeds. Complementary fix (separate repo): the cross-platform dotfiles' docker
role should mark `loginctl enable-linger` `failed_when: false` / guard it behind a
systemd check, so a no-systemd distro degrades gracefully instead of aborting.

## Related

- `scripts/enable-wsl-ubuntu.ps1` — the `/etc/wsl.conf` write (`[boot] systemd=true`)
- `scripts/bootstrap-wsl-dotfiles.ps1` — `just wsl-dotfiles`, the unconditional retry path
- `backlog/wsl-ubuntu-auto-dotfiles.md` — provisioning design
- Sibling: [`wsl-ubuntu-oobe-and-wsl-l-encoding`](wsl-ubuntu-oobe-and-wsl-l-encoding.md) (same wsl.conf / terminate mechanics)
- Cross-platform dotfiles docker role: `~/.ansible/roles/docker/tasks/main.yml` (the `enable-linger` task)
