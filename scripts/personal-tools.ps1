#Requires -Version 7.4
#Requires -PSEdition Core
# Shared selection/ownership policy for install-only apply and explicit upgrades.
# exp is deferred until its native Windows canonical-storage contract is complete.
function Get-PersonalTools {
    @(
        [pscustomobject]@{ Id = 'dev-cli'; Binary = 'dev-cli'; Manager = 'release'; VersionName = 'dev' }
        [pscustomobject]@{ Id = 'translate'; Binary = 'translate'; Manager = 'scoop'; VersionName = 'translate' }
        [pscustomobject]@{ Id = 'lazychezmoi'; Binary = 'lazychezmoi'; Manager = 'scoop'; VersionName = 'lazychezmoi' }
        [pscustomobject]@{ Id = 'lazyclash'; Binary = 'lazyclash'; Manager = 'scoop'; VersionName = 'lazyclash' }
        [pscustomobject]@{ Id = 'lazymlflow'; Binary = 'lazymlflow'; Manager = 'scoop'; VersionName = 'lazymlflow' }
        [pscustomobject]@{ Id = 'lazypueue'; Binary = 'lazypueue'; Manager = 'scoop'; VersionName = 'lazypueue' }
    )
}

function Get-SelectedPersonalTools {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    if ($Data.Contains('installPersonalTools')) {
        if ($Data['installPersonalTools'] -eq $true) { Get-PersonalTools }
        return
    }
    # Compatibility applies only while the new key is absent. An explicit false
    # must never be overridden by the old translation or Herdr selections.
    Get-PersonalTools | Where-Object {
        ($_.Id -eq 'dev-cli' -and $Data['installHerdr'] -eq $true) -or
        ($_.Id -eq 'translate' -and $Data['installTranslate'] -eq $true)
    }
}

function Get-PersonalScoopRoot {
    if ($env:SCOOP) { return [IO.Path]::GetFullPath($env:SCOOP) }
    Join-Path $HOME 'scoop'
}

function Get-PersonalToolOwner {
    param(
        [Parameter(Mandatory)]$Tool,
        [string]$ScoopRoot = (Get-PersonalScoopRoot),
        [string]$BinRoot = (Join-Path $HOME '.local\bin')
    )
    $candidate = if ($Tool.Manager -eq 'release') {
        Join-Path $BinRoot 'dev-cli.exe'
    } else {
        Join-Path $ScoopRoot "apps\$($Tool.Id)\current\$($Tool.Binary).exe"
    }
    $command = Get-Command $Tool.Binary -ListImported -ErrorAction SilentlyContinue
    $kind = 'missing'
    if ($Tool.Manager -eq 'release') {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $kind = 'release' }
        elseif ($command) { $kind = 'unmanaged' }
    } else {
        $receipt = Join-Path (Split-Path $candidate) 'install.json'
        if (Test-Path -LiteralPath $receipt -PathType Leaf) {
            try {
                $installed = Get-Content -LiteralPath $receipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($installed.bucket -eq 'daviddwlee84' -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $kind = 'scoop' }
                else { $kind = 'unmanaged' }
            } catch { $kind = 'unmanaged' }
        } elseif ($command) { $kind = 'unmanaged' }
        if ($kind -eq 'scoop' -and $command) {
            $shim = Join-Path $ScoopRoot "shims\$($Tool.Binary).exe"
            $allowed = @($candidate, $shim) | ForEach-Object { [IO.Path]::GetFullPath($_) }
            if (-not $command.Source -or [IO.Path]::GetFullPath($command.Source) -notin $allowed) { $kind = 'unmanaged' }
        }
    }
    [pscustomobject]@{ Kind = $kind; Path = $candidate; Id = $Tool.Id }
}

