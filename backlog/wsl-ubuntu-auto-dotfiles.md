# Setup WSL Ubuntu + auto-install dotfiles (unattended, opt-in)

**Status**: shipped (2026-07)
**Effort**: L
**Related**: `TODO.md` · `scripts/enable-wsl-ubuntu.ps1` · `.chezmoiscripts/run_onchange_after_46_wsl_ubuntu.ps1.tmpl` · `scripts/enable-wsl.ps1` (the shipped `installWsl` = platform only) · cross-platform repo `daviddwlee84/dotfiles` · `pitfalls/wsl-ubuntu-oobe-and-wsl-l-encoding.md`

## Context

2026-07, follow-up to the shipped `installWsl` toggle. That toggle installs only
the **WSL2 platform** (`wsl --install --no-distribution`) as Docker Desktop's
backend — no Linux distro. This item is the *other* direction: an **opt-in,
default-off** prompt that installs a real **Ubuntu** distro and then bootstraps
the user's cross-platform dotfiles **inside** WSL, fully unattended.

Scope note / tension: this repo explicitly declares WSL-as-a-Linux-shell **out
of scope** (see `docs/rationale.md` — "handled by the cross-platform dotfiles,
not this repo"). This feature is a deliberate *bridge* — it doesn't manage the
Linux config itself, it just triggers `daviddwlee84/dotfiles`' own installer
inside the new distro. Whether that bridge belongs here or in the Linux repo is
an open design question (see below).

## The load-bearing question: can the first-run user/password prompt be skipped?

**Yes — fully automatable.** From the Windows Store, `Ubuntu`'s first launch runs
an OOBE that interactively asks for a UNIX username + password. You **cannot**
pass `--user` to `wsl --install` to skip it. But there are three unattended
paths, best-first:

1. **cloud-init user-data (recommended, Ubuntu 24.04+).** Ubuntu 24.04 is the
   first WSL image with built-in cloud-init. Drop a cloud-config at
   `%USERPROFILE%\.cloud-init\<distro>.user-data` **before first launch**, then
   register the distro. cloud-init creates the user (+ hashed/locked password or
   SSH key), configures sudo, and can run the dotfiles bootstrap in `runcmd`.
   - Caveat: cloud-init will **not** re-provision an already-initialized
     instance — the user-data must be in place before first registration.
   - Caveat: 24.04+ only; older images have no cloud-init → fall back to (2)/(3).
2. **`install --root` / run-as-root + scripted user (any version).** Install
   without OOBE (`wsl --install -d Ubuntu --no-launch`, or the launcher's
   `install --root`), then `wsl -d <distro> -u root -- useradd -m -s /bin/bash ...`,
   set a password (or lock it + passwordless sudo), and pin the default user via
   `/etc/wsl.conf` `[user] default=<name>` (then `wsl --terminate`) or
   `ubuntu.exe config --default-user <name>`.
3. **`wsl --import` a prebuilt rootfs (most deterministic).** Register a tar/VHD
   that already has the user, `/etc/passwd`, `/etc/wsl.conf` baked in. Version-
   agnostic; but we'd have to build/host the rootfs.

### Sketch (Option A — the clean path)

```
# 1. write %USERPROFILE%\.cloud-init\Ubuntu-24.04.user-data  (BEFORE first launch)
#cloud-config
users:
  - name: <user>
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]   # or a hashed passwd via chpasswd
runcmd:
  - [ su, <user>, -c, "sh -c \"$(curl -fsLS get.chezmoi.io)\" -- init --apply daviddwlee84" ]
# 2. wsl.exe --install -d Ubuntu-24.04 --no-launch
# 3. wsl.exe -d Ubuntu-24.04 --exec true   # first boot → cloud-init provisions + runs runcmd
```

## Options considered

| Option | Unattended? | Pros | Cons |
|---|---|---|---|
| A. cloud-init user-data + dotfiles in `runcmd` | Yes | Declarative; one-shot user + dotfiles; official Ubuntu path | 24.04+ only; user-data must precede first launch; password/secret handling in a file |
| B. `--no-launch`/`install --root` + scripted `useradd` + `wsl.conf` | Yes | Works on any image version | Imperative, more moving parts; must sequence terminate/restart; sudo/passwd policy choices |
| C. `wsl --import` prebuilt rootfs | Yes | Deterministic, version-agnostic | Must build + host a rootfs artifact; heaviest |
| D. Plain `wsl --install -d Ubuntu` then let user do OOBE | No | Trivial | Not the ask (interactive username/password) |

## Current blocker / open questions

- **Reboot ordering.** Depends on the WSL2 platform being live, which needs the
  `installWsl` reboot first. A distro install attempted in the same pre-reboot
  apply will fail — so this must gate on "WSL2 already usable" (or run only via
  `just` after the reboot). Ties into the `auto-resume-wsl-docker-after-reboot`
  backlog item.
- **Scope / cross-repo coupling.** Should the Linux-side bootstrap live here or
  in `daviddwlee84/dotfiles`? This repo would only *trigger* the other repo's
  installer; it shouldn't own Linux config.
- **Credentials policy.** Username source (git `name`? fixed? new prompt?) and
  password strategy (locked account + `NOPASSWD` sudo — cleanest for WSL — vs a
  hashed password in a file the user must supply).
- **Ubuntu version pin.** 24.04 for cloud-init, or support older via Option B?
- **Idempotency.** Skip if the distro is already registered (`wsl -l -q`), and
  don't clobber an existing user / re-run chezmoi destructively.
- **Testing.** CI (`windows.yml`) can't actually install a WSL distro; this is
  render/parse-testable only. Real verification needs a Windows box with WSL2.

## Decision (if any)

**Shipped 2026-07** as the default-off `installWslUbuntu` toggle
(`scripts/enable-wsl-ubuntu.ps1` + `run_onchange_after_46_wsl_ubuntu.ps1.tmpl` +
`just enable-wsl-ubuntu`). Choices made:

- **Bootstrap:** headless "frozen-from-Windows" by default — Windows prompts once,
  the answers seed a non-interactive `chezmoi init --apply daviddwlee84
  --promptDefaults --promptString name/email --promptChoice profile=ubuntu_server`
  run headless in WSL. Selectable via `wslUbuntuBootstrap` (`headless` |
  `interactive` | `none`).
- **User creation:** the **imperative** path (Option B) — `wsl --install -d
  Ubuntu-24.04 --no-launch` then `wsl -u root -- useradd …` + `passwd -l` +
  `/etc/sudoers.d` NOPASSWD + `/etc/wsl.conf [user] default=` — chosen over
  cloud-init (Option A). Rationale: everything lives in the one PS script (repo's
  single-source-of-truth convention), no deployed `~/.cloud-init/` artifact to
  gate, and it's version-agnostic (not Ubuntu-24.04+-only). Cloud-init remains a
  valid alternative if declarative provisioning is ever wanted.
- **Account:** `wslUsername` prompt (default = Windows username, sanitized),
  locked password + passwordless sudo, WSL auto-login. No OOBE.
- **No self-elevation:** registering a distro on a ready platform doesn't need
  admin; the script uses detect-and-guide (points to `just enable-wsl-ubuntu`
  from an admin pwsh only if a step returns an elevation error).
- **Reboot ordering:** gated on `wsl --status` (WSL2 platform usable); defers with
  guidance if `installWsl`'s reboot is still pending.
- **Idempotency:** no-op if the distro is registered AND `~/.local/share/chezmoi`
  exists for the user; registered-but-no-dotfiles re-runs just the bootstrap.

See `pitfalls/wsl-ubuntu-oobe-and-wsl-l-encoding.md` for the OOBE-bypass /
`WSL_UTF8` / `wsl.conf`-terminate traps. Future: surface `profile=ubuntu_desktop`
(GUI apps via WSLg) as an option.

## References

- Ubuntu WSL cloud-init HOWTO: https://ubuntu.com/wsl/docs/stable/howto/cloud-init/
- cloud-init WSL guide (won't re-provision initialized instances): https://docs.cloud-init.io/en/latest/howto/launch_wsl.html
- No `--user` on `wsl --install`; alternatives: https://superuser.com/questions/1925924/scripting-automating-installation-of-a-wsl-distro
- Set default user (`/etc/wsl.conf` `[user]`, `ubuntu.exe config`): https://superuser.com/questions/1566022/how-to-set-default-user-for-manually-installed-wsl-distro
- WSL basic commands / `--no-launch`: https://learn.microsoft.com/en-us/windows/wsl/basic-commands
