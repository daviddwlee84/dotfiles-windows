#Requires -Version 7.4
#Requires -PSEdition Core
$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

. (Join-Path $PSScriptRoot 'herdr-skill-sync.ps1')
. (Join-Path $PSScriptRoot 'windows-system-proxy.ps1')
. (Join-Path $PSScriptRoot 'herdr-upgrade-core.ps1')

exit (Invoke-HerdrUpgrade -Channel preview)
