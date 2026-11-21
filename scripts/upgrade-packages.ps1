#Requires -Version 7.4
#Requires -PSEdition Core
[CmdletBinding()]
param([ValidateSet('All', 'Scoop', 'Winget', 'Yazi', 'Translate', 'Pia')][string]$Action = 'All')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'organization-policy.ps1')
. (Join-Path $PSScriptRoot 'organization-packages.ps1')
$null = Import-OrganizationPolicyData
if (Test-MicrosoftOrganization) {
    Set-OrganizationEnvironment
    if ($Action -eq 'Scoop') { throw 'Scoop upgrades are disabled by Microsoft profile. Use just upgrade.' }
    if ($Action -eq 'Pia') {
        if (-not (Test-OrganizationSource pi-agents -Operation upgrade)) { exit 1 }
        $root = Join-Path $HOME '.local\share\pi-agents'
        if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { Write-Host 'pia missing; upgrade does not install it.'; exit 0 }
        $git = Resolve-OrganizationCommand git
        if (-not $git) { throw 'Approved Git unavailable.' }
        $origin = @(& $git -C $root remote get-url origin) -join ''
        if ($LASTEXITCODE -ne 0 -or $origin -notmatch '^https://github\.com/daviddwlee84/pi-agents(?:\.git)?/?$') { throw 'pia origin is not the cataloged source; preserved.' }
        & $git -C $root pull --ff-only
        exit $LASTEXITCODE
    }
    if ($Action -eq 'Yazi') {
        if (-not (Test-OrganizationSource yazi-plugins -Operation upgrade)) { exit 1 }
        $results = @(Invoke-OrganizationPackages -Upgrade -Only yazi)
        $results | Format-Table -Wrap
        if (@($results | Where-Object Status -EQ 'failed').Count) { exit 1 }
        $yazi = Resolve-OrganizationCommand yazi
        if (-not $yazi) { Write-Host 'Yazi missing; upgrade does not install it.'; exit 0 }
        $ya = Join-Path (Split-Path $yazi) 'ya.exe'
        if (-not (Test-Path -LiteralPath $ya) -or (Test-OrganizationScoopPath $ya)) { throw 'A matched approved yazi/ya pair is required.' }
        $env:YAZI_CONFIG_HOME = Join-Path $HOME '.config\yazi'
        & $ya pkg upgrade
        exit $LASTEXITCODE
    }
    $only = if ($Action -eq 'Translate') { @('translate') } else { @() }
    $results = @(Invoke-OrganizationPackages -Upgrade -Only $only)
    $results | Format-Table -Wrap -AutoSize
    if (@($results | Where-Object Status -EQ 'failed').Count) { exit 1 }
    exit 0
}
# Legacy commands retain their existing owners and behavior.
switch ($Action) {
    { $_ -in 'All', 'Scoop' } { & scoop update; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; & scoop update '*'; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
}
switch ($Action) {
    { $_ -in 'All', 'Winget' } { & winget upgrade --all --accept-source-agreements --accept-package-agreements }
    'Translate' { & scoop update translate }
    'Yazi' { & scoop update yazi; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; $env:YAZI_CONFIG_HOME = Join-Path $HOME '.config\yazi'; & ya pkg upgrade }
    'Pia' { & chezmoi apply --refresh-externals }
}
exit $LASTEXITCODE
