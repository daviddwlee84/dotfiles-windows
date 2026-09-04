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
- [ ] **[S] Verify the herdr port on a real Windows box** — the full keymap, six pwsh helper scripts, three tv channels and the herdr-plus config were ported from the parent repo on 2026-07-27 and validated as far as macOS allows (overlay merge + idempotency, TOML validity, regex parity with the unix pipelines, channel TSV against a stub `herdr`, the `installHerdr` gate). Fifteen behaviours can only be confirmed with herdr actually running on Windows — chiefly whether the preview build supports `[[keys.command]]` / `type = "popup"` at all, how it spawns the `pwsh -File` command strings, and whether `prefix+ctrl+N` survives ConPTY. Item 12 covers source-pane identity for command helpers; item 15 covers the `prefix+Y` Yazi temporary-pane fallback. → [research](backlog/herdr-windows-port-verification.md)
- [ ] **[S] Verify the Rime/Weasel port on a real Windows box** — CI can't cover IME registration. Check: UAC install registers 中文（繁體，台灣）not 简体; Ctrl+` lists all 5 schemas; bopomofo_tw outputs 臺灣字形; the Hack Nerd Font Mono + Microsoft JhengHei UI fallback chain renders; global_ascii shares 中/英 state while pwsh/VSCode stay ASCII; WeaselDeployer /deploy picks up an edit. → [research](backlog/rime-windows-port-verification.md)
- [ ] **[M] Restore a deterministic full Windows Pester gate across locale, runtime, and coverage variants** — a 2026-09-04 real-host run (zh-TW Windows, pwsh 7.6.5, Pester 6.1.0, Bun 1.4.0) gave 572 passed / 21 failed / 3 skipped: ClaudeSettings 1 (inaccessible WindowsApps `bash.exe` alias), CodexConfig 18 (implicit code-page decoding), Copilot 2 (removed Bun zstd API + process-survival fixture). The changed-feature gate was independently green at 164/164. The older `-CI` coverage/mocking failure also remains; split correctness from deliberate coverage and make child-process encoding/runtime probes explicit. → [research](backlog/windows-pester-gate-portability.md)

## P3

Someday / nice-to-have.

- [ ] **[S] Example deferred item** — low signal-to-effort, but easy.
- [ ] **[S] Windows ssh-agent profile fragment** — parallel to the parent repo's `94_ssh_agent.zsh`. A `dot_config/powershell/profile.d/` fragment that ensures the OpenSSH Authentication Agent service is running (`Set-Service ssh-agent -StartupType Automatic`; `Start-Service`) and optionally detects Bitwarden desktop's `//./pipe/openssh-ssh-agent`. Config skeleton (`dot_ssh/`) already shipped; this only automates the agent side.
- [ ] **[M] Extract the shared Rime config into its own repo** — Today .chezmoitemplates/rime/ is duplicated byte-for-byte in dotfiles and dotfiles-windows, kept in sync by hand + diff. A standalone rime-config repo pulled via .chezmoiexternal in both would remove the drift risk, at the cost of a third repo and a fetch on every apply. → [research](backlog/rime-shared-config.md)
- [ ] **[S] Automate Rime redeploy on macOS and Linux** — Windows redeploys automatically via run_onchange_after_50_rime_deploy.ps1. The unix repo leaves it manual because Squirrel's --reload is unreliable and ibus restart interrupts the session — revisit if a safe non-disruptive trigger appears.

## P?

Needs a spike before committing to a real priority. Tag as `[?/Effort]`.

