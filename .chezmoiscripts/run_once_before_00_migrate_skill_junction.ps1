#Requires -Version 7
# run_once_before_00_migrate_skill_junction.ps1 — one-time migration.
#
# An earlier version linked the agent skill with a Windows JUNCTION:
#   ~/.claude/skills/dotfiles-windows  ->  ~/.agents/skills/dotfiles-windows
# created by the now-removed run_onchange_after_40_link_skills.ps1. The current
# design instead deploys a REAL SKILL.md under BOTH ~/.agents/skills/ and
# ~/.claude/skills/ (rendered from one shared template). chezmoi cannot
# reconcile a regular file against an existing junction / reparse point and
# aborts the ENTIRE apply with:
#   unsupported file type 0o2000000: unknown type
#
# Remove any stale reparse point at those paths so chezmoi can write the real
# files. Pure no-op once they're regular directories (new installs never see a
# junction here). Fault-tolerant: never abort the apply.
$ErrorActionPreference = 'Continue'

foreach ($p in @(
    (Join-Path $HOME '.claude\skills\dotfiles-windows'),
    (Join-Path $HOME '.agents\skills\dotfiles-windows')
)) {
    try {
        $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Host "==> removing stale skill junction: $p" -ForegroundColor Cyan
            # Non-recursive delete unlinks the junction WITHOUT touching the
            # directory it points at (Remove-Item -Recurse could follow it).
            [System.IO.Directory]::Delete($p, $false)
        }
    } catch {
        Write-Warning "could not remove stale junction $p (non-fatal): $_"
    }
}
