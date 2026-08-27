param(
    [Parameter(Mandatory)] [int] $ProcessId,
    [Parameter(Mandatory)] [string] $Component,
    [Parameter(Mandatory)] [string] $LogPath,
    [Parameter(Mandatory)] [string] $IntentPath,
    [string] $Package,
    [string] $Version,
    [int] $Port
)

$ErrorActionPreference = 'SilentlyContinue'
$exitCode = $null
$observed = $false
try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $null = $process.Handle
    $observed = $true
    $process.WaitForExit()
    $process.Refresh()
    try { $exitCode = $process.ExitCode } catch { $exitCode = $null }
} catch {}

$deliberate = Test-Path -LiteralPath $IntentPath
if ($deliberate) { Remove-Item -LiteralPath $IntentPath -Force -ErrorAction SilentlyContinue }
$event = if ($deliberate) { 'deliberate_stop' } elseif ($observed) { 'unexpected_exit' } else { 'watch_failed' }
$row = [ordered]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    component = $Component
    event = $event
    pid = $ProcessId
    port = $Port
    package = $Package
    version = $Version
    exit_code = $exitCode
}

$directory = Split-Path -Parent $LogPath
[System.IO.Directory]::CreateDirectory($directory) | Out-Null
$line = ($row | ConvertTo-Json -Compress) + [Environment]::NewLine
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    try {
        [System.IO.File]::AppendAllText($LogPath, $line, [System.Text.UTF8Encoding]::new($false))
        break
    } catch { Start-Sleep -Milliseconds 100 }
}
