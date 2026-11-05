#Requires -Version 7.4
#Requires -PSEdition Core

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'organization-policy.ps1')
$null = Import-OrganizationPolicyData
Set-OrganizationEnvironment
if (-not (Test-OrganizationSource omp -Operation upgrade)) { exit 1 }
. (Join-Path $PSScriptRoot 'omp-install-core.ps1')

$binary = Get-OmpBinaryPath
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    Write-Host 'OMP is not installed at its managed path; skipping upgrade.'
    exit 0
}
if (-not (Install-OmpBinary -Force)) { exit 1 }
