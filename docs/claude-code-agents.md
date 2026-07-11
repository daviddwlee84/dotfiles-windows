# Appendix: running multiple Claude Code agents

!!! note "Why this page is here"
    This repo is maintained largely by **concurrent Claude Code agents** (e.g. the
    herdr change was built by a background job in an isolated worktree). This page
    is not Windows-specific — it documents the multi-session workflow and the
    **git-worktree isolation** model so future-me (and future agents) don't have
    to re-derive it. Behaviour below is Claude Code **2.1.x** (mid-2026); press
    `?` in Agent View for the live keybinding list, since these evolve.

## Prompt editing: newline & external editor

Two prompt-input questions that bite on Windows specifically. (These are about the
terminal → Claude Code input layer; the `Shift+Enter` in the **Agent View** table
further down is a *different* binding — it dispatches a new session.)

### Shift+Enter, and the newline that always works

Enter **submits**. To insert a line break *without* submitting:

- **`Ctrl+J`** — or type **`\`** then Enter. Both work in *every* terminal with no
  setup. This is the reliable fallback; reach for it first if in doubt.
- **`Shift+Enter`** — also mapped to newline, but only fires when the terminal
  emits a distinct escape sequence (CSI-u `ESC[13;2u`) so Claude Code can tell it
  apart from a bare Enter.

| Terminal | Shift+Enter → newline |
|---|---|
| **WezTerm** | yes — sent by `dot_config/wezterm/wezterm.lua` |
| **Alacritty** | yes — sent by `AppData/Roaming/alacritty/alacritty.toml.tmpl` |
| **Windows Terminal** | yes — a `sendInput` action added by `run_onchange_after_30_windows_terminal.ps1` |
| **Plain pwsh / conhost** | no CSI-u possible — use `Ctrl+J` |

After a fresh `chezmoi apply`, **restart the terminal** so the new keybinding
loads. If Shift+Enter still submits, fall back to `Ctrl+J` — and prefer WezTerm or
Windows Terminal over the bare console window.

### Ctrl+G — compose the prompt in nvim

**`Ctrl+G`** (or the `Ctrl+X Ctrl+E` chord) opens the current prompt in `$EDITOR`.
This repo already sets `$env:EDITOR = 'nvim'` in
`dot_config/powershell/profile.d/00_env.ps1` (when nvim is on PATH), so `Ctrl+G`
drops you straight into nvim; save and quit to load the edited text back. Works in
pwsh on Windows.

All three are Claude Code defaults; remap them in `~/.claude/keybindings.json`
via the `chat:newline`, `chat:submit`, and `chat:externalEditor` actions.

## The mental model: three ways to parallelize

| Approach | What it is | Isolation | Use when |
|---|---|---|---|
| **Subagent** (Task/Agent tool) | A worker *inside one session* with its own context; returns a summary | Shares the session's working copy | A side task (search, research) would flood the main context |
| **Background session** (`claude --bg`, Agent View) | An *independent* detached Claude Code process | **Auto-isolated in its own git worktree** | Several independent tasks you hand off and check on later |
| **Manual worktree** (`claude --worktree`, `EnterWorktree`) | You run a normal session in an isolated checkout | Its own worktree + branch | You want a foreground session that can't collide with `main` |

The insight that removes the mental overhead: **you rarely manage worktrees by
hand.** Background sessions create, name, and clean them up for you; Agent View is
the one dashboard you look at.

## What actually happens on disk (not a symlink, not `.claude/workspace`)

When a background job is about to edit files, it isolates itself:

```
<repo>/.claude/worktrees/<name>/      ← a real git worktree (a full checkout)
   └── .git                            ← a file, not a dir: "gitdir: <repo>/.git/worktrees/<name>"
```

- It's a **standard `git worktree`**, on a new branch **`worktree-<name>`**, listed
  by `git worktree list`. It is *not* a symlink, and there is **no
  `.claude/workspace/`** directory — if you saw symlinks under `.claude/`, those
  were something else (e.g. shared `skills/` or a repo's own `CLAUDE.md → AGENTS.md`).
- The branch is cut from **`origin/HEAD`** (the remote default branch) by default,
  so it's a clean base — see `worktree.baseRef` below.

Verify any time:

```bash
git worktree list          # every checkout + its branch
cat .claude/worktrees/<name>/.git   # proves it's a worktree pointer, not a copy
```

## Settings that control isolation

In `.claude/settings.json`:

| Setting | Values | Effect |
|---|---|---|
| `worktree.bgIsolation` | *(unset = isolate)* / `"none"` | `"none"` turns **off** auto-isolation for background jobs — they edit the main checkout directly. Use when worktrees are impractical. |
| `worktree.baseRef` | `"fresh"` (default) / `"head"` | `fresh` branches from `origin/HEAD` (clean); `head` branches from your local `HEAD` (carries unpushed/in-progress commits). |

The auto-isolation guard is enforced: in a background job, **file edits in the
shared checkout are rejected until you isolate**. The rejection message even tells
you the opt-out (`worktree.bgIsolation: "none"`). Foreground interactive sessions
are **not** auto-isolated — reach for `claude --worktree <name>` or the
`EnterWorktree` tool when you want isolation there.

## Agent View — the multi-session dashboard

Open it with `claude agents` (or `/background` / `/bg` from inside a session).

**Scope — the answer to "is it machine-wide?":** yes. By default Agent View lists
**every background session for your user on this machine, across all repos and
directories.** To scope it to one project, launch `claude agents --cwd <path>`.
New sessions dispatch into the directory where you opened the view; target another
repo by `@`-mentioning it in the prompt.

Common keys (press `?` for the current full set):

| Key | Action |
|---|---|
| `↑` / `↓` | Move between sessions |
| `Enter` / `→` | Attach to the selected session |
| **`←`** | Detach / back to Agent View (this is the key you noticed) |
| `Space` | Peek — status / pending question, reply inline |
| `Shift+Enter` | Dispatch a new session **and** attach |
| `Ctrl+T` | Pin (keep the process alive while idle) |
| `Ctrl+X` | Stop (again within ~2s to delete) |

## Best practices

1. **One worktree = one unit of work.** Don't stack unrelated changes on a merged
   branch. The herdr change and *this* doc were built in separate worktrees
   (`worktree-herdr`, `worktree-docs-agents`) — each with its own branch and PR.
2. **Ship, don't stall.** A background job's job isn't done at "code written":
   commit → push the branch → open a **draft PR**, and let a human merge. This
   repo's agents never push to `main`, force-push, or merge (see `AGENTS.md`).
3. **Let CI be the gate before merge.** Off-Windows we can only render/parse/lint;
   the `windows-latest` PR check is authoritative. Merge after it's green.
4. **Fight the "which branch am I on?" confusion with tooling, not memory:**
    - keep a **branch segment in your prompt** (starship's `git_branch` already does
      this) so every command shows where you are;
    - trust **Agent View** as the single pane instead of tracking terminals;
    - run `git worktree list` when unsure — it's the ground truth.
5. **Mind the cleanup.** Worktrees with no uncommitted/untracked/unpushed changes
   are auto-removed after `cleanupPeriodDays` (default 30). Merged work → let it be
   reaped, or remove now with `ExitWorktree` (remove) / `git worktree remove <path>`
   and `git push origin --delete <branch>`.
6. **Watch cost.** Each background session burns tokens independently and hits rate
   limits per session — parallelism multiplies usage. Spin up what you'll actually
   watch.

## This repo's agent workflow, concretely

The herdr change is a worked example of the loop:

1. Background job → auto-isolates into `.claude/worktrees/herdr` (`worktree-herdr`).
2. Edits + verification (render/parse, `tomllib`, PSScriptAnalyzer, Pester, `mkdocs --strict`) inside the worktree.
3. `commit` → `git push -u origin worktree-herdr` → `gh pr create --draft`.
4. Human reviews, CI goes green, human merges. Agent does **not** merge to `main`.

## References

- [Worktrees](https://code.claude.com/docs/en/worktrees.md) — `--worktree`, isolation, `baseRef`, cleanup, `.worktreeinclude`
- [Agent View](https://code.claude.com/docs/en/agent-view.md) — dashboard, keybindings, scope, dispatch
- [Common workflows → parallel sessions](https://code.claude.com/docs/en/common-workflows.md) — worktrees vs subagents
- [Choosing an agent approach](https://code.claude.com/docs/en/agents.md) · [Settings](https://code.claude.com/docs/en/settings.md) · [The `.claude` directory](https://code.claude.com/docs/en/claude-directory.md)
