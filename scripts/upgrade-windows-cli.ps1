#Requires -Version 7.4
#Requires -PSEdition Core
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('dev-cli', 'specstory')][string]$Name)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-cli-release.ps1')
Install-WindowsCliRelease -Name $Name -Upgrade
