#Requires -Version 7.4
#Requires -PSEdition Core
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are consumed by nested watcher helper functions.')]
param(
    [Parameter(Mandatory)] [int] $ProcessId,
    [Parameter(Mandatory)] [ValidateSet('proxy', 'shim')] [string] $Component,
    [Parameter(Mandatory)] [string] $LogPath,
    [string] $FallbackLogPath,
    [Parameter(Mandatory)] [string] $IntentPath,
    [string] $ReadyPath,
    [string] $Package,
    [string] $Version,
    [int] $Port,
    [string] $ModulePath,
    [string] $ProxyHealthUri,
    [string] $ShimHealthUri,
    [string] $ShimStatePath,
    [string] $StartedAt,
    [string] $StdoutPath,
    [string] $StderrPath,
    [int] $RecoveryAttempt = 0,
    [int[]] $RecoveryDelaySeconds = @(1, 5, 30)
)

$ErrorActionPreference = 'SilentlyContinue'

function Write-WatchEvent {
    param(
        [Parameter(Mandatory)] [string] $EventName,
        [Nullable[int]] $ExitCode,
        [string] $Detail,
        $CrashSummary,
        [Nullable[int]] $Attempt,
        [Nullable[int]] $UptimeSeconds
    )
    $row = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString('o')
        component = $Component
        event = $EventName
        pid = $ProcessId
        port = $Port
        package = $Package
        version = $Version
        exit_code = $ExitCode
        detail = $Detail
        crash_summary = $CrashSummary
        attempt = $Attempt
        uptime_seconds = $UptimeSeconds
    }
    $line = ($row | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine
    $written = $false
    for ($writeAttempt = 0; $writeAttempt -lt 10; $writeAttempt++) {
        try {
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $LogPath)) | Out-Null
            [System.IO.File]::AppendAllText($LogPath, $line, [System.Text.UTF8Encoding]::new($false))
            $written = $true
            break
        } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $written) {
        $fallback = if ([string]::IsNullOrWhiteSpace($FallbackLogPath)) { "$LogPath.fallback" } else { $FallbackLogPath }
        try {
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $fallback)) | Out-Null
            [System.IO.File]::AppendAllText($fallback, $line, [System.Text.UTF8Encoding]::new($false))
        } catch { $null = $_ }
    }
}

function Get-NativeCrashSummary {
    if ($Component -ne 'shim' -or [string]::IsNullOrWhiteSpace($StderrPath) -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
        return $null
    }
    try {
        $lines = @(
            Get-Content -LiteralPath $StderrPath -Tail 80 -ErrorAction Stop |
                ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() } |
                Where-Object { $_ -match '^(?:Bun v|Windows v|panic\(|oh no: Bun has crashed\.)' -or $_ -match '^https://bun\.report/' } |
                Select-Object -Last 8
        )
        if ($lines.Count -eq 0) { return $null }
        [pscustomobject]@{
            stream = 'stderr'
            generation = 0
            path = $StderrPath
            lines = $lines
        }
    } catch {
        [pscustomobject]@{
            stream = 'stderr'
            generation = 0
            path = $StderrPath
            lines = @("crash log read failed: $($_.Exception.Message -replace '\s+', ' ')")
        }
    }
}

function Test-WatchHealth {
    param([Parameter(Mandatory)] [string] $Uri, [switch] $RequireShimIdentity)
    if ([string]::IsNullOrWhiteSpace($Uri)) { return $false }
    try {
        $response = Invoke-RestMethod -Uri $Uri -TimeoutSec 2 -ErrorAction Stop
        if ($RequireShimIdentity) { return $response.ok -eq $true }
        return $true
    } catch { return $false }
}

function Test-ShimRecoveryEnabled {
    if ([string]::IsNullOrWhiteSpace($ShimStatePath) -or -not (Test-Path -LiteralPath $ShimStatePath)) { return $true }
    try { return (Get-Content -Raw -LiteralPath $ShimStatePath -ErrorAction Stop).Trim() -ne 'off' }
    catch { return $false }
}

$exitCode = $null
$observed = $false
try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $null = $process.Handle
    $observed = $true
    $process.WaitForExit()
    $process.Refresh()
    try { $exitCode = $process.ExitCode } catch { $exitCode = $null }
} catch { $null = $_ }

$deliberate = Test-Path -LiteralPath $IntentPath
if ($deliberate) { Remove-Item -LiteralPath $IntentPath -Force -ErrorAction SilentlyContinue }
$wasReady = -not [string]::IsNullOrWhiteSpace($ReadyPath) -and (Test-Path -LiteralPath $ReadyPath)
if ($wasReady) { Remove-Item -LiteralPath $ReadyPath -Force -ErrorAction SilentlyContinue }

