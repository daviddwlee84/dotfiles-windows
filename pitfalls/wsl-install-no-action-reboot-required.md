# Docker Desktop says "WSL not installed"; `wsl --install` does nothing / needs elevation

**Symptoms** (grep this section):
- Docker Desktop won't start: **"WSL 2 is not installed"** / **"Docker Desktop requires a newer WSL kernel version"** / "WSL not installed".
- `wsl --install` prints **`No action was taken as a system reboot is required.`** and exits without installing.
- `wsl --install` fails with **`The requested operation requires elevation.`** (or `Error code: Wsl/...` / `0x80070522`) when run from a non-admin shell.
- After `chezmoi apply` on a fresh box, Docker Desktop is installed but the WSL2 backend is missing and nothing prompted to fix it.

**First seen**: 2026-07
**Affects**: Windows 10 21H2+ / Windows 11; Docker Desktop (WSL2 backend); `wsl.exe` (inbox + Store WSL)
**Status**: workaround documented (automated via the `installWsl` toggle)

## Symptom

Docker Desktop installs via winget (`Docker.DockerDesktop`) but its WSL2 backend
is a *separate* prerequisite that winget does not provision. On a machine without
WSL, Docker Desktop launches into an error and you're told to run `wsl --install`
by hand. Doing so from a normal shell gives:

```
The requested operation requires elevation.
```

and even from an elevated shell, the first run typically ends with:

```
Installing: Virtual Machine Platform
Installing: Windows Subsystem for Linux
...
No action was taken as a system reboot is required. Please restart the machine and try the operation again.
```

## Root cause

`wsl --install` enables kernel-mode / hypervisor Windows features
(`Microsoft-Windows-Subsystem-Linux`, `VirtualMachinePlatform`) and installs the
WSL kernel. Both operations **require admin** and the feature enablement
**requires a reboot** before WSL2 (and therefore Docker's WSL2 backend) works.
This is a longstanding WSL limitation — features that install drivers/services
can't come online without a restart:

- Elevation required: <https://learn.microsoft.com/en-us/windows/wsl/install>
- Reboot required (won't proceed until restart): <https://github.com/microsoft/WSL/issues/6474>
- "install without requiring a restart" (WONTFIX, by design): <https://github.com/microsoft/WSL/issues/4743>

Because a `chezmoi apply` runs **unelevated** by design and must never abort
(hard invariant #2), it can't just call `wsl --install` inline.

## Workaround

The `installWsl` toggle (on for `workstation`) handles this via
`scripts/enable-wsl.ps1`:

```powershell
# during `chezmoi apply` (run_onchange_after_45_wsl.ps1.tmpl) OR standalone:
just enable-wsl
# -> if not elevated, self-relaunches elevated (one UAC prompt), then runs:
wsl.exe --install --no-distribution
# -> then: REBOOT, then start Docker Desktop.
```

- `--no-distribution` installs only the WSL2 platform (Docker creates its own
  `docker-desktop` distro; no Ubuntu needed). On older builds that reject the
  flag, the script falls back to a plain `wsl --install`.
- If the UAC prompt was **declined**, the run_onchange won't re-fire (it's
  content-hash gated), so re-run `just enable-wsl` to retry.
- Already-installed machines are a silent no-op (presence is judged by
  `wsl --status` / `wsl --version` exit code, so no needless UAC prompt).

Manual equivalent, if you're not using the toggle: open an **elevated** pwsh and
run `wsl --install --no-distribution`, then **reboot**.

## Prevention

- Keep `installWsl` on for workstations so a fresh setup provisions the backend.
- Expect **exactly one reboot** after the first WSL install — it's not a failure;
  `wsl --install` finishing with "a system reboot is required" is the normal path.
- Don't run `wsl --install` from a non-admin shell and conclude "it's broken" —
  it needs elevation; that's what the self-elevating script is for.

## Related

- `scripts/enable-wsl.ps1` · `.chezmoiscripts/run_onchange_after_45_wsl.ps1.tmpl`
- [tools.md → Docker Desktop's WSL2 backend](../docs/tools.md)
- Modeled on the OpenSSH admin pattern: `scripts/enable-sshd.ps1`
- `TODO.md`: auto-resume WSL/Docker setup after the required reboot (deliberately not automated)
