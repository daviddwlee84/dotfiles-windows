# Helpers embedded into the package run-onchange script. Only callers decide
# whether failure is fatal; the installer records failures and continues.

function ConvertTo-ScoopSemanticVersion {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim()
    if ($normalized -notmatch '^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$') { return $null }
    try { [System.Management.Automation.SemanticVersion]::new($Matches[1]) } catch { $null }
}

function Get-ScoopAppMetadata {
    param([Parameter(Mandatory)] [string] $Name)
    try { @((scoop export | ConvertFrom-Json).apps | Where-Object Name -EQ $Name)[0] } catch { $null }
}

function Test-ScoopMinimumVersion {
    param([string] $Version, [Parameter(Mandatory)] [string] $MinimumVersion)
    $current = ConvertTo-ScoopSemanticVersion $Version
    $minimum = ConvertTo-ScoopSemanticVersion $MinimumVersion
    $null -ne $current -and $null -ne $minimum -and $current.CompareTo($minimum) -ge 0
}

function Ensure-ScoopMinimumVersion {
    param(
        [Parameter(Mandatory)] [string] $App,
        [Parameter(Mandatory)] [string] $MinimumVersion
    )
    $installed = Get-ScoopAppMetadata -Name $App
    if (-not $installed) {
        Register-Failure "scoop:$App (requires >= $MinimumVersion; not installed)"
        return $false
    }
    if (Test-ScoopMinimumVersion -Version ([string]$installed.Version) -MinimumVersion $MinimumVersion) { return $true }

    Info "scoop update $App ($($installed.Version) -> >= $MinimumVersion)"
    $updateExitCode = 1
    try {
        scoop update $App 2>&1 | Out-Host
        $updateExitCode = $LASTEXITCODE
    } catch { Write-Warning "scoop update $App error: $_" }
    $updated = Get-ScoopAppMetadata -Name $App
    if ($updateExitCode -eq 0 -and $updated -and (Test-ScoopMinimumVersion -Version ([string]$updated.Version) -MinimumVersion $MinimumVersion)) { return $true }

    $found = if ($updated) { [string]$updated.Version } else { 'not installed' }
    Write-Warning "scoop $App remains incompatible after update (exit $updateExitCode; requires >= $MinimumVersion; found $found)"
    Register-Failure "scoop:$App"
    $false
}