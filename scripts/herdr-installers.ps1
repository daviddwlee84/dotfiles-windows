#Requires -Version 7.4
#Requires -PSEdition Core
# Install-only helpers for the Herdr GUI clients and the Herdr 2 runtime:
#   Sheprd (formerly Herdr UI): Herdr 1 GUI client, x64 + ARM64
#   herdr-core (hc):            Herdr 2 terminal runtime, x64 only
#   Herdr App:                  official Herdr 2 desktop app, x64 only
# Each upstream installer is pinned by commit and SHA-256 and runs in its own
# pwsh process (containing upstream preferences, `exit` and Add-Type). The
# installers then verify their release payload's SHA-256 themselves. Updates
# belong to each app afterwards (in-app updaters; `hc update`).

$script:SheprdInstallerUri = 'https://raw.githubusercontent.com/sheprd-labs/sheprd/3b9800ff7cff98141f835fa57bd84b8ae579e156/site/install.ps1'
$script:SheprdInstallerSha256 = '3CFB5EFB4508D6934B21028DB4DAFBAE44257741605809717D4F38F509139AF2'
$script:HerdrCoreInstallerUri = 'https://raw.githubusercontent.com/herdrdev/herdr-core/bb08e28befc52d41ce920771d00fb9c2ba6815f2/distribution/install.ps1'
$script:HerdrCoreInstallerSha256 = '0EB72D7F9E8158142F5633D8039E3B9D02460581869858FDAC95A20BBBC82FEF'
$script:HerdrAppInstallerUri = 'https://raw.githubusercontent.com/herdrdev/herdr-app/4cff5791364ab77532c0a6965019fe7bc3df1ce4/distribution/install.ps1'
$script:HerdrAppInstallerSha256 = 'C973F34EC58FFF5448D639DA48F7A0A97A0CBB4F156D390CAB141E9DF889D59E'

function Invoke-HerdrInstallerScriptProcess {
    param([Parameter(Mandatory)][string]$InstallerPath)
    & pwsh -NoProfile -File $InstallerPath | Out-Host
    return $LASTEXITCODE
}

function Get-HerdrOsArchitecture {
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
}

function Invoke-PinnedHerdrInstaller {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$ExpectedPath
    )
    $installer = Join-Path ([IO.Path]::GetTempPath()) ('herdr-installer-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing $Uri -OutFile $installer -TimeoutSec 60 -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $Sha256) {
            throw "$Name installer checksum mismatch; refusing to execute"
        }
        $exitCode = Invoke-HerdrInstallerScriptProcess -InstallerPath $installer
        if ($exitCode -ne 0) { throw "$Name installer failed with exit $exitCode" }
        if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
            throw "$Name installer did not produce $ExpectedPath"
        }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

function Test-HerdrCommand {
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($n in $Name) {
        if (Get-Command $n -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

# Sheprd keeps the legacy install dir and the herdr-gpui.exe entry point
# alongside sheprd.exe, so either name means "already installed".
function Install-Sheprd {
    $ErrorActionPreference = 'Stop'
    $dir = Join-Path $env:LOCALAPPDATA 'Programs\Herdr UI'
    $exe = Join-Path $dir 'sheprd.exe'
    $legacy = Join-Path $dir 'herdr-gpui.exe'
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -or
        (Test-Path -LiteralPath $legacy -PathType Leaf) -or
        (Test-HerdrCommand @('sheprd', 'herdr-gpui'))) {
        Write-Host 'Sheprd already installed; skipping (updates: Check for Updates in the app)'
        return
    }
    Invoke-PinnedHerdrInstaller -Name 'Sheprd' -Uri $script:SheprdInstallerUri `
        -Sha256 $script:SheprdInstallerSha256 -ExpectedPath $exe
}

function Install-HerdrCore {
    $ErrorActionPreference = 'Stop'
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\herdr-core.exe'
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -or (Test-HerdrCommand @('herdr-core'))) {
        Write-Host 'herdr-core already installed; skipping (updates: just upgrade-herdr-core)'
        return
    }
    $arch = Get-HerdrOsArchitecture
    if ($arch -ne 'X64') {
        Write-Host "herdr-core skipped: upstream ships Windows x64 builds only (this host: $arch)"
        return
    }
    Invoke-PinnedHerdrInstaller -Name 'herdr-core' -Uri $script:HerdrCoreInstallerUri `
        -Sha256 $script:HerdrCoreInstallerSha256 -ExpectedPath $exe
}

function Install-HerdrApp {
    $ErrorActionPreference = 'Stop'
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\herdr-app\herdr-app.exe'
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -or (Test-HerdrCommand @('herdr-app'))) {
        Write-Host 'Herdr App already installed; skipping (updates: Settings > Updates in the app)'
        return
    }
    $arch = Get-HerdrOsArchitecture
    if ($arch -ne 'X64') {
        Write-Host "Herdr App skipped: upstream ships Windows x64 builds only (this host: $arch)"
        return
    }
    Invoke-PinnedHerdrInstaller -Name 'Herdr App' -Uri $script:HerdrAppInstallerUri `
        -Sha256 $script:HerdrAppInstallerSha256 -ExpectedPath $exe
}

# `hc update` swaps the core without ending running terminals; it is safe from
# inside an hc terminal. Only the installer-managed copy is updated here.
function Update-HerdrCore {
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\herdr-core\herdr-core.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Host 'herdr-core (installer-managed) not found; skipping'
        return 0
    }
    & $exe update | Out-Host
    return $LASTEXITCODE
}
