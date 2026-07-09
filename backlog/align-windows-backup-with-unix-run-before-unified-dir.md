# Align Windows backup with Unix: run_before + unified dir

**Status**: P?
**Effort**: S
**Related**: `TODO.md` · `.chezmoiscripts/run_once_before_01_backup.ps1.tmpl` · Unix repo `run_before_01_backup_dotfiles.sh.tmpl`

## Context

2026-07, surfaced while comparing the Windows `bootstrap.ps1` install path
against the Unix `get.chezmoi.io` one-liner. Both repos carry a pre-apply
backup run-script, but they are **not behaviorally equivalent**, and the
divergence means the Windows side offers weaker ongoing protection.

## Investigation

Two differences confirmed by reading both scripts:

1. **Trigger frequency.**
   - Unix: `run_before_01_backup_dotfiles.sh.tmpl` — `run_before_` fires
     **before every `chezmoi apply`**, with a daily-dedup guard, and uses
     `chezmoi status` "smart" mode to back up only files whose col2 ∈ {M,D}
     (about to be overwritten/deleted). Ongoing protection on every apply.
   - Windows: `.chezmoiscripts/run_once_before_01_backup.ps1.tmpl` —
     `run_once_before_` fires **only on the first apply** (or when the script
     content hash changes). After the initial snapshot, editing a local file
     and re-applying does **not** back it up. This is the real gap.

2. **Selection strategy.**
   - Unix: smart (status-driven) vs full (fixed allowlist) vs off.
   - Windows: fixed target allowlist only (smart == full); no status-driven
     selection. Allowlist currently:
     `Documents/PowerShell/Microsoft.PowerShell_profile.ps1`,
     `.config/powershell`, `.config/starship.toml`,
     `%APPDATA%/alacritty/alacritty.toml`,
     `%APPDATA%/{Code,Cursor}/User/settings.json`.

3. **Backup dir naming inconsistency.**
   - Unix writes to `~/.dotfiles_backup` (underscore).
   - Windows writes to `~/.dotfiles-backup` (hyphen).

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Rename `run_once_before_` → `run_before_` on Windows | Every-apply protection, matches Unix intent | `chezmoi status` parsing in PowerShell needed for true smart mode; more work per apply |
| B. Keep `run_once_`, just unify dir name | Trivial, low risk | Leaves the first-apply-only gap unaddressed |
| C. Full parity: `run_before_` + PowerShell `chezmoi status` smart-select + unified dir | Real cross-platform symmetry | Most effort; must parse status output & map target paths on Windows |

## Current blocker / open questions

- Is every-apply backup actually wanted on Windows, or is first-apply-only an
  intentional lighter-touch choice? Need user preference before picking A/C.
- If going smart: does `chezmoi status` output on Windows map cleanly from
  relpath → on-disk target for the parse loop (APPDATA-rooted targets aren't
  under `$HOME`)?
- Dir rename: pick one name for both repos (`~/.dotfiles-backup` reads better;
  Unix uses underscore) — renaming Unix side touches the other repo.

## Decision (if any)

None yet — logged for later. Lowest-risk slice is Option B (dir-name unify);
full value is Option C.

## References

- Windows backup: `.chezmoiscripts/run_once_before_01_backup.ps1.tmpl`
- Unix backup: `run_before_01_backup_dotfiles.sh.tmpl` (repo `daviddwlee84/dotfiles`)
- chezmoi run-script ordering: https://www.chezmoi.io/reference/target-types/#scripts