$uptimeSeconds = 0
try {
    $started = [DateTime]::Parse($StartedAt).ToUniversalTime()
    $uptimeSeconds = [int][Math]::Max(0, ([DateTime]::UtcNow - $started).TotalSeconds)
} catch { $null = $_ }

$exitEvent = if ($deliberate) { 'deliberate_stop' } elseif ($observed) { 'unexpected_exit' } else { 'watch_failed' }
$crashSummary = if ($exitEvent -eq 'unexpected_exit') { Get-NativeCrashSummary } else { $null }
Write-WatchEvent -EventName $exitEvent -ExitCode $exitCode -CrashSummary $crashSummary -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds

if ($deliberate -or -not $observed -or $Component -ne 'shim') { return }
if (-not $wasReady) {
    Write-WatchEvent -EventName 'restart_suppressed' -Detail 'process never reached ready state' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}
if (-not (Test-ShimRecoveryEnabled)) {
    Write-WatchEvent -EventName 'restart_suppressed' -Detail 'shim is disabled' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}
$backendVersion = $null
if (-not [version]::TryParse($Version, [ref]$backendVersion) -or $backendVersion -ge [version]'2.5.2') {
    Write-WatchEvent -EventName 'recovery_required' -Detail 'backend may retain work after shim exit; inspect active work and use a controlled copilot-proxy restart of both processes; automatic shim-only recovery is disabled' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}
if (Test-WatchHealth -Uri $ShimHealthUri -RequireShimIdentity) {
    Write-WatchEvent -EventName 'restart_suppressed' -Detail 'shim is already healthy' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}
if (-not (Test-WatchHealth -Uri $ProxyHealthUri)) {
    Write-WatchEvent -EventName 'restart_suppressed' -Detail 'proxy is not healthy' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}
if ([string]::IsNullOrWhiteSpace($ModulePath) -or -not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
    Write-WatchEvent -EventName 'restart_suppressed' -Detail 'Copilot module is unavailable' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}

$nextAttempt = if ($uptimeSeconds -ge 300) { 1 } else { $RecoveryAttempt + 1 }
if ($nextAttempt -gt 3) {
    Write-WatchEvent -EventName 'restart_exhausted' -Detail 'three quick-failure attempts consumed' -Attempt $RecoveryAttempt -UptimeSeconds $uptimeSeconds
    return
}

for ($attempt = $nextAttempt; $attempt -le 3; $attempt++) {
    $delayIndex = [Math]::Min($attempt - 1, $RecoveryDelaySeconds.Count - 1)
    $delay = if ($delayIndex -ge 0) { [Math]::Max(0, $RecoveryDelaySeconds[$delayIndex]) } else { 0 }
    Write-WatchEvent -EventName 'restart_scheduled' -Detail "delay=${delay}s" -Attempt $attempt -UptimeSeconds $uptimeSeconds
    if ($delay -gt 0) { Start-Sleep -Seconds $delay }

    if (-not (Test-ShimRecoveryEnabled)) {
        Write-WatchEvent -EventName 'restart_suppressed' -Detail 'shim was disabled during backoff' -Attempt $attempt -UptimeSeconds $uptimeSeconds
        return
    }
    if (Test-WatchHealth -Uri $ShimHealthUri -RequireShimIdentity) {
        Write-WatchEvent -EventName 'restart_succeeded' -Detail 'shim became healthy during backoff' -Attempt $attempt -UptimeSeconds $uptimeSeconds
        return
    }
    if (-not (Test-WatchHealth -Uri $ProxyHealthUri)) {
        Write-WatchEvent -EventName 'restart_suppressed' -Detail 'proxy became unhealthy during backoff' -Attempt $attempt -UptimeSeconds $uptimeSeconds
        return
    }

    try {
        Import-Module $ModulePath -Force -DisableNameChecking -ErrorAction Stop
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            $recoveryArgs = @('shim', 'recover', '--attempt', [string]$attempt)
            copilot-proxy @recoveryArgs
        } finally { $ErrorActionPreference = $savedPreference }
    } catch {
        Write-WatchEvent -EventName 'restart_failed' -Detail ([string]$_.Exception.Message) -Attempt $attempt -UptimeSeconds $uptimeSeconds
        continue
    }

    if (Test-WatchHealth -Uri $ShimHealthUri -RequireShimIdentity) {
        Write-WatchEvent -EventName 'restart_succeeded' -Detail 'shim health restored' -Attempt $attempt -UptimeSeconds $uptimeSeconds
        return
    }
    Write-WatchEvent -EventName 'restart_failed' -Detail 'recovery command returned without shim health' -Attempt $attempt -UptimeSeconds $uptimeSeconds
}

Write-WatchEvent -EventName 'restart_exhausted' -Detail 'three recovery attempts failed' -Attempt 3 -UptimeSeconds $uptimeSeconds
