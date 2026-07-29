# `git push` rejected by GitHub push protection — a PAT leaked via `env` in an agent transcript

**Symptoms** (grep this section): `git push` fails with
`remote: error: GH013: Repository rule violations found for refs/heads/main`,
`GITHUB PUSH PROTECTION`, `Push cannot contain secrets`, and a
`—— GitHub Personal Access Token ——` block naming
`.specstory/history/<session>.md:<line>`. The push writes objects
successfully (`Writing objects: 100%`, `remote: Resolving deltas: 100%`) and
*then* the ref update is rejected, so it looks like the push "almost worked".
Nothing in the diff was hand-written — the offending line is inside a
generated agent transcript, which makes it look like SpecStory invented a
secret out of nowhere.
**First seen**: 2026-07-29
**Affects**: any repo where a coding agent runs an environment dump and a
transcript recorder (SpecStory / Cursor / Claude Code) commits the output.
Requires `GITHUB_PERSONAL_ACCESS_TOKEN` (or similar) to be exported in the
shell environment.
**Status**: workaround documented; local hook stack now installed
(`pre-commit install` + `scoop install gitleaks`).

## Symptom

```
remote: - GITHUB PUSH PROTECTION
remote:   —————————————————————————————————————————
remote:     Resolve the following violations before pushing again
remote:
remote:     - Push cannot contain secrets
remote:
remote:       —— GitHub Personal Access Token ——————————————————————
remote:        locations:
remote:          - commit: d912fb13fa95bd15ad37e3770f8552b51e00f036
remote:            path: .specstory/history/2026-07-29_09-56-55Z-help-me-solve-the.md:1727
```

## Root cause

An earlier agent turn was debugging a stuck rebase and ran a routine
environment dump:

```bash
env | grep -i git
```

`grep -i git` matches far more than `GIT_*` — it also matches
**`GITHUB_PERSONAL_ACCESS_TOKEN`**, which is exported in this shell. The
token's full value was printed to stdout, SpecStory captured the tool output
verbatim into the session transcript, and the transcript was committed
alongside the feature diff (which is the *correct* default — see
`agent-history-hygiene`). The resulting line was:

```
GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_<82 more chars>
```

Two things make this easy to walk into:

1. **The dump command looks harmless.** `env | grep -i git` reads as "show me
   git-related env vars", not "print my credentials". The same trap applies to
   `printenv`, `set`, `Get-ChildItem Env:`, and `docker inspect`.
2. **The secret lives in an environment variable**, so it is not a one-off
   mistake — *every* future transcript that dumps the environment re-leaks it.

### Why the local hook stack didn't catch it

This repo already ships `.gitleaks.toml` and `.pre-commit-config.yaml`, and
both are correct:

- `[extend] useDefault = true` keeps gitleaks' built-in
  `github-fine-grained-pat` rule active.
- The `.specstory/history/` allowlist uses `condition = "AND"`, so it only
  tolerates lines that *also* match an example/demo marker. A real PAT still
  fires.

Verified after the fact against the offending commit:

```bash
gitleaks git -c .gitleaks.toml --log-opts="d912fb1~1..d912fb1" --redact
# WRN leaks found: 1      (exit 1)
```

The config was never the problem. **Nothing was executing it:**

```bash
ls .git/hooks/pre-commit    # No such file — `pre-commit install` never run in this clone
git config core.hooksPath   # (unset)
command -v gitleaks         # not on PATH
```

`pre-commit install` is **per-clone** — cloning a repo that contains
`.pre-commit-config.yaml` does *not* activate it. So GitHub's server-side
push protection was the only gate between the token and a public repo.

## Workaround

The leaked commit was HEAD and unpushed (`git branch -r --contains <sha>`
empty), so this is the cheap `amend` case from the `agent-history-hygiene`
remediation runbook. Two constraints make the naive fix wrong:

