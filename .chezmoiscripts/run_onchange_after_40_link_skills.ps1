#Requires -Version 7
# run_onchange_after_40_link_skills.ps1 — expose the dot_agents skill to Claude
# Code by linking ~/.claude/skills/<name> -> ~/.agents/skills/<name>.
# Uses a directory JUNCTION (not a symlink) so it needs no elevation /
# Developer Mode on Windows.
$ErrorActionPreference = 'Continue'   # best-effort; never abort the apply

$src = Join-Path $HOME '.agents/skills/dotfiles-windows'
$dst = Join-Path $HOME '.claude/skills/dotfiles-windows'

if (-not (Test-Path $src)) { return }

New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null

if (Test-Path $dst) {
    $item = Get-Item $dst -Force
    if ($item.LinkType) { Remove-Item $dst -Force }   # refresh an existing link
    else { Write-Warning "$dst exists and is not a link — leaving it alone"; return }
}
New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
Write-Host "linked $dst -> $src"
