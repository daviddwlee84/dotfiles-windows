# Shared Oh My Pi binary installer. The apply-time installer includes this file
# verbatim; scripts/upgrade-omp.ps1 dot-sources it for explicit upgrades.

$script:OmpInstallerUri = 'https://omp.sh/install.ps1'

function Get-OmpBinaryPath {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable' }
    Join-Path $env:LOCALAPPDATA 'omp\omp.exe'
}

function Add-ScoopGitBashToProcessPath {
    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
    $gitBin = Join-Path $scoopRoot 'apps\git\current\bin'
    $bash = Join-Path $gitBin 'bash.exe'
    if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { return }

    $pathEntries = @($env:PATH -split ';' | Where-Object { $_ })
    if ($pathEntries -notcontains $gitBin) { $env:PATH = "$gitBin;$env:PATH" }
}

function Get-OmpBinaryVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "OMP binary is missing: $Path"
    }
    $output = @(& $Path --version 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "OMP version probe exited $LASTEXITCODE" }
    $version = (($output | ForEach-Object { [string] $_ }) -join "`n").Trim()
    if (-not $version) { throw 'OMP version probe returned no output' }
    $version
}

function Get-OmpUserPathSnapshot {
    [CmdletBinding()]
    param()

    $snapshot = [ordered]@{
        ProcessPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
        Exists = $false
        Value = $null
        Kind = $null
    }
    if (-not $IsWindows) { return [pscustomobject] $snapshot }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if (-not $key) { throw 'HKCU\Environment is unavailable for PATH snapshot' }
    try {
        $snapshot.Exists = $key.GetValueNames() -contains 'Path'
        if ($snapshot.Exists) {
            $snapshot.Value = [string] $key.GetValue(
                'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            $snapshot.Kind = $key.GetValueKind('Path')
        }
    } finally {
        $key.Dispose()
    }
    [pscustomobject] $snapshot
}

function Send-OmpEnvironmentChangeNotification {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { return }
    if (-not ('OmpEnvironment.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace OmpEnvironment {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint message, UIntPtr wParam, string lParam,
            uint flags, uint timeout, out UIntPtr result);
    }
}
'@
    }
    $result = [UIntPtr]::Zero
    [void] [OmpEnvironment.NativeMethods]::SendMessageTimeout(
        [IntPtr] 0xffff, 0x001a, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref] $result
    )
}

function Restore-OmpUserPathSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Snapshot)

    [Environment]::SetEnvironmentVariable('Path', $Snapshot.ProcessPath, 'Process')
    if (-not $IsWindows) { return }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { throw 'HKCU\Environment is unavailable for PATH restore' }
    try {
        if ($Snapshot.Exists) {
            $key.SetValue('Path', $Snapshot.Value, $Snapshot.Kind)
        } else {
            $key.DeleteValue('Path', $false)
        }
    } finally {
        $key.Dispose()
    }
    Send-OmpEnvironmentChangeNotification
}

function Invoke-OmpOfficialBinaryInstaller {
    [CmdletBinding()]
    param([string] $InstallerUri = $script:OmpInstallerUri)

    $source = @(Invoke-RestMethod -Uri $InstallerUri -TimeoutSec 60 -ErrorAction Stop)
    if (-not $source) { throw "OMP installer returned no content: $InstallerUri" }
    $installer = [scriptblock]::Create(($source -join "`n"))
    # Force the official prebuilt binary path. The default installer mode picks
    # Bun when available, which would move ownership into a mutable global npm
    # prefix and make upgrades diverge from this repo's contract.
    $installDirectory = Split-Path -Parent (Get-OmpBinaryPath)
    $savedInstallDirectory = $env:PI_INSTALL_DIR
    $pathSnapshot = Get-OmpUserPathSnapshot
    try {
        $env:PI_INSTALL_DIR = $installDirectory
        & $installer -Binary
    } finally {
        if ($null -eq $savedInstallDirectory) {
            Remove-Item Env:PI_INSTALL_DIR -ErrorAction SilentlyContinue
        } else {
            $env:PI_INSTALL_DIR = $savedInstallDirectory
        }
        Restore-OmpUserPathSnapshot -Snapshot $pathSnapshot
    }
}

function Install-OmpBinary {
    [CmdletBinding()]
    param([switch] $Force)

    $binary = Get-OmpBinaryPath
    if (-not $Force) {
        try {
            $version = Get-OmpBinaryVersion -Path $binary
            Write-Host "==> OMP already installed: $version"
            return $true
        } catch {
            if (Test-Path -LiteralPath $binary) {
                Write-Warning "Existing OMP binary failed verification; reinstalling: $_"
            }
        }
    }

    $backup = $null
    $backupCandidate = $null
    $retainBackup = $false
    $hadOwnedBinary = Test-Path -LiteralPath $binary -PathType Leaf
    try {
        if ($hadOwnedBinary) {
            $backupCandidate = "$binary.pia-backup-$([guid]::NewGuid().ToString('N'))"
            Copy-Item -LiteralPath $binary -Destination $backupCandidate -Force -ErrorAction Stop
            $backup = $backupCandidate
        }
        # The upstream installer records shellPath by searching PATH. Scoop Git's
        # bash.exe is not shimmed, so expose its real bin directory before invoking
        # the installer. profile.d/00_env.ps1 repeats this for future sessions.
        Add-ScoopGitBashToProcessPath
        Write-Host '==> installing OMP with the official binary installer'
        Invoke-OmpOfficialBinaryInstaller

        # Verify the owned path, never an unrelated `omp` earlier on PATH.
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
            throw "official installer did not create $binary"
        }
        $version = Get-OmpBinaryVersion -Path $binary
        Write-Host "==> OMP verified: $version"
        $true
    } catch {
        $installFailure = $_
        try {
            if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                Move-Item -LiteralPath $backup -Destination $binary -Force -ErrorAction Stop
            } elseif (-not $hadOwnedBinary -and (Test-Path -LiteralPath $binary)) {
                Remove-Item -LiteralPath $binary -Force -ErrorAction Stop
            }
        } catch {
            if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                $retainBackup = $true
                Write-Warning "OMP rollback failed: $_; recovery copy retained at $backup"
            } else {
                Write-Warning "OMP rollback failed: $_"
            }
        }
        Write-Warning "OMP install or verification failed: $installFailure"
        $false
    } finally {
        if ($backup -and -not $retainBackup) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        if ($backupCandidate -and $backupCandidate -ne $backup) {
            Remove-Item -LiteralPath $backupCandidate -Force -ErrorAction SilentlyContinue
        }
    }
}