- [ ] **[?/L] Example evaluation item** — what spike would answer the question? → [research](backlog/example-evaluation.md)
- [ ] **[?/S] Align Windows backup with Unix: run_before + unified dir** — Windows backup is run_once_before_ (first-apply only) with a fixed allowlist; Unix is run_before_ (every apply) using chezmoi status smart-selection. Also unify backup dir naming (~/.dotfiles-backup vs ~/.dotfiles_backup). → [research](backlog/align-windows-backup-with-unix-run-before-unified-dir.md)
- [ ] **[?/L] Windows-on-ARM64 + managed-machine rough edges** — nvim-treesitter arch mismatch (arm64 zig vs amd64-emulated nvim), mason download blocks, per-user font registration, Defender PUA blocks. Decide on an all-arm64 vs all-amd64 Neovim toolchain. → [research](backlog/windows-arm64-managed-machine-rough-edges.md)
- [ ] **[?/M] Auto-resume WSL/Docker setup after the required reboot** — `installWsl` self-elevates and runs `wsl --install`, but the mandatory reboot is manual and nothing resumes afterward (WSL2 backend verification + Docker Desktop first-run happen only once the user reboots + relaunches). Spike: a `RunOnce` registry key / scheduled task to finish post-reboot vs. just documenting the manual reboot. → [research](backlog/auto-resume-wsl-docker-after-reboot.md)
- [ ] **[?/M] Evaluate converging claude-hud installation architecture across the Windows and parent dotfiles repos** — keep Windows plugin-native/enabled and the parent direct-sync/disabled flow for now; revisit when marketplace lifecycle reliability, command/skill exposure controls, cache-schema maintenance, or cross-platform sharing materially changes the trade-off. → [research](backlog/claude-hud-installation-architecture-convergence.md)
- [ ] **[?/M] WSL: systemd-enabled `ubuntu_server` vs. a dedicated no-systemd WSL profile** — the provisioned Ubuntu now boots systemd so the cross-platform `docker` role's rootless `loginctl enable-linger` works (`scripts/enable-wsl-ubuntu.ps1` → `[boot] systemd=true`). Alternatives: a WSL-tuned profile in `daviddwlee84/dotfiles` that skips systemd-only roles (Docker Desktop's WSL integration may already cover `docker`), and/or making the docker role `failed_when: false`. Decide the WSL provisioning shape. → [research](backlog/wsl-systemd-vs-wsl-profile.md)
- [ ] **[?/L] copilot-proxy global apply mode for Claude Code and Codex** — Design an explicit reversible global switch only after proxy supervision exists; require atomic snapshots, ownership markers, drift detection, exact restore, and platform parity. → [research](backlog/copilot-proxy-global-apply-mode-for-claude-code-and-codex.md)
- [ ] **[?/S] Windows as a `fleet` worker** — the head (any box running the Unix dotfiles, including a Windows devbox's own WSL) drives workers over SSH; this repo only has to be a good worker, not host a `fleet` port. `installSshServer` already ships the transport and `installWslUbuntu` the optional POSIX env, so the likely additions here are small: an `authorized_keys` provisioning path for the head's key, plus a worker-setup docs page. Keep `enable-sshd.ps1`'s `DefaultShell = pwsh` — the runner side sends `pwsh -NoProfile -EncodedCommand`, which is pure ASCII and survives either default shell, so the community.general#11307 quoting break never applies. Blocked on a per-box reachability spike: a managed Dev Box may have neither Tailscale (`managedMachine`) nor inbound 22, which flips the whole design to an outbound-dialing worker. → [research](backlog/fleet-worker-role.md)

## Done

- ✅ [2026-09-04] [P?/M] SpecStory Windows-native CLI (track PR #191) — Shipped official SHA-256-verified Windows releases with coding agents; retained standalone toggle and compatibility upgrade command.

- ✅ [2026-08-27] [P2/M] Ship prebuilt Windows binaries for `translate` and install it via scoop — done upstream and here. The `translate` repo got its first `.github/` (CI + an on-tag release workflow) and a `.goreleaser.yaml` that cross-compiles 6 targets from one `ubuntu-latest` runner (pure Go, `CGO_ENABLED=0` — no docker images or Windows runners needed) and pushes the manifest to the new `daviddwlee84/scoop-bucket`. This repo's block is now `scoop bucket add` + `Scoop-Install @('daviddwlee84/translate')` instead of a version-pinned `go install`, so a fresh `workstation` apply no longer spends minutes compiling or drags in a Go toolchain, and `just upgrade-translate` is `scoop update translate`. Includes a migration guard that deletes a stale `~\.local\bin\translate.exe` (it precedes `~\scoop\shims` on PATH and would shadow the shim forever) — but only once the shim exists. → [backlog/translate-windows-distribution.md](backlog/translate-windows-distribution.md)
Recently shipped. When implementing an active item, in the same commit run:

```
scripts/promote-todo.sh --title "<substring>" --summary "<one-line shipped summary>"
```

This moves the entry here using the dated `Done` syntax and re-validates.

- ✅ [2026-04-23] [P1/M] Example shipped item — one-line summary of what landed and where.
- ✅ [2026-07-11] [P3/S] Windows Terminal full CSI-u parity (Ctrl+/, Ctrl+digits) — added `ctrl+/` (0x1f) and `ctrl+0..9` (ESC[48+d;5u) sendInput actions to `run_onchange_after_30_windows_terminal.ps1`, matching wezterm/alacritty; `ctrl+0` overrides WT's default resetFontSize.
- ✅ [2026-07-11] [P?/L] Setup WSL Ubuntu + auto-install dotfiles (unattended, opt-in) — `installWslUbuntu` toggle: `scripts/enable-wsl-ubuntu.ps1` registers `Ubuntu-24.04` with no OOBE (user via `wsl -u root`, passwordless sudo, wsl.conf default), then the default `headless` mode runs a frozen-from-Windows `chezmoi init --apply daviddwlee84` (name/email/profile seeded). `wslUbuntuBootstrap` = headless/interactive/none; `just enable-wsl-ubuntu`. → [research](backlog/wsl-ubuntu-auto-dotfiles.md)
- ✅ [2026-07-29] [P2/M] Manage `~/.gitconfig` (currently unmanaged entirely) — modify_dot_gitconfig.ps1.tmpl overlay: baseline owns user.name/email (from init prompts), core.autocrlf=input, init.defaultBranch, pull.rebase, rebase.autoStash, filter "lfs", http.postBuffer, include ~/.gitconfig.local. Key-level pull-through preserves [credential "azrepos:*"] + [otel]. core.hooksPath deliberately omitted so per-clone pre-commit hooks stay armed. 16 Pester tests incl. a case-sensitivity regression. → [research](backlog/manage-gitconfig-via-chezmoi.md)

<!-- Prune older entries into CHANGELOG.md once prior-year items appear here
     or this section grows past ~20 entries. -->
