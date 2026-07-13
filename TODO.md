# TODO

Long-term backlog for dotfiles-windows. See AGENTS.md
for the maintenance workflow that agents should follow.

> **For agents**: when the user surfaces an idea explicitly **not** being
> implemented this session (signals: "maybe later", "nice to have",
> "工程量太大需要再評估", "先記下來"), add it here with priority + effort tags.
> Do not create new `ROADMAP.md` / `IDEAS.md` / `BACKLOG.md` files —
> `TODO.md` is the single backlog index. Long-form research goes in
> [`backlog/<slug>.md`](backlog/).

<!-- Use the exact section order: P1, P2, P3, P?, Done.
     The bundled scripts/todo-kanban.sh validator only inspects top-level
     `- [ ]` and `- ✅` items inside these sections. Prose paragraphs,
     blockquotes, indented sub-bullets, HTML comments, and `---` rules are
     ignored — feel free to add inline guidance like this without breaking
     machine readability. -->

## P1

Likely next batch — items you'd reach for if you sat down to work today.

- [ ] **[S] Example small item** — short description with file paths if helpful.

## P2

Worth doing, no rush.

- [ ] **[M] Example medium item** — link to research if non-trivial. → [research](backlog/example-medium.md)

## P3

Someday / nice-to-have.

- [ ] **[S] Example deferred item** — low signal-to-effort, but easy.
- [ ] **[S] Windows ssh-agent profile fragment** — parallel to the parent repo's `94_ssh_agent.zsh`. A `dot_config/powershell/profile.d/` fragment that ensures the OpenSSH Authentication Agent service is running (`Set-Service ssh-agent -StartupType Automatic`; `Start-Service`) and optionally detects Bitwarden desktop's `//./pipe/openssh-ssh-agent`. Config skeleton (`dot_ssh/`) already shipped; this only automates the agent side.

## P?

Needs a spike before committing to a real priority. Tag as `[?/Effort]`.

- [ ] **[?/L] Example evaluation item** — what spike would answer the question? → [research](backlog/example-evaluation.md)
- [ ] **[?/S] Align Windows backup with Unix: run_before + unified dir** — Windows backup is run_once_before_ (first-apply only) with a fixed allowlist; Unix is run_before_ (every apply) using chezmoi status smart-selection. Also unify backup dir naming (~/.dotfiles-backup vs ~/.dotfiles_backup). → [research](backlog/align-windows-backup-with-unix-run-before-unified-dir.md)
- [ ] **[?/M] SpecStory Windows-native CLI (track PR #191)** — no npm/native-Windows release; Windows CLI support sits in unmerged getspecstory PR #191 (mergeable=false). Experimental build wired: `installSpecstoryBuild` init toggle (inline build at apply time) + `just specstory-build`. Revisit when the PR merges/releases → switch to the official install. → [research](backlog/specstory-windows-native-cli.md)
- [ ] **[?/L] Windows-on-ARM64 + managed-machine rough edges** — nvim-treesitter arch mismatch (arm64 zig vs amd64-emulated nvim), mason download blocks, per-user font registration, Defender PUA blocks. Decide on an all-arm64 vs all-amd64 Neovim toolchain. → [research](backlog/windows-arm64-managed-machine-rough-edges.md)
- [ ] **[?/M] Auto-resume WSL/Docker setup after the required reboot** — `installWsl` self-elevates and runs `wsl --install`, but the mandatory reboot is manual and nothing resumes afterward (WSL2 backend verification + Docker Desktop first-run happen only once the user reboots + relaunches). Spike: a `RunOnce` registry key / scheduled task to finish post-reboot vs. just documenting the manual reboot. → [research](backlog/auto-resume-wsl-docker-after-reboot.md)
- [ ] **[?/M] WSL: systemd-enabled `ubuntu_server` vs. a dedicated no-systemd WSL profile** — the provisioned Ubuntu now boots systemd so the cross-platform `docker` role's rootless `loginctl enable-linger` works (`scripts/enable-wsl-ubuntu.ps1` → `[boot] systemd=true`). Alternatives: a WSL-tuned profile in `daviddwlee84/dotfiles` that skips systemd-only roles (Docker Desktop's WSL integration may already cover `docker`), and/or making the docker role `failed_when: false`. Decide the WSL provisioning shape. → [research](backlog/wsl-systemd-vs-wsl-profile.md)

## Done

Recently shipped. When implementing an active item, in the same commit run:

```
scripts/promote-todo.sh --title "<substring>" --summary "<one-line shipped summary>"
```

This moves the entry here using the dated `Done` syntax and re-validates.

- ✅ [2026-04-23] [P1/M] Example shipped item — one-line summary of what landed and where.
- ✅ [2026-07-11] [P3/S] Windows Terminal full CSI-u parity (Ctrl+/, Ctrl+digits) — added `ctrl+/` (0x1f) and `ctrl+0..9` (ESC[48+d;5u) sendInput actions to `run_onchange_after_30_windows_terminal.ps1`, matching wezterm/alacritty; `ctrl+0` overrides WT's default resetFontSize.
- ✅ [2026-07-11] [P?/L] Setup WSL Ubuntu + auto-install dotfiles (unattended, opt-in) — `installWslUbuntu` toggle: `scripts/enable-wsl-ubuntu.ps1` registers `Ubuntu-24.04` with no OOBE (user via `wsl -u root`, passwordless sudo, wsl.conf default), then the default `headless` mode runs a frozen-from-Windows `chezmoi init --apply daviddwlee84` (name/email/profile seeded). `wslUbuntuBootstrap` = headless/interactive/none; `just enable-wsl-ubuntu`. → [research](backlog/wsl-ubuntu-auto-dotfiles.md)

<!-- Prune older entries into CHANGELOG.md once prior-year items appear here
     or this section grows past ~20 entries. -->
