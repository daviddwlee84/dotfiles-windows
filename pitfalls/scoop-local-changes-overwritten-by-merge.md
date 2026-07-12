# scoop: "Your local changes to the following files would be overwritten by merge" (bucket/*.json)

**Symptoms** (grep this section): `scoop update` / `scoop install` /
`bootstrap.ps1` prints `Updating Scoop... / Updating Buckets...` then
`error: Your local changes to the following files would be overwritten by merge:`
followed by a long list of `bucket/*.json` (e.g. `bucket/amp.json`),
`Please commit your changes or stash them before you merge.`, `Aborting`.
Often **many** manifests at once, and progress then stalls with no further log.
"Why did I/chezmoi modify these?" — you didn't.
**First seen**: 2026-07
**Affects**: scoop on Windows with Git for Windows' default `core.autocrlf=true`;
any `scoop update` / `scoop install` (which auto-updates first), including inside
this repo's `bootstrap.ps1` and the `run_onchange` package script.
**Status**: fixed — `bootstrap.ps1` now sets `core.autocrlf=input` and self-heals
scoop's repos; manual workaround below for machines already in the bad state.

## Symptom

```
Updating Scoop...
Updating Buckets...
error: Your local changes to the following files would be overwritten by merge:
        bucket/amp.json
        bucket/... (many more)
Please commit your changes or stash them before you merge.
Aborting
```

…and then nothing — bootstrap / the package script appears to hang because the
step that triggered the update never completes. The dirty files are **scoop's
own bucket manifests**, not anything you or chezmoi edited.

## Root cause

Each scoop bucket (`~\scoop\buckets\main`, `extras`, …) and scoop's core repo
(`~\scoop\apps\scoop\current`) is a **git clone**. `scoop update` runs `git pull`
in each. The manifests are committed upstream with **LF** line endings, but Git
for Windows defaults to **`core.autocrlf=true`**, which rewrites the working-tree
copies to **CRLF**. Once the tree gets renormalized, git sees *every* `.json` as
locally modified, and the next `git pull` refuses to overwrite them — hence the
whole-directory `bucket/*.json` list. A `git pull` interrupted mid-way (common
behind the GFW, where scoop fetches from GitHub) can leave the same dirty state.

Key point: **chezmoi / these dotfiles never touch `~\scoop\buckets`** — the repo
only manages `$PROFILE`, `~/.config`, etc. This is purely a scoop + git-on-Windows
line-ending quirk. `git diff` on one "modified" manifest shows a whole-file churn
with no real content change — the line-ending tell.

## Workaround

Discard the phantom changes (buckets are disposable indexes — safe) and stop the
renormalization:

```powershell
$scoop = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }

# 1. hard-reset scoop's core repo + every bucket to the committed state
git -C "$scoop\apps\scoop\current" reset --hard
Get-ChildItem "$scoop\buckets" -Directory | ForEach-Object { git -C $_.FullName reset --hard }

# 2. stop git rewriting scoop's LF manifests into CRLF (the recurring cause)
git config --global core.autocrlf input      # 'false' also works

# 3. retry
scoop update
```

If a single bucket stays wedged, re-clone it: `scoop bucket rm main; scoop bucket add main`.

## Prevention

Baked into `bootstrap.ps1`: before the heavier scoop installs it installs `git`,
sets `core.autocrlf=input` (only when unset or `true`, so a deliberate choice is
never overridden), and hard-resets scoop's git repos (`Reset-ScoopRepos`). Scoop
installs also run through `Invoke-Scoop`, which resets the repos and retries once
on any non-zero exit. So a fresh bootstrap — and re-runs after a GFW-interrupted
pull — no longer stall here.

## Related

- `bootstrap.ps1` — `Reset-ScoopRepos` / `Invoke-Scoop` / the `core.autocrlf` step
- `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` — `Ensure-Scoop` / `Scoop-Install` (same buckets)
- scoop issue tracker: line-ending / "overwritten by merge" reports on `ScoopInstaller/Scoop`
