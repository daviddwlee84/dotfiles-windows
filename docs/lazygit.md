# LazyGit branch insights

LazyGit reads the managed `~/.config/lazygit/config.yml` because the PowerShell
profile sets `XDG_CONFIG_HOME`. The config keeps the existing `delta` diff
renderer and adds a status-first Local branches view:

- Nerd Font v3 icons.
- Prefix colors for feature, fix, docs, maintenance, worktree, and automation
  branches.
- Recency ordering.
- Right-aligned base-branch divergence (`↓N`).

`↓N` means that the branch is behind LazyGit's detected base branch. It does
not prove that the branch is merged: the branch may also have unique commits.
Likewise, the normal upstream `✓` means local and upstream are synchronized,
not that main contains the branch.

## `I` Branch insights

In the Local branches panel, press **`I`** and choose:

| Key | Report | Network |
|---|---|---|
| `g` | Exact Git containment against local and remote-tracking main | none |
| `p` | The same report plus recent GitHub PR state from one `gh pr list` call | GitHub |

The native PowerShell helper is read-only. It does not fetch, checkout, delete,
or modify refs, so refresh LazyGit before relying on remote results.

```text
Local base:  main
Remote base: origin/main
Local main vs origin/main: ahead 1, behind 0

SEL LOC REM  BASE-  BASE+ UPSTREAM      WORKTREE     DATE       BRANCH  PR
    Y   Y       12      0 gone          -            2026-08-20 fix/old  MERGED->main#42
>   Y   N        0      1 up1           repo-wt      2026-09-01 feat/new OPEN->main#43
```

- `LOC` / `REM`: whether the branch tip is an ancestor of local / remote main.
- `BASE-` / `BASE+`: commits found only on the comparison base / only on the
  branch.
- `UPSTREAM`: `=`, `upN`, `downN`, `downN/upN`, `gone`, or `-`.
- `WORKTREE`: the leaf directory of the worktree using the branch.
- `PR`: best-effort GitHub state. A squash-merged PR can correctly show both
  `PR=MERGED` and `REM=N` because these answer different questions.

Base detection checks `origin/HEAD`, then `main`, then `master`. Override it for
a repository that uses another trunk:

```powershell
git config lazygit.branchBase develop
```

A remote-tracking value such as `upstream/trunk` is also accepted.

## Diff rendering

LazyGit v0.64+ uses `git.diffRenderers`; this repo configures `delta` with dark,
non-paging output. The config deliberately avoids the deprecated `git.pagers`
shape so LazyGit does not rewrite the chezmoi-managed file.

## References

- [LazyGit configuration](https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md)
- [LazyGit custom commands](https://github.com/jesseduffield/lazygit/blob/master/docs/Custom_Command_Keybindings.md)
- [GitHub CLI PR list](https://cli.github.com/manual/gh_pr_list)
