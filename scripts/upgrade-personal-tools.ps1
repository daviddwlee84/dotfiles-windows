#Requires -Version 7.4
#Requires -PSEdition Core
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'personal-tools.ps1')
. (Join-Path $PSScriptRoot 'windows-cli-release.ps1')
. (Join-Path $PSScriptRoot 'organization-policy.ps1')
$organization = Import-OrganizationPolicyData
Set-OrganizationEnvironment
$data = $organization.Data
$results = @(Update-SelectedPersonalTools -Data $data -WhatIf:$WhatIfPreference)
$results | Format-Table -AutoSize
if (@($results | Where-Object Status -EQ 'failed').Count) { exit 1 }
