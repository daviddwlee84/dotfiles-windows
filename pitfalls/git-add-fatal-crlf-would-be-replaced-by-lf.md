# `git add` dies with "fatal: CRLF would be replaced by LF" on a SpecStory transcript

**Symptoms** (grep this section): `git add -A` / `git add .specstory` aborts with
`fatal: CRLF would be replaced by LF in .specstory/history/<session>.md`.
Nothing is staged — the whole `git add` fails, not just that one file, so a
routine "commit my chat" turns into a hard stop. The file was written by the
SpecStory extension, never hand-edited. Other transcripts in the same folder
commit fine, which makes it look file-specific / random.
Also seen mid-rebase, where it compounds with `git rebase --continue` refusing
to proceed while the extension keeps writing to `.specstory/`.
**First seen**: 2026-07
**Affects**: Git for Windows with `core.autocrlf=input` (global, set by this
repo's `bootstrap.ps1`) **and** `core.safecrlf=true` (the Git for Windows
*system* default at `C:/Program Files/Git/etc/gitconfig`). Any generated file
with mixed line endings; in practice `.specstory/history/*.md`.
**Status**: workaround documented — repo-local `core.safecrlf=false`.

## Symptom

```
Administrator in chezmoi on  main [!?⇕⇡4⇣2] via  v3.9.5 took 14s
❯ git add -A
fatal: CRLF would be replaced by LF in .specstory/history/2026-07-29_09-56-55Z-help-me-solve-the.md
```

The tell that it's a line-ending issue and not corruption — the file is
**mixed**, a handful of CRLF among mostly-LF:

```powershell
$b = [IO.File]::ReadAllBytes('.specstory/history/<session>.md')
$crlf = 0; for ($i = 1; $i -lt $b.Length; $i++) { if ($b[$i] -eq 10 -and $b[$i-1] -eq 13) { $crlf++ } }
"CRLF=$crlf totalLF=$(($b | Where-Object { $_ -eq 10 }).Count)"
# CRLF=12 totalLF=1769
```

## Root cause

Two settings from **different config scopes** combine into a fatal error:

| Scope | Setting | Effect |
|---|---|---|
| global (`~/.gitconfig`, set by `bootstrap.ps1`) | `core.autocrlf=input` | normalize CRLF→LF **on commit** |
| system (`C:/Program Files/Git/etc/gitconfig`) | `core.safecrlf=true` | make that normalization **fatal** if any CR would be lost |

`core.autocrlf=input` is deliberate here — it's the fix for
[`scoop-local-changes-overwritten-by-merge`](scoop-local-changes-overwritten-by-merge.md),
where the Git-for-Windows default `autocrlf=true` renormalized scoop's LF bucket
manifests to CRLF and wedged every `scoop update`. `safecrlf=true` then upgrades
"I normalized this file" from a silent no-op into `fatal:`, and `git add` is
all-or-nothing, so **one** mixed file blocks the entire staging operation.

Why only *some* transcripts trip it — `git ls-files --eol` tells the story:

```
i/lf    w/crlf  attr/    .specstory/history/2026-07-11_00-08-14Z-herdr.md
i/-text w/-text attr/    .specstory/history/2026-07-27_07-04-27Z-administrator-in-chezmoi-on.md
i/lf    w/lf    attr/    .specstory/history/2026-07-27_18-11-39Z-hi.md
```

- `i/-text` — git sniffed the blob as **binary** (transcripts full of terminal
  escape sequences / control bytes) and skips conversion entirely. These never
  trip the check.
- `i/lf w/crlf` — already-committed text transcripts, LF in the index, CRLF in
  the worktree. **18 tracked files are in this state.** They look clean only
  because `git diff` normalizes silently; they'd fail `git add` too the moment
  they changed.

So the failing file isn't special. It's just the first text-detected transcript
with mixed endings that happened to be *new*. The SpecStory extension emits LF
for its own markdown but pastes terminal output verbatim, so whether any given
session ends up mixed, pure-LF, or binary-detected is luck.

## Workaround

Disable the fatal check **for this repo only** (leaves the system-wide safety
net intact for every other repo):

```powershell
git config --local core.safecrlf false
git add -A     # now succeeds
```

Verify the override landed in the right scope:

```powershell
git config --show-origin --get-all core.safecrlf
# file:C:/Program Files/Git/etc/gitconfig  true
# file:.git/config                         false
```

### Rejected alternative: `.gitattributes`

A scratch-repo test (mixed file, `autocrlf=input` + `safecrlf=true`) shows what
actually silences it:

| `.gitattributes` | Result |
|---|---|
| *(none)* | `fatal: CRLF would be replaced by LF` |
| `text eol=lf` | `fatal: CRLF would be replaced by LF` — **does not help** |
| `-text` | staged OK |

So the only attribute that works is `.specstory/** -text`, marking the whole
folder binary. That flips those 18 `i/lf w/crlf` files to "modified" and forces
a one-time churn commit re-injecting CRs into ~3 MB of transcripts — and gives
up diffs on them forever. Not worth it: these are generated agent transcripts
where a lost CR is meaningless, and keeping LF-normalized blobs matches what's
already committed.

### If it bites mid-rebase

`git rebase --continue` also refuses to run while the working tree has unstaged
changes — and the SpecStory extension writes to `.specstory/` *live*, so it
dirties the tree under you. The error is misleading (`You must edit all merge
conflicts` even when `git ls-files -u` is empty). Stash just those paths:

```powershell
git stash push -m "wip specstory" -- .specstory/history/<session>.md .specstory/statistics.json
git rebase --continue
git stash pop   # statistics.json may conflict; keep the newer superset, validate with python -c "import json;json.load(open('.specstory/statistics.json'))"
```

## Prevention

Nothing to bake in — but note the fix is **machine-local and unversioned**
(`.git/config` is not tracked), so a fresh clone of this repo on another box
will hit the same `fatal:` the first time SpecStory writes a mixed transcript.
Re-run the one-liner there.

Do **not** "fix" it by setting `core.autocrlf=true` or `false` globally —
`input` is load-bearing for scoop (see Related).

## Related

- [`scoop-local-changes-overwritten-by-merge`](scoop-local-changes-overwritten-by-merge.md)
  — why `core.autocrlf=input` is set globally in the first place.
- `.agents/skills/agent-history-hygiene/SKILL.md` — the "commit transcripts
  alongside the diff" workflow this blocks; run its
  `assets/redact_secrets.py` scan before committing transcripts.
- [gitattributes docs — `text` / `eol`](https://git-scm.com/docs/gitattributes#_text)
  and [`core.safecrlf`](https://git-scm.com/docs/git-config#Documentation/git-config.txt-coresafecrlf).
