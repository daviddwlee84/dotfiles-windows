#Requires -Version 7.4
#Requires -PSEdition Core
# pueue-bootstrap.ps1 — make the pueue client usable without a manual daemon
# terminal. Included into both the package installer and the PowerShell profile.

function Resolve-PueueCommand {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pueue', 'pueued')]
        [string]$Name,
        [switch]$ScoopOnly
    )

    # Resolve both executables from one Scoop `current` directory before PATH.
    # A legacy ~/bin or ~/.local/bin Pueue can otherwise shadow Scoop's shims and
    # mix a 3.x client/daemon with the installed 4.x package.
    $prefixes = [System.Collections.Generic.List[string]]::new()
    try {
        $scoop = Get-Command scoop -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandType -in @('Application', 'ExternalScript') } |
            Select-Object -First 1
        if ($scoop) {
            $scoopPath = if ($scoop.Path) { $scoop.Path } elseif ($scoop.Source) { $scoop.Source } else { $scoop.Name }
            $prefixOutput = @(& $scoopPath prefix pueue 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $prefix = @($prefixOutput | ForEach-Object { ([string]$_).Trim().Trim('"') } |
                    Where-Object { $_ }) | Select-Object -Last 1
                if ($prefix) { $prefixes.Add($prefix) }
            }
        }
    } catch {
        # Direct Scoop roots below still cover a stale PATH or failed prefix call.
        $null = $_
    }

    $scoopRoots = [System.Collections.Generic.List[string]]::new()
    if ($env:SCOOP) { $scoopRoots.Add($env:SCOOP) }
    if ($HOME) { $scoopRoots.Add((Join-Path $HOME 'scoop')) }
    if ($env:SCOOP_GLOBAL) { $scoopRoots.Add($env:SCOOP_GLOBAL) }
    if ($env:ProgramData) { $scoopRoots.Add((Join-Path $env:ProgramData 'scoop')) }
    foreach ($root in $scoopRoots) {
        $prefix = Join-Path $root 'apps\pueue\current'
        if ($prefix -notin $prefixes) { $prefixes.Add($prefix) }
    }

    foreach ($prefix in $prefixes) {
        $clientCandidate = Join-Path $prefix 'pueue.exe'
        $daemonCandidate = Join-Path $prefix 'pueued.exe'
        if ((Test-Path -LiteralPath $clientCandidate -PathType Leaf) -and
            (Test-Path -LiteralPath $daemonCandidate -PathType Leaf)) {
            if ($Name -eq 'pueue') { return $clientCandidate }
            return $daemonCandidate
        }
    }

    if ($ScoopOnly) { return $null }

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Test-PueueAdministrator {
    if (-not $IsWindows) { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-PueuedReady {
    param(
        [AllowNull()][string]$ClientPath,
        [int]$TimeoutMilliseconds = 500
    )

    if (-not $ClientPath) { $ClientPath = Resolve-PueueCommand -Name pueue }
    if (-not $ClientPath) { return $false }
    $process = $null
    try {
        $process = Start-Process -FilePath $ClientPath -ArgumentList 'status' -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit([Math]::Max(1, $TimeoutMilliseconds))) {
            try { $process.Kill($true) } catch { $null = $_ }
            return $false
        }
        return ($process.ExitCode -eq 0)
    } catch {
        return $false
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Wait-PueuedReady {
    param(
        [Parameter(Mandatory)][string]$ClientPath,
        [int]$TimeoutMilliseconds = 3000
    )

    $timeout = [Math]::Max(1, $TimeoutMilliseconds)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $timeout) {
        $remaining = $timeout - [int]$clock.ElapsedMilliseconds
        if (Test-PueuedReady -ClientPath $ClientPath -TimeoutMilliseconds ([Math]::Min(500, $remaining))) {
            return $true
        }
        $remaining = $timeout - [int]$clock.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
    }
    return (Test-PueuedReady -ClientPath $ClientPath -TimeoutMilliseconds 1)
}

function Start-PueuedIfNeeded {
    [CmdletBinding()]
    param(
        # The package installer opts into Pueue 4's built-in Windows service.
        # A normal shell never changes service state; it only uses daemon mode.
        [switch]$InstallService,
        [switch]$Quiet,
        [int]$ReadyTimeoutMilliseconds = 3000
    )

    # Resolve both names through the Scoop-first resolver before probing either
    # one. When Scoop's current pair exists, both paths share that directory even
    # if an older pair appears first on PATH or could not be removed.
    $clientPath = Resolve-PueueCommand -Name pueue
    $daemonPath = Resolve-PueueCommand -Name pueued
    if (-not $clientPath -or -not $daemonPath) {
        if (-not $Quiet) { Write-Warning 'pueue/pueued not found after installation' }
        return $false
    }

    if (Test-PueuedReady -ClientPath $clientPath) {
        if (-not $Quiet) { Write-Host '==> pueued already running' -ForegroundColor Cyan }
        return $true
    }

    if ($InstallService -and (Test-PueueAdministrator)) {
        try {
            $service = Get-Service -Name pueued -ErrorAction SilentlyContinue
            if (-not $service) {
                if (-not $Quiet) { Write-Host '==> pueued: installing built-in Windows service' -ForegroundColor Cyan }
                if ($Quiet) { & $daemonPath service install *> $null }
                else { & $daemonPath service install 2>&1 | Out-Host }
                if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
                    Write-Warning 'pueued service install failed; falling back to daemon mode'
                }
                $service = Get-Service -Name pueued -ErrorAction SilentlyContinue
            }

            if ($service) {
                if (-not $Quiet) { Write-Host '==> pueued: starting Windows service' -ForegroundColor Cyan }
                if ($Quiet) { & $daemonPath service start *> $null }
                else { & $daemonPath service start 2>&1 | Out-Host }
                $serviceStartExitCode = $LASTEXITCODE
                if ($serviceStartExitCode -ne 0) {
                    if (-not $Quiet) { Write-Warning 'pueued service start failed; falling back to daemon mode' }
                } elseif (Wait-PueuedReady -ClientPath $clientPath -TimeoutMilliseconds $ReadyTimeoutMilliseconds) {
                    return $true
                } else {
                    if (-not $Quiet) { Write-Warning 'pueued service started but did not become ready' }
                    return $false
                }
            }
        } catch {
            if (-not $Quiet) { Write-Warning "pueued service setup failed; falling back to daemon mode: $_" }
        }
    }

    if (-not $Quiet) { Write-Host '==> pueued: starting detached daemon' -ForegroundColor Cyan }
    try {
        # Pueue's daemonized child inherits stdio. PowerShell native redirection
        # therefore waits forever for pipe EOF even after the launcher exits.
        Start-Process -FilePath $daemonPath -ArgumentList '--daemonize' -WindowStyle Hidden
    } catch {
        if (-not $Quiet) { Write-Warning "pueued --daemonize failed: $_" }
        return $false
    }

    $ready = Wait-PueuedReady -ClientPath $clientPath -TimeoutMilliseconds $ReadyTimeoutMilliseconds
    if (-not $ready -and -not $Quiet) { Write-Warning 'pueued started but did not become ready' }
    return $ready
}
