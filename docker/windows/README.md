# Windows-in-Docker test harness (dockur/windows)

Boots a **real Windows 11 VM inside a container** so you can dry-run
`bootstrap.ps1` end-to-end before touching a physical machine.

> [!IMPORTANT]
> **This does NOT run on the Apple-Silicon Mac this repo was authored on**, and
> not on any host without KVM. It requires an **x86-64 Linux host with nested
> virtualization** (`/dev/kvm` present, `kvm-ok` passes). On such a host:

```bash
cd docker/windows
docker compose up        # first boot downloads + installs Windows (several minutes)
# open http://localhost:8006 for the VNC-style web viewer, or RDP to localhost:3389
```

Inside the Windows VM, this repo is mounted (via the shared `\\host.lan\Data`
folder / the `volumes` map). Open PowerShell and run:

```powershell
# from the mounted copy, using the local source (no GitHub needed):
\\host.lan\Data\bootstrap.ps1 -Source \\host.lan\Data
```

Tear down with `docker compose down -v` (the `-v` also drops the VM disk).

## Why CI is the primary gate

Because Docker-based Windows testing needs specific hardware, the **real gate is
the GitHub Actions `windows-latest` runner** (`.github/workflows/windows.yml`):
PSScriptAnalyzer, `chezmoi init --apply`, template render/parse, and Pester run
on every push. This compose file is a convenience for deeper manual runs on a
capable Linux host, and a stand-in until you validate on the actual device.
