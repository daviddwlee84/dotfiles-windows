#Requires -Version 7
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

. (Join-Path $PSScriptRoot 'herdr-skill-sync.ps1')

$herdr = Resolve-HerdrExecutable
if (-not $herdr) {
    Write-Warning 'herdr is not installed; skipping'
    exit 0
}
if ($env:HERDR_ENV -or $env:HERDR_PANE_ID) {
    Write-Warning 'Run this outside Herdr after detaching; update --handoff cannot replace the server that owns this pane.'
    exit 0
}

Write-Output '==> Upgrading Herdr with live handoff'
& $herdr update --handoff
if ($LASTEXITCODE -ne 0) {
    Write-Error 'herdr update --handoff failed'
    exit 1
}

if (-not (Sync-HerdrSkill -HerdrPath $herdr)) {
    Write-Error 'Herdr updated, but its global agent skill could not be synchronized'
    exit 1
}

Write-Output '==> Herdr binary and global agent skill updated'
Write-Warning 'Reconnect clients with herdr; check `herdr integration status` for integrations that need reinstalling.'
