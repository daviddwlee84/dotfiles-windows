# Verified Herdr upgrade orchestration. The caller provides Resolve-HerdrExecutable
# and Sync-HerdrSkill from herdr-skill-sync.ps1.

$script:HerdrInstallerUri = 'https://herdr.dev/install.ps1'
$script:HerdrInstallerSha256 = '3415EA0BC562CAD003AFCC70AC9916B81CDE043C4C26087F05255AE7807D1BA7'

function Invoke-HerdrInstallerProcess {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$Channel
    )

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallerPath -Channel $Channel 2>&1 | Out-Host
    return $LASTEXITCODE
}

function Invoke-HerdrOfficialInstaller {
    param(
        [ValidateSet('preview')][string]$Channel = 'preview',
        [string]$InstallerUri = $script:HerdrInstallerUri,
        [string]$ExpectedSha256 = $script:HerdrInstallerSha256
    )

    $installer = Join-Path ([IO.Path]::GetTempPath()) ('herdr-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing $InstallerUri -OutFile $installer -ErrorAction Stop
        $actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSha256) {
            throw "Herdr installer changed; expected $ExpectedSha256, got $actual. Stop and re-audit it."
        }

        $exitCode = Invoke-HerdrInstallerProcess -InstallerPath $installer -Channel $Channel
        if ($exitCode -ne 0) { throw "Official Herdr installer failed with exit $exitCode" }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

function Get-HerdrVersion {
    param([Parameter(Mandatory)][string]$HerdrPath)

    $output = @(& $HerdrPath --version 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Installed Herdr failed its version probe: $HerdrPath" }
    return ($output -join "`n").Trim()
}

function Invoke-HerdrUpgrade {
    [CmdletBinding()]
    param([ValidateSet('preview')][string]$Channel = 'preview')

    $herdr = Resolve-HerdrExecutable
    if (-not $herdr) {
        Write-Warning 'herdr is not installed; skipping'
        return 0
    }
    if ($env:HERDR_ENV -or $env:HERDR_PANE_ID) {
        Write-Warning 'Run this outside Herdr after detaching; the installer cannot replace the server that owns this pane.'
        return 0
    }

    Write-Host '==> Upgrading Herdr with verified official installer'
    try {
        Invoke-HerdrOfficialInstaller -Channel $Channel
        $herdr = Resolve-HerdrExecutable
        if (-not $herdr -or -not (Test-Path -LiteralPath $herdr -PathType Leaf)) {
            throw 'Installed Herdr executable is missing after the installer completed'
        }
        $version = Get-HerdrVersion -HerdrPath $herdr
        Write-Host $version
        if (-not (Sync-HerdrSkill -HerdrPath $herdr)) {
            throw 'Herdr installed, but its global agent skill could not be synchronized; prior copies were preserved.'
        }
    } catch {
        Write-Error $_
        return 1
    }

    Write-Host '==> Herdr binary and global agent skill updated'
    Write-Warning 'Restart Herdr deliberately to load the new binary; check `herdr integration status` for integrations that need reinstalling.'
    return 0
}
