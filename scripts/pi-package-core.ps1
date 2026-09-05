#Requires -Version 7.4
#Requires -PSEdition Core
# Shared Pi npm package lifecycle. The apply-time installer includes this file
# verbatim; the explicit upgrade command dot-sources it.

$script:PiCodingAgentPackage = '@earendil-works/pi-coding-agent'
$script:DeprecatedPiCodingAgentPackage = '@mariozechner/pi-coding-agent'
$script:PiMinimumNodeVersion = [version] '22.19.0'

function Get-PiNodeVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $NodeExecutable)

    $output = @(& $NodeExecutable --version 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        throw "could not run $NodeExecutable --version"
    }
    $text = (($output | ForEach-Object { [string] $_ }) -join "`n").Trim()
    if ($text -notmatch '^v?(?<Version>\d+\.\d+\.\d+)(?:[-+].*)?$') {
        throw "unrecognized Node version: $text"
    }
    [version] $Matches.Version
}

function Get-NpmGlobalPackageManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Package
    )

    Join-Path (Join-Path $Root $Package) 'package.json'
}

function Get-PiOwnedNpmContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $NpmContext)

    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
    $prefix = Join-Path $scoopRoot 'persist\nodejs-lts\bin'
    [pscustomobject]@{
        NodeExecutable = $NpmContext.NodeExecutable
        NpmCli = $NpmContext.NpmCli
        Root = Join-Path $prefix 'node_modules'
        Prefix = $prefix
        Cache = $NpmContext.Cache
        ConfigValues = $NpmContext.ConfigValues
    }
}

function Get-PiOwnedNpmCommandPath {
    [CmdletBinding()]
    param()

    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
    Join-Path $scoopRoot 'apps\nodejs-lts\current\npm.cmd'
}

function Get-PiShimPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Prefix)

    @(
        (Join-Path $Prefix 'pi.cmd'),
        (Join-Path $Prefix 'pi.ps1')
    )
}

function Get-PiMigrationShimPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Prefix)

    @(
        (Join-Path $Prefix 'pi'),
        (Join-Path $Prefix 'pi.cmd'),
        (Join-Path $Prefix 'pi.ps1')
    )
}

function New-PiMigrationSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $NpmContext)

    $root = Join-Path ([IO.Path]::GetTempPath()) ('pi-migration-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $items = [Collections.Generic.List[object]]::new()
    try {
        foreach ($package in $script:PiCodingAgentPackage, $script:DeprecatedPiCodingAgentPackage) {
            $manifest = Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root -Package $package
            $source = Split-Path -Parent $manifest
            if (Test-Path -LiteralPath $source -PathType Container) {
                $backup = Join-Path $root ('package-' + $items.Count)
                Copy-Item -LiteralPath $source -Destination $backup -Recurse -Force -ErrorAction Stop
                $items.Add([pscustomobject]@{ Source = $source; Backup = $backup; Kind = 'Directory' })
            }
        }
        foreach ($source in (Get-PiMigrationShimPaths -Prefix $NpmContext.Prefix)) {
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $backup = Join-Path $root ('shim-' + $items.Count)
                Copy-Item -LiteralPath $source -Destination $backup -Force -ErrorAction Stop
                $shimText = try { (Get-Content -Raw -LiteralPath $source -ErrorAction Stop) -replace '\\', '/' } catch { '' }
                $ownedByDeprecated = $shimText.ToLowerInvariant().Contains(
                    'node_modules/@mariozechner/pi-coding-agent/'
                )
                $items.Add([pscustomobject]@{
                    Source = $source; Backup = $backup; Kind = 'File'
                    OwnedByDeprecated = $ownedByDeprecated
                })
            }
        }
        [pscustomobject]@{ Root = $root; Items = @($items) }
    } catch {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Restore-PiPreservedShims {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Snapshot)

    foreach ($item in $Snapshot.Items) {
        if ($item.Kind -eq 'File' -and -not $item.OwnedByDeprecated) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $item.Source) | Out-Null
            Copy-Item -LiteralPath $item.Backup -Destination $item.Source -Force -ErrorAction Stop
        }
    }
}

function Remove-PiPartialCanonicalInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $NpmContext)

    $manifest = Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root `
        -Package $script:PiCodingAgentPackage
    $packageRoot = Split-Path -Parent $manifest
    try {
        if (Test-Path -LiteralPath $packageRoot) {
            Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $packageRoot) { throw "could not clear $packageRoot" }
        $true
    } catch {
        Write-Warning "Could not remove partial canonical Pi package: $_"
        $false
    }
}

function Test-PiCanonicalEntrypoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $NpmContext,
        [Parameter(Mandatory)] [string] $Entrypoint
    )

    $probe = Invoke-CapturedPackageProcess -Executable $NpmContext.NodeExecutable `
        -Arguments @($Entrypoint, '--version') -TimeoutSeconds 30 -OutputMode Capture
    $probe.ExitCode -eq 0 -and -not $probe.TimedOut -and -not $probe.LaunchFailed -and
        -not [string]::IsNullOrWhiteSpace($probe.Stdout)
}

