#Requires -Version 7.4
#Requires -PSEdition Core
# Verified Herdr upgrade orchestration. The caller provides Resolve-HerdrExecutable
# and Sync-HerdrSkill from herdr-skill-sync.ps1.

$script:HerdrInstallerUri = 'https://herdr.dev/install.ps1'
$script:HerdrInstallerSha256 = '3415EA0BC562CAD003AFCC70AC9916B81CDE043C4C26087F05255AE7807D1BA7'

function Invoke-HerdrInstallerProcess {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$Channel
    )

    # The upstream curl download does not retry interrupted connections. Retry
    # once on its explicit transport errors, using the same verified installer
    # and source; authentication, TLS, digest and activation failures stay fatal.
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $result = Invoke-WithWindowsSystemProxy {
            # pwsh avoids Windows PowerShell treating curl stderr as a terminating
            # exception before the installer can check curl's native exit code.
            $output = @(& pwsh -NoProfile -File $InstallerPath -Channel $Channel 2>&1)
            [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
        }
        $output = $result.Output
        $exitCode = $result.ExitCode
        $output | Out-Host
        if ($exitCode -eq 0 -or $attempt -eq 2 -or
            ($output -join "`n") -notmatch 'curl exit code (6|7|18|28|52|55|56)\)') {
            return $exitCode
        }
        Write-Warning 'Herdr download was interrupted; retrying the official installer once.'
    }
}

function Invoke-HerdrOfficialInstaller {
    param(
        [ValidateSet('preview')][string]$Channel = 'preview',
        [string]$InstallerUri = $script:HerdrInstallerUri,
        [string]$ExpectedSha256 = $script:HerdrInstallerSha256
    )

    $installer = Join-Path ([IO.Path]::GetTempPath()) ('herdr-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing $InstallerUri -OutFile $installer -TimeoutSec 60 -ErrorAction Stop
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