1. **Never print the secret while recovering.** The SpecStory writer is live;
   every `grep` / `sed -n '<line>p'` / `cat` of that line appends it to the
   *current* transcript, so the redact-then-restage loop never converges.
   Redact blind, verify only after the sentinel is in place.
2. **Redact in binary mode.** These transcripts are the mixed-EOL files from
   [`git-add-fatal-crlf-would-be-replaced-by-lf`](git-add-fatal-crlf-would-be-replaced-by-lf.md).
   Python text-mode I/O silently normalizes newlines and rewrites the whole
   file.

One atomic pipeline, so the index is frozen before the next transcript write:

```bash
python -c "
import re, pathlib
p = pathlib.Path('.specstory/history/<session>.md')
b = p.read_bytes()                       # bytes, NOT text — preserves mixed EOL
pat = re.compile(rb'\bgithub_pat_[A-Za-z0-9_]{60,}')
n = len(pat.findall(b))
assert n == 1, 'expected 1 hit, got %d' % n
p.write_bytes(pat.sub(b'[REDACTED_GITHUB_PAT]', b))
" && git add .specstory/history/<session>.md && git commit --amend --no-edit
```

The sentinel passes because it simply isn't secret-shaped — **no allowlist is
involved**. Worth stating explicitly, because it is tempting to assume one of
the `.gitleaks.toml` allowlists covers it; neither does:

| Pattern | Matches `[REDACTED_GITHUB_PAT]`? |
|---|---|
| global `\b[A-Za-z0-9_-]+_REDACTED(?:_[A-Z_]+)?\b` | no — needs a prefix *before* `_REDACTED` |
| `.specstory/` allowlist `\bREDACTED\b` | no — `_` is a word char, so `\b` never lands |
| rule `github-fine-grained-pat` (`github_pat_\w{82}`) | no — nothing left to match |

So don't reach for a sentinel that *depends* on an allowlist entry. Any string
that fails the rule regex is safe, and stays safe if the allowlists are
retuned later.

Then verify — history *and* working tree:

```bash
gitleaks git -c .gitleaks.toml --log-opts="--all" --redact   # INF no leaks found
gitleaks dir . -c .gitleaks.toml --redact                    # INF no leaks found
```

### On rotation

The ref update was rejected, so the commit never became public, browsable,
forkable, or indexed. But the pack **was** transferred and unpacked into
GitHub's quarantine before the pre-receive check ran — that is how the alert
and its unblock URL exist. Those objects are unreferenced and get GC'd.

Rotation is therefore lower-urgency than a true public leak, but not zero: the
raw token sat in a plaintext file on disk, and the environment variable will
keep re-leaking it. Rotate at <https://github.com/settings/personal-access-tokens>.

Note the old commit survives locally as a dangling object for ~90 days of
reflog. Purge with
`git reflog expire --expire-unreachable=now --all && git gc --prune=now`.

## Prevention

1. **Activate the hook stack in every clone** — this is the actual fix:

   ```bash
   scoop install gitleaks     # the `gitleaks-system` hook needs it on PATH
   pre-commit install         # per-clone; cloning the config does NOT arm it
   ```

2. **Don't dump the whole environment.** Ask for the specific variables:

   ```bash
   env | grep -E '^GIT_(DIR|WORK_TREE|EDITOR|SEQUENCE_EDITOR)='   # not `grep -i git`
   ```

3. **Get the PAT out of a plain environment variable.** A credential helper
   (`git credential-manager`, already used here for the `azrepos:*` entries)
   keeps it out of every child process's environment.

## Related

- [`git-add-fatal-crlf-would-be-replaced-by-lf`](git-add-fatal-crlf-would-be-replaced-by-lf.md)
  — same transcript file; why the redaction must be byte-level.
- `.agents/skills/agent-history-hygiene/references/remediation.md` — the
  rotate-first runbook and the pushed/unpushed decision tree.
- [GitHub docs — working with push protection from the command line](https://docs.github.com/code-security/secret-scanning/working-with-secret-scanning-and-push-protection/working-with-push-protection-from-the-command-line)