function Restore-PiMigrationSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $NpmContext,
        [Parameter(Mandatory)] $Snapshot
    )

    try {
        foreach ($package in $script:PiCodingAgentPackage, $script:DeprecatedPiCodingAgentPackage) {
            $manifest = Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root -Package $package
            $packageRoot = Split-Path -Parent $manifest
            if (Test-Path -LiteralPath $packageRoot) {
                Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $packageRoot) { throw "could not clear package path $packageRoot" }
        }
        foreach ($shim in (Get-PiMigrationShimPaths -Prefix $NpmContext.Prefix)) {
            if (Test-Path -LiteralPath $shim) {
                Remove-Item -LiteralPath $shim -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $shim) { throw "could not clear shim path $shim" }
        }
        foreach ($item in $Snapshot.Items) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $item.Source) | Out-Null
            if ($item.Kind -eq 'Directory') {
                Copy-Item -LiteralPath $item.Backup -Destination $item.Source -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $item.Backup -Destination $item.Source -Force -ErrorAction Stop
            }
            $expectedType = if ($item.Kind -eq 'Directory') { 'Container' } else { 'Leaf' }
            if (-not (Test-Path -LiteralPath $item.Source -PathType $expectedType)) {
                throw "restored item is missing: $($item.Source)"
            }
        }
        $true
    } catch {
        Write-Warning "Could not restore the pre-migration Pi installation: $_"
        $false
    }
}

