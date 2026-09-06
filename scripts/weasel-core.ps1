# Shared Weasel installation discovery for package install and Rime redeploy.
# Probe both registry views explicitly: Weasel is a 32-bit NSIS package on many
# x64 hosts, so the PowerShell provider's process-default view can miss it.
function Get-WeaselRegistryMetadata {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Win32.RegistryView] $View
    )

    $baseKey = $null
    $weaselKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $View
        )
        $weaselKey = $baseKey.OpenSubKey('SOFTWARE\Rime\Weasel')
        if (-not $weaselKey) { return $null }

        [pscustomobject]@{
            RegistryView = $View
            WeaselRoot   = [string] $weaselKey.GetValue('WeaselRoot', $null)
            InstallDir   = [string] $weaselKey.GetValue('InstallDir', $null)
        }
    } catch {
        return $null
    } finally {
        if ($weaselKey) { $weaselKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Resolve-WeaselInstallation {
    foreach ($view in [Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32) {
        $metadata = Get-WeaselRegistryMetadata -View $view
        if (-not $metadata) { continue }

        $roots = @(
            if (-not [string]::IsNullOrWhiteSpace($metadata.WeaselRoot)) { $metadata.WeaselRoot }
            if ([string]::IsNullOrWhiteSpace($metadata.WeaselRoot) -and
                -not [string]::IsNullOrWhiteSpace($metadata.InstallDir)) { $metadata.InstallDir }
        )
        foreach ($root in $roots) {
            $setupPath = Join-Path $root 'WeaselSetup.exe'
            $deployerPath = Join-Path $root 'WeaselDeployer.exe'
            if ((Test-Path -LiteralPath $setupPath -PathType Leaf) -and
                (Test-Path -LiteralPath $deployerPath -PathType Leaf)) {
                return [pscustomobject]@{
                    RegistryView = $metadata.RegistryView
                    Root         = $root
                    SetupPath    = $setupPath
                    DeployerPath = $deployerPath
                }
            }
        }
    }

    return $null
}
