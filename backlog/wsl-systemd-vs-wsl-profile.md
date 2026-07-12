# WSL provisioning: systemd-enabled `ubuntu_server` vs. a dedicated no-systemd WSL profile

**Status**: P? — decision needed; systemd path shipped as the interim default
**Effort**: M (cross-repo: a new profile lives in `daviddwlee84/dotfiles`; this repo only changes the `--promptChoice "Which profile="` it passes)
**Related**: `scripts/enable-wsl-ubuntu.ps1` · `scripts/bootstrap-wsl-dotfiles.ps1` · `pitfalls/wsl-loginctl-enable-linger-no-systemd.md` · [`wsl-ubuntu-auto-dotfiles.md`](wsl-ubuntu-auto-dotfiles.md)

## Context

2026-07. `installWslUbuntu` registers an `Ubuntu-24.04` distro and runs the
cross-platform dotfiles bootstrap inside it with
`--promptChoice "Which profile=ubuntu_server"`. That profile includes the
**docker** role, which sets up *rootless* Docker and runs
`loginctl enable-linger <user>` — a **systemd-only** operation. A stock WSL distro
has no systemd (PID 1 is `/init`), so the task failed and aborted the whole
ansible play (see the pitfall doc). Everything else in the play succeeded
(`ok=323 changed=136 failed=1`); only the systemd-dependent step broke.

Interim fix shipped: `enable-wsl-ubuntu.ps1` now writes `[boot] systemd=true` into
the distro's `/etc/wsl.conf`, so systemd boots and `enable-linger` works. The open
question is whether that's the *right* long-term shape.

## Options

| Option | Cross-repo? | Pros | Cons |
|---|---|---|---|
| **A. systemd + `ubuntu_server`** (shipped) | No (config here) | WSL gets the full server env unchanged; rootless docker actually works; zero profile divergence | Forces systemd (boot overhead; needs recent WSL ≥ 0.67.6); depends on the docker role assuming systemd |
| **B. dedicated `wsl` profile** | Yes (define in `daviddwlee84/dotfiles`) | No forced systemd; leaner, WSL-tuned toolset; can skip rootless-docker entirely (this repo already ships **Docker Desktop + WSL2 integration** on the Windows side, which exposes `docker` inside any distro) | New profile to design + maintain; WSL toolset diverges from server; another `Which profile=` value to wire |
| **C. make the docker role graceful** | Yes (role edit) | One-line safety net (`failed_when: false` / `when: systemd running`); no-systemd distro degrades instead of aborting | Rootless docker still won't autostart without linger; treats the symptom, not the shape |

A and C are complementary (systemd on + role won't hard-fail elsewhere). B is the
alternative architecture.

## Key question for the spike

Does the auto-provisioned WSL companion distro need its **own** `dockerd` at all?
This repo installs **Docker Desktop** with WSL2 integration for the Windows user,
which injects the `docker` CLI + socket into WSL distros. If that covers the WSL
docker need, the rootless-docker role (and thus systemd) is redundant in *this*
distro → argues for **B** (a WSL profile that omits the docker role) or simply
dropping docker from the WSL bootstrap.

## Decision (so far)

Ship **A** (systemd) as the pragmatic default — it makes `ubuntu_server` work in
WSL with no cross-repo change and gives a complete environment. Do **C** upstream
regardless (cheap resilience). Defer **B** until we decide whether WSL should carry
its own docker vs. lean on Docker Desktop's integration.

## References

- Pitfall: [`pitfalls/wsl-loginctl-enable-linger-no-systemd.md`](../pitfalls/wsl-loginctl-enable-linger-no-systemd.md)
- WSL systemd support (`wsl.conf [boot] systemd=true`): https://learn.microsoft.com/windows/wsl/systemd
- Docker Desktop WSL2 integration: https://docs.docker.com/desktop/wsl/
