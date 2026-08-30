#Requires -Version 7

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'omp-install-core.ps1')

$binary = Get-OmpBinaryPath
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    Write-Host 'OMP is not installed at its managed path; skipping upgrade.'
    exit 0
}
if (-not (Install-OmpBinary -Force)) { exit 1 }