function Get-PersonalToolVersion {
    param([Parameter(Mandatory)]$Tool, [Parameter(Mandatory)][string]$Path)
    $output = @(& $Path --version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output.Trim() -notmatch ('^' + [regex]::Escape($Tool.VersionName) + ' version \S+$')) {
        throw "Could not verify $($Tool.Id) at its owned installation path"
    }
    $output.Trim()
}

function Install-SelectedPersonalTools {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $selected = @(Get-SelectedPersonalTools -Data $Data)
    if ($selected.Count -eq 0) { return }
    $bucketReady = $false
    foreach ($tool in $selected) {
        try {
            $owner = Get-PersonalToolOwner -Tool $tool
            if ($owner.Kind -eq 'unmanaged') {
                Write-Warning "$($tool.Id): existing installation is unmanaged or shadows the expected package; preserved."
                continue
            }
            if ($tool.Manager -eq 'release') { Install-DevCli; continue }
            if (-not $bucketReady) {
                $bucket = Join-Path (Get-PersonalScoopRoot) 'buckets\daviddwlee84'
                if (Test-Path -LiteralPath $bucket -PathType Container) {
                    $origin = @(& git -C $bucket remote get-url origin 2>$null) -join ''
                    if ($LASTEXITCODE -ne 0 -or $origin -notmatch '^(https://github\.com/|git@github\.com:)daviddwlee84/scoop-bucket(?:\.git)?/?$') {
                        throw 'Existing daviddwlee84 bucket has an unexpected source; it was not changed.'
                    }
                } else {
                    & scoop bucket add daviddwlee84 https://github.com/daviddwlee84/scoop-bucket
                    if ($LASTEXITCODE -ne 0) { throw 'Could not add the personal Scoop bucket' }
                }
                $bucketReady = $true
            }
            Scoop-Install @("daviddwlee84/$($tool.Id)")
            $after = Get-PersonalToolOwner -Tool $tool
            if ($after.Kind -eq 'scoop') { Write-Host (Get-PersonalToolVersion -Tool $tool -Path $after.Path) }
        } catch { Write-Warning $_; Register-Failure "personal:$($tool.Id)" }
    }
}

function Update-SelectedPersonalTools {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    foreach ($tool in @(Get-SelectedPersonalTools -Data $Data)) {
        $owner = Get-PersonalToolOwner -Tool $tool
        if ($owner.Kind -notin @('release', 'scoop')) {
            Write-Host "$($tool.Id): $($owner.Kind); skipping"
            [pscustomobject]@{ Tool = $tool.Id; Status = 'skipped'; Reason = $owner.Kind }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($owner.Path, "Upgrade $($tool.Id) through $($owner.Kind)")) { continue }
        try {
            $before = Get-PersonalToolVersion -Tool $tool -Path $owner.Path
            if ($owner.Kind -eq 'release') {
                Install-WindowsCliRelease -Name dev-cli -Upgrade
            } else {
                $output = @(& scoop update $tool.Id *>&1)
                $code = $LASTEXITCODE
                $output | Out-Host
                $plain = (($output -join "`n") -replace '\x1b\[[0-?]*[ -/]*[@-~]', '')
                if ($code -ne 0 -or $plain -match 'Running process detected|Close them and try again|(?:^|\s)ERROR[ :!]') { throw 'Scoop reported a failure or skipped an active process; inspect its output before retrying.' }
            }
            $afterOwner = Get-PersonalToolOwner -Tool $tool
            if ($afterOwner.Kind -ne $owner.Kind) { throw 'Installation ownership changed during upgrade' }
            $after = Get-PersonalToolVersion -Tool $tool -Path $afterOwner.Path
            Write-Host "$($tool.Id): $before -> $after"
            [pscustomobject]@{ Tool = $tool.Id; Status = $(if ($before -eq $after) { 'unchanged' } else { 'updated' }); Version = $after }
        } catch {
            Write-Warning "$($tool.Id): $_"
            [pscustomobject]@{ Tool = $tool.Id; Status = 'failed'; Reason = [string]$_ }
        }
    }
}
