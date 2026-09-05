# Cross-platform Git checkouts

Repositories used from Windows, macOS, Linux, and WSL cross several filesystem
boundaries that Git cannot make identical. The managed defaults are deliberately
small: `core.autocrlf = input` keeps committed text LF-normalized, while
`core.symlinks = true` asks Git for real links on Windows. Repository-owned
`.gitattributes` remains the authority for file-specific EOL and binary rules.

## Audit and repair

```powershell
# Current repository, read-only
git-windows-doctor

# Repair only safe symlink placeholders
gwinfix

# Audit or repair a collection of existing repositories
git-windows-doctor -Root ~/Documents/Program
gwinfix -Root ~/Documents/Program -WhatIf
gwinfix -Root ~/Documents/Program
```

`gwinfix` only replaces a regular file when its bytes exactly match the symlink
target stored in the current Git index, or restores a missing tracked symlink.
It refuses modified files, real directories, unexpected links, and unmerged
index entries. It also tests Windows symlink creation before deleting anything.
After a successful repair it removes a repo-local `core.symlinks` override so
the managed user-level `true` value remains authoritative. Changing the setting
alone does not rewrite paths already checked out; that is why old clones need
the one-time repair.

All other findings are read-only. In particular, the command never runs
`git add --renormalize .`, changes executable bits, renames paths, installs Git
LFS, or toggles filesystem case sensitivity.

## Common portability boundaries

| Area | Failure on another OS | Policy / repair |
|---|---|---|
| Symbolic links | Git for Windows checks a link out as a one-line target file | Enable Windows Developer Mode, keep `core.symlinks=true`, then run `gwinfix` once for an old checkout. |
| Line endings | Shell scripts gain CRLF; generated files become mixed; `safecrlf` rejects `git add` | Commit an explicit `.gitattributes`; inspect with `git ls-files --eol`. Renormalize only on a clean branch and review the resulting diff. |
| Executable bit | Windows cannot infer the Unix execute bit | Record it in the index with `git update-index --chmod=+x path/to/script`; do not set global `core.filemode=true` as a substitute. |
| Case sensitivity | `Foo.py` and `foo.py`, or case-only renames, collide on normal Windows/macOS volumes | Keep unique case-insensitive names. For a case-only rename, use an intermediate `git mv` name. |
| Windows filenames | `CON`, `NUL`, trailing dots/spaces, and characters such as `:` or `*` cannot be checked out normally | Rename in Git from a compatible filesystem; do not disable `core.protectNTFS` as a routine workaround. |
| Long paths | Git or downstream Windows tools fail near legacy path limits | Shorten repository/path names first. Enable `core.longpaths` only when needed; applications outside Git can still retain shorter limits. |
| Git LFS | Checkout leaves pointer text instead of the binary asset | Install Git LFS, run `git lfs install`, then fetch/checkout the required objects. |
| Windows + WSL | Two Git implementations apply different config, permissions, path, and watcher behavior to one worktree | Prefer separate clones for native Windows and WSL work. If sharing is unavoidable, choose one Git implementation to perform writes. |
| Encoding | UTF-8 BOM breaks Unix shebangs; Windows PowerShell 5.1 interprets BOM-less UTF-8 differently from PowerShell 7 | Keep shell scripts BOM-free UTF-8/LF. Treat legacy Windows PowerShell files explicitly rather than applying one encoding rewrite to the whole repo. |

## Suggested `.gitattributes` baseline

Adapt this to the repository; binary and generated-file exceptions are part of
the policy, not optional decoration:

```gitattributes
* text=auto eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf
*.png binary
*.jpg binary
*.pdf binary
```

After introducing or changing `.gitattributes`, perform any intentional
renormalization separately:

```powershell
git status --short
git add --renormalize .
git diff --cached --check
git diff --cached
```

Do this only with a clean, dedicated branch. EOL normalization can legitimately
touch many files, so it is never part of `gwinfix`.
