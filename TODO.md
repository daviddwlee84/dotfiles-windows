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
- [ ] **[?/M] SpecStory Windows-native CLI (track PR #191)** — no npm/native-Windows release; Windows CLI support sits in unmerged getspecstory PR #191 (mergeable=false). Experimental build wired: `just specstory-build`. Revisit when the PR merges/releases → switch to the official install. → [research](backlog/specstory-windows-native-cli.md)
- [ ] **[?/L] Windows-on-ARM64 + managed-machine rough edges** — nvim-treesitter arch mismatch (arm64 zig vs amd64-emulated nvim), mason download blocks, per-user font registration, Defender PUA blocks. Decide on an all-arm64 vs all-amd64 Neovim toolchain. → [research](backlog/windows-arm64-managed-machine-rough-edges.md)

## Done

Recently shipped. When implementing an active item, in the same commit run:

```
scripts/promote-todo.sh --title "<substring>" --summary "<one-line shipped summary>"
```

This moves the entry here using the dated `Done` syntax and re-validates.

- ✅ [2026-04-23] [P1/M] Example shipped item — one-line summary of what landed and where.

<!-- Prune older entries into CHANGELOG.md once prior-year items appear here
     or this section grows past ~20 entries. -->
