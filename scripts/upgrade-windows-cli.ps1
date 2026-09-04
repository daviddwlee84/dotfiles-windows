#Requires -Version 7
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('dev-cli', 'specstory')][string]$Name)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-cli-release.ps1')
Install-WindowsCliRelease -Name $Name -Upgrade
