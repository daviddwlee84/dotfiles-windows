#Requires -Version 7.4
#Requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('dev-cli', 'specstory')][string]$Name)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'organization-policy.ps1')
$null = Import-OrganizationPolicyData
Set-OrganizationEnvironment
if (-not (Test-OrganizationSource $Name -Operation upgrade)) { exit 1 }
. (Join-Path $PSScriptRoot 'windows-cli-release.ps1')
Install-WindowsCliRelease -Name $Name -Upgrade
