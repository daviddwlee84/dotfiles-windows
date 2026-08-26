# pueue-bootstrap.ps1 — make the pueue client usable without a manual daemon
# terminal. Included into both the package installer and the PowerShell profile.

function Resolve-PueueCommand {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pueue', 'pueued')]
        [string]$Name
    )

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }

    # A first-time Scoop install can create the shim after this pwsh process
    # captured PATH. Resolve the stable `current` junction as a fallback.
    $scoop = Get-Command scoop -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $scoop) { return $null }

    $prefixOutput = @(& $scoop.Source prefix pueue 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $prefixOutput) { return $null }
    $prefix = ([string]$prefixOutput[-1]).Trim()
    $candidate = Join-Path $prefix "$Name.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
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
    param([AllowNull()][string]$ClientPath)

    if (-not $ClientPath) { $ClientPath = Resolve-PueueCommand -Name pueue }
    if (-not $ClientPath) { return $false }
    try {
        & $ClientPath status *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Wait-PueuedReady {
    param(
        [Parameter(Mandatory)][string]$ClientPath,
        [int]$TimeoutMilliseconds = 3000
    )

    $attempts = [Math]::Max(1, [Math]::Ceiling($TimeoutMilliseconds / 100))
    foreach ($attempt in 1..$attempts) {
        if (Test-PueuedReady -ClientPath $ClientPath) { return $true }
        if ($attempt -lt $attempts) { Start-Sleep -Milliseconds 100 }
    }
    return $false
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
                if ($LASTEXITCODE -ne 0 -and -not $Quiet) {
                    Write-Warning 'pueued service start failed; falling back to daemon mode'
                }
                if (Wait-PueuedReady -ClientPath $clientPath -TimeoutMilliseconds $ReadyTimeoutMilliseconds) {
                    return $true
                }
            }
        } catch {
            if (-not $Quiet) { Write-Warning "pueued service setup failed; falling back to daemon mode: $_" }
        }
    }

    if (-not $Quiet) { Write-Host '==> pueued: starting detached daemon' -ForegroundColor Cyan }
    try {
        if ($Quiet) { & $daemonPath --daemonize *> $null }
        else { & $daemonPath --daemonize 2>&1 | Out-Host }
        if ($LASTEXITCODE -ne 0) {
            if (-not $Quiet) { Write-Warning "pueued --daemonize failed (exit $LASTEXITCODE)" }
            return $false
        }
    } catch {
        if (-not $Quiet) { Write-Warning "pueued --daemonize failed: $_" }
        return $false
    }

    $ready = Wait-PueuedReady -ClientPath $clientPath -TimeoutMilliseconds $ReadyTimeoutMilliseconds
    if (-not $ready -and -not $Quiet) { Write-Warning 'pueued started but did not become ready' }
    return $ready
}
