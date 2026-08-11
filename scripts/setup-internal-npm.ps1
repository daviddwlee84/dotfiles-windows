#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Registry = 'https://pkgs.dev.azure.com/O365Exchange/_packaging/O365Infra_NPM/npm/registry/',
    [string]$ProviderRegistry = 'https://pkgs.dev.azure.com/artifacts-public/23934c1b-a3b5-4b70-9dd3-d1bef4cc72a0/_packaging/AzureArtifacts/npm/registry/'
)

$ErrorActionPreference = 'Stop'
function Info($Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) {
    throw 'npm.cmd not found. Install Node first (scoop install nodejs-lts), open a new PowerShell, then retry.'
}

$provider = Get-Command artifacts-npm-credprovider -ErrorAction SilentlyContinue
$npmRoot = (& $npm.Source root --global).Trim()
$nativeProvider = Join-Path $npmRoot '@microsoft\artifacts-npm-credprovider\node_modules\@microsoft\artifacts-credprovider-wrapper\bin\CredentialProvider.Microsoft.exe'
if (-not $provider -or -not (Test-Path $nativeProvider)) {
    Info 'installing the Azure Artifacts npm credential provider'
    & $npm.Source install --global '@microsoft/artifacts-npm-credprovider' `
        --registry $ProviderRegistry --foreground-scripts --loglevel=notice
    if ($LASTEXITCODE -ne 0) { throw 'Credential-provider npm installation failed.' }
    $provider = Get-Command artifacts-npm-credprovider -ErrorAction SilentlyContinue
    if (-not $provider -or -not (Test-Path $nativeProvider)) {
        throw 'The credential provider was installed but its command or native helper is missing.'
    }
} else {
    Info 'Azure Artifacts npm credential provider is already installed'
}

$npmrc = Join-Path $HOME '.npmrc'
$lines = if (Test-Path $npmrc) { @(Get-Content $npmrc) } else { @() }
$registryLine = "registry=$Registry"
$lines = @($lines | Where-Object { $_ -notmatch '^\s*(registry|always-auth)\s*=' })
$lines += $registryLine, 'always-auth=true'
$lines | Set-Content -LiteralPath $npmrc -Encoding utf8

Info 'authenticating the internal npm feed'
& $provider.Source --config-file $npmrc --verbosity minimal
if ($LASTEXITCODE -ne 0) { throw 'Azure Artifacts npm authentication failed.' }

$localProfile = Join-Path $HOME '.config\powershell\local.ps1'
New-Item -ItemType Directory -Force -Path (Split-Path $localProfile) | Out-Null
$assignment = "`$env:npm_config_registry = '$Registry'"
$localLines = if (Test-Path $localProfile) { @(Get-Content $localProfile) } else { @() }
$localLines = @($localLines | Where-Object { $_ -notmatch '^\s*\$env:npm_config_registry\s*=' })
$localLines += $assignment
$localLines | Set-Content -LiteralPath $localProfile -Encoding utf8
$env:npm_config_registry = $Registry

Info 'deploying and reloading the Copilot module'
$moduleTarget = Join-Path $HOME '.config\powershell\modules\Copilot\Copilot.psm1'
$moduleSource = Join-Path $PSScriptRoot '..\dot_config\powershell\modules\Copilot\Copilot.psm1'
if (-not (Test-Path $moduleSource)) { throw "Copilot module source not found: $moduleSource" }
New-Item -ItemType Directory -Force -Path (Split-Path $moduleTarget) | Out-Null
Copy-Item -LiteralPath $moduleSource -Destination $moduleTarget -Force
Import-Module (Join-Path (Split-Path $moduleTarget) 'Copilot.psd1') -Force

Info 'verifying the internal feed'
& $npm.Source view '@jeffreycao/copilot-api@2.1.0' version --fetch-timeout=30000 --fetch-retries=1
if ($LASTEXITCODE -ne 0) { throw 'The internal feed is configured but the Copilot package cannot be resolved.' }

Write-Host "`nInternal npm authentication is ready. Open a new PowerShell (or run: reload), then run: copilot-proxy reinstall" -ForegroundColor Green