function Test-PiCanonicalInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $NpmContext)

    $manifest = Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root `
        -Package $script:PiCodingAgentPackage
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    try {
        $metadata = Get-Content -Raw -LiteralPath $manifest -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $binTarget = if ($metadata.bin -is [string]) { [string] $metadata.bin } else { [string] $metadata.bin.pi }
        if (-not $binTarget) { return $false }
        $packageRoot = Split-Path -Parent $manifest
        $root = [IO.Path]::GetFullPath($packageRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
        $entrypoint = [IO.Path]::GetFullPath((Join-Path $packageRoot $binTarget))
        if (-not $entrypoint.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) { return $false }
        if (-not (Test-PiCanonicalEntrypoint -NpmContext $NpmContext -Entrypoint $entrypoint)) { return $false }
    } catch {
        return $false
    }
    $true
}

function Remove-DeprecatedPiCodingAgent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $NpmContext)

    $manifest = Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root `
        -Package $script:DeprecatedPiCodingAgentPackage
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $true }

    Write-Host "==> migrating deprecated $($script:DeprecatedPiCodingAgentPackage) to $($script:PiCodingAgentPackage)"
    $result = Invoke-InteractivePackageProcess -Executable $NpmContext.NodeExecutable `
        -Arguments @(
            $NpmContext.NpmCli, 'uninstall', '-g', '--ignore-scripts',
            $script:DeprecatedPiCodingAgentPackage,
            "--prefix=$($NpmContext.Prefix)"
        ) -TimeoutSeconds 120
    if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        Write-Warning "Could not remove deprecated npm package $($script:DeprecatedPiCodingAgentPackage)."
        return $false
    }
    $true
}

function Invoke-PiCodingAgentPackageCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $NpmContext,
        [Parameter(Mandatory)] [ValidateSet('Install', 'Update')] [string] $Action,
        [Parameter(Mandatory)] [bool] $ManagedMachine,
        [Parameter(Mandatory)] [bool] $AllowPublicFallback,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 600
    )

    $deprecatedManifest = Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root `
        -Package $script:DeprecatedPiCodingAgentPackage
    $hadDeprecated = Test-Path -LiteralPath $deprecatedManifest -PathType Leaf
    $hadCanonicalManifest = Test-Path -LiteralPath `
        (Get-NpmGlobalPackageManifestPath -Root $NpmContext.Root -Package $script:PiCodingAgentPackage) `
        -PathType Leaf

    if ($Action -eq 'Update' -and -not $hadCanonicalManifest -and -not $hadDeprecated) {
        Write-Host "==> Pi is not installed -- skipping explicit update"
        return [pscustomobject]@{ Succeeded = $true; ExitCode = 0; Skipped = $true; Failure = $null }
    }

    try {
        $nodeVersion = Get-PiNodeVersion -NodeExecutable $NpmContext.NodeExecutable
    } catch {
        return [pscustomobject]@{
            Succeeded = $false; ExitCode = 1; Skipped = $false
            Failure = "requires Node >= $script:PiMinimumNodeVersion; version probe failed: $_"
        }
    }
    if ($nodeVersion -lt $script:PiMinimumNodeVersion) {
        return [pscustomobject]@{
            Succeeded = $false; ExitCode = 1; Skipped = $false
            Failure = "requires Node >= $script:PiMinimumNodeVersion; found $nodeVersion"
        }
    }

    $canonicalHealthy = Test-PiCanonicalInstall -NpmContext $NpmContext
    $migrationSnapshot = $null
    $retainMigrationSnapshot = $false

    if ($Action -eq 'Install' -and $canonicalHealthy -and -not $hadDeprecated) {
        Write-Host "==> npm: $($script:PiCodingAgentPackage) already installed -- skipping (upgrade: just upgrade-npm-agents)"
        return [pscustomobject]@{ Succeeded = $true; ExitCode = 0; Skipped = $true; Failure = $null }
    }

    if ($hadDeprecated -or $hadCanonicalManifest) {
        try {
            $migrationSnapshot = New-PiMigrationSnapshot -NpmContext $NpmContext
        } catch {
            return [pscustomobject]@{
                Succeeded = $false; ExitCode = 1; Skipped = $false
                Failure = "could not snapshot the existing Pi installation before migration: $_"
            }
        }
    }

    try {
        if (-not (Remove-DeprecatedPiCodingAgent -NpmContext $NpmContext)) {
            $restored = -not $migrationSnapshot -or
                (Restore-PiMigrationSnapshot -NpmContext $NpmContext -Snapshot $migrationSnapshot)
            if (-not $restored -and $migrationSnapshot) { $retainMigrationSnapshot = $true }
            $recovery = if ($retainMigrationSnapshot) { "; recovery snapshot=$($migrationSnapshot.Root)" } else { '' }
            return [pscustomobject]@{
                Succeeded = $false; ExitCode = 1; Skipped = $false
                Failure = "could not migrate $script:DeprecatedPiCodingAgentPackage; rollback restored=$restored$recovery"
            }
        }

    # `npm update` does not install a missing package. This matters during the
    # one-time migration: after removing the deprecated package, an explicit
    # upgrade must install the canonical replacement rather than leave `pi`
    # absent. The reviewed package has no required lifecycle scripts, so both
    # paths explicitly deny them.
        $verb = if ($Action -eq 'Update' -and $canonicalHealthy -and -not $hadDeprecated) {
            'update'
        } else {
            'install'
        }
        Write-Host "==> npm $verb -g --ignore-scripts --no-bin-links $($script:PiCodingAgentPackage)"
        $packageArguments = @(
            $NpmContext.NpmCli, $verb, '-g', '--ignore-scripts', '--no-bin-links',
            $script:PiCodingAgentPackage
        )
        if (-not $ManagedMachine) { $packageArguments += "--prefix=$($NpmContext.Prefix)" }
        $result = Invoke-PackageSourceCommand -Manager npm -Executable $NpmContext.NodeExecutable `
            -Arguments $packageArguments `
            -Operation $script:PiCodingAgentPackage -PackageSpec $script:PiCodingAgentPackage `
            -NpmPrefix $NpmContext.Prefix -NpmCache $NpmContext.Cache `
            -NpmConfigValues $NpmContext.ConfigValues -ManagedMachine $ManagedMachine `
            -AllowPublicFallback $AllowPublicFallback -TimeoutSeconds $TimeoutSeconds
        $healthy = $result.Succeeded -and (Test-PiCanonicalInstall -NpmContext $NpmContext)
        if (-not $healthy) {
            $restored = if ($migrationSnapshot) {
                Restore-PiMigrationSnapshot -NpmContext $NpmContext -Snapshot $migrationSnapshot
            } else {
                Remove-PiPartialCanonicalInstall -NpmContext $NpmContext
            }
            if (-not $restored -and $migrationSnapshot) { $retainMigrationSnapshot = $true }
            $recovery = if ($retainMigrationSnapshot) { "; recovery snapshot=$($migrationSnapshot.Root)" } else { '' }
            $failure = if (-not $result.Succeeded) {
                "canonical package install failed; rollback restored=$restored$recovery"
            } else {
                "canonical package completed but its manifest/bin entrypoint is invalid; rollback restored=$restored$recovery"
            }
            return [pscustomobject]@{
                Succeeded = $false; ExitCode = $(if ($result.ExitCode) { $result.ExitCode } else { 1 })
                Skipped = $false; Failure = $failure
            }
        }
        if ($migrationSnapshot) { Restore-PiPreservedShims -Snapshot $migrationSnapshot }
        $result
    } catch {
        $operationFailure = $_
        $restored = if ($migrationSnapshot) {
            Restore-PiMigrationSnapshot -NpmContext $NpmContext -Snapshot $migrationSnapshot
        } else {
            Remove-PiPartialCanonicalInstall -NpmContext $NpmContext
        }
        if (-not $restored -and $migrationSnapshot) { $retainMigrationSnapshot = $true }
        $recovery = if ($retainMigrationSnapshot) { "; recovery snapshot=$($migrationSnapshot.Root)" } else { '' }
        [pscustomobject]@{
            Succeeded = $false; ExitCode = 1; Skipped = $false
            Failure = "Pi package operation threw: $operationFailure; rollback restored=$restored$recovery"
        }
    } finally {
        if ($migrationSnapshot -and -not $retainMigrationSnapshot) {
            Remove-Item -LiteralPath $migrationSnapshot.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
