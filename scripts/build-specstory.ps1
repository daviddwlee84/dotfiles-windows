#Requires -Version 7
# Compatibility entry point: PR #191 merged; install the official Windows release.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-cli-release.ps1')
Install-WindowsCliRelease -Name specstory -Upgrade
