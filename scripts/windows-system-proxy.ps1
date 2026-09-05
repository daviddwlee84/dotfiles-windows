#Requires -Version 7.4
#Requires -PSEdition Core
# Native curl/Go do not read Windows Internet Settings, unlike Invoke-WebRequest.
# Bridge the user's existing static proxy for a bounded child command only.
function Get-WindowsSystemProxyVariables {
    $settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $values = @{}
    if (-not $settings -or $settings.ProxyEnable -ne 1 -or -not $settings.ProxyServer) { return $values }
    $server = [string]$settings.ProxyServer
    foreach ($scheme in @('http', 'https')) {
        $address = $server
        if ($server.Contains('=')) {
            $match = [regex]::Match($server, '(?:^|;)\s*' + $scheme + '=([^;]+)')
            if (-not $match.Success) { continue }
            $address = $match.Groups[1].Value
        }
        if ($address -notmatch '^[a-z]+://') { $address = 'http://' + $address }
        $uri = $null
        if ([uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
            $values[$scheme.ToUpperInvariant() + '_PROXY'] = $uri.AbsoluteUri
        }
    }
    # curl/Go support host suffix exclusions, but not arbitrary WinINET wildcards.
    # Keep only representable exclusions; <local> covers this command's loopbacks.
    $bypass = @('localhost', '127.0.0.1', '::1')
    foreach ($entry in ([string]$settings.ProxyOverride -split ';')) {
        $entry = $entry.Trim()
        if ($entry -match '^\*\.[a-zA-Z0-9.-]+$') { $bypass += $entry.Substring(1) }
        elseif ($entry -match '^[a-zA-Z0-9.:-]+$') { $bypass += $entry }
    }
    if ($values.Count) { $values.NO_PROXY = $bypass -join ',' }
    return $values
}

function Invoke-WithWindowsSystemProxy {
    param([Parameter(Mandatory)][scriptblock]$Command)
    # Explicit command/user proxy policy always wins, including ALL_PROXY.
    if ($env:HTTPS_PROXY -or $env:HTTP_PROXY -or $env:ALL_PROXY -or $env:NO_PROXY) {
        return (& $Command)
    }
    $values = Get-WindowsSystemProxyVariables
    $saved = @{}
    try {
        foreach ($name in $values.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process')
        }
        & $Command
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}
