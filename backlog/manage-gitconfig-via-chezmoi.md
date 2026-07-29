# Manage `~/.gitconfig` via a `modify_` overlay

**Status**: P2
**Effort**: M
**Related**: `TODO.md` · parent repo `modify_dot_gitconfig.tmpl` ·
`pitfalls/git-add-fatal-crlf-would-be-replaced-by-lf.md` ·
`pitfalls/scoop-local-changes-overwritten-by-merge.md` ·
`pitfalls/push-protection-blocks-pat-leaked-by-env-dump.md` ·
`dot_config/herdr/modify_config.toml.ps1.tmpl` (the `modify_` precedent)

## Context

2026-07-29, after a GitHub PAT leaked into a SpecStory transcript and push
protection rejected the push. Two things surfaced during cleanup:

1. `~/.gitconfig` is **not managed by chezmoi at all** on this repo — there is
   no `dot_gitconfig*` / `private_dot_gitconfig*` in the source tree. Every
   git setting on this box was applied by hand or by `bootstrap.ps1`, so none
   of it is reproducible on a fresh machine.
2. The CRLF pitfall already ends with *"the fix is machine-local and
   unversioned … a fresh clone on another box will hit the same `fatal:`"* —
   i.e. this gap has already bitten once.

The parent repo solves this with
[`modify_dot_gitconfig.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/modify_dot_gitconfig.tmpl):
a `modify_` script that emits a chezmoi-managed baseline and preserves any
live `[credential "<url>"]` blocks via `awk`.

## Investigation

### Current live state on this machine

```ini
[user]   name = hanruzhou ; email = hanruzhou+odspmdb@microsoft.com
[filter "lfs"]  process/required/clean/smudge
[otel "trace2"] historyOn = true
[credential "azrepos:org/onedrive"]     username = …@microsoft.com
[credential "azrepos:org/o365exchange"] username + azureAuthority = …/72f988bf-…
[credential "azrepos:org/msfast"]       username = …
[credential "azrepos:org/office"]       username + azureAuthority
[credential "azrepos:org/O365Exchange"] username + azureAuthority
[core]   autocrlf = input
[pull]   rebase   = true
```

`pull.rebase = true` is **already set**, so the "default to rebase instead of
merge" question is answered — it just isn't reproducible.

### What the parent's baseline sets

`[user]` · `[http] postBuffer` · `[filter "lfs"]` · `[init] defaultBranch=main`
· `[core] hooksPath=~/.config/git/hooks` · `[pull] rebase=true` ·
`[rebase] autoStash=true` · delta blocks (conditional) ·
`[include] path=~/.gitconfig.local`.

Merge semantics: **the baseline replaces everything except `[credential "…"]`
blocks.** That is the crux of the three landmines below.

### Landmine 1 — it's a bash script

The parent's file is `set -euo pipefail` bash. `AGENTS.md` invariant 5 says
`modify_` interpreter selection is unreliable on Windows — but that's about
*extensionless* scripts. `dot_config/herdr/modify_config.toml.ps1.tmpl` proves
the `.ps1` form works, because `.chezmoi.toml.tmpl` sets
`[interpreters.ps1] = pwsh`. So the port must be rewritten as
`modify_dot_gitconfig.ps1.tmpl`, not copied.

### Landmine 2 — `core.hooksPath` would silently disarm pre-commit

The baseline sets `core.hooksPath = ~/.config/git/hooks`. Git honours
`core.hooksPath` **instead of** `.git/hooks/`, so setting it globally
immediately stops the per-clone hook that `pre-commit install` writes — the
exact hook armed on 2026-07-29 to close the PAT-leak gap.

The parent gets away with it because it *also* deploys a
`~/.config/git/hooks/pre-commit` wrapper that re-dispatches to the repo's
`.pre-commit-config.yaml`. **This repo ships no such wrapper.** Porting
`hooksPath` without the wrapper turns every repo's hooks off, silently, with
no error — the failure mode is "secrets stop being scanned and nobody
notices". Either port the wrapper too, or drop the key.

### Landmine 3 — `core.autocrlf = input` is load-bearing and absent from the baseline

The parent baseline has no `core.autocrlf`, and the merge drops every
non-credential key. Applying it verbatim would **delete `core.autocrlf =
input`**, which exists specifically to stop
[`scoop-local-changes-overwritten-by-merge`](../pitfalls/scoop-local-changes-overwritten-by-merge.md)
(the Git-for-Windows default `autocrlf=true` renormalizes scoop's LF bucket
manifests to CRLF and wedges every `scoop update`). It must be added to the
Windows baseline explicitly.

Same class, lower stakes: `[otel "trace2"]` would also be dropped, since only
`[credential …]` blocks are preserved.

## Options

| Option | Pros | Cons |
|---|---|---|
| **A. Full `modify_dot_gitconfig.ps1.tmpl` port** | Parity with parent; one file owns git config; `[include] ~/.gitconfig.local` gives a corp escape hatch | Must rewrite bash→pwsh, must re-add `autocrlf`, must resolve `hooksPath`; destructive merge risks dropping unknown corp keys on managed machines |
| **B. Minimal `run_onchange` that sets only chosen keys** | Non-destructive (`git config --global <k> <v>` touches nothing else); no awk/merge logic; safe on corp boxes | Config is spread across a script rather than a readable file; drifts from parent's shape; can't *remove* a bad key |
| **C. Leave unmanaged, document in `docs/`** | Zero risk | The gap stays; next fresh box repeats the CRLF pitfall |

Leaning **B** for the first pass — the value here is reproducing ~4 keys
(`autocrlf`, `pull.rebase`, `rebase.autoStash`, `init.defaultBranch`), and B
gets that without any chance of eating the five `azrepos:` credential blocks
that corp auth depends on. Revisit A once a `~/.config/git/hooks/pre-commit`
wrapper exists.

## Open questions

- **Overlap with `bootstrap.ps1` is confirmed, not hypothetical.**
  `bootstrap.ps1:121-124` already does
  `git config --global core.autocrlf input`, guarded by
  "only if unset or `true`". Any new writer must either replace that block or
  agree with it — two writers with different guards is how the key silently
  flips back.
- Should `rebase.autoStash = true` be on given the live SpecStory writer
  constantly dirties the tree? It would have avoided the
  `cannot pull with rebase: You have unstaged changes` hit on 2026-07-29, but
  autostash pop can conflict on `.specstory/statistics.json`.
- Init already prompts for git name/email; reuse those rather than
  re-prompting.
