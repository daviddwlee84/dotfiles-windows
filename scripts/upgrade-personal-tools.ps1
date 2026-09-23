#Requires -Version 7.4
#Requires -PSEdition Core
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'personal-tools.ps1')
. (Join-Path $PSScriptRoot 'windows-cli-release.ps1')
$source = Split-Path $PSScriptRoot -Parent
$dataText = & chezmoi data --source $source --format json
if ($LASTEXITCODE -ne 0) { throw 'Could not read this Windows dotfiles configuration' }
$data = ($dataText -join "`n") | ConvertFrom-Json -AsHashtable
$results = @(Update-SelectedPersonalTools -Data $data -WhatIf:$WhatIfPreference)
$results | Format-Table -AutoSize
if (@($results | Where-Object Status -EQ 'failed').Count) { exit 1 }
