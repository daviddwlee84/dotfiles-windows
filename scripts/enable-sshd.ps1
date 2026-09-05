#Requires -Version 7.4
#Requires -PSEdition Core
# enable-sshd.ps1 — verify or safely enable Microsoft OpenSSH Server.
#
# This file is both a standalone recovery command (`just enable-sshd`) and the
# body embedded by run_onchange_after_40_openssh_server.ps1.tmpl. Keep setup in
# functions: Pester dot-sources this file and must not change the machine.
#
# WARNING: setup enables an inbound TCP 22 listener. It never opens Public
# networks, changes the network category, removes an SSH installation, or edits
# authorized keys. Unexpected failures are warnings so chezmoi apply stays alive.
param(
    [switch]$CheckOnly,
    [switch]$Elevated,
    [switch]$RequireSuccess
)

$script:OpenSshRegistryPath = 'HKLM:\SOFTWARE\OpenSSH'
$script:OpenSshCapabilityName = 'OpenSSH.Server~~~~0.0.1.0'
$script:OpenSshFirewallRuleBaseName = 'Dotfiles-OpenSSH-Server-In-TCP'
$script:OpenSshRecoveryCommand = 'just enable-sshd'

function Info($Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    } catch {
        return $false
    }
}

function Test-SshSession {
    return [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY)
}

function Join-WindowsPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Child
    )

    return $Root.TrimEnd([char[]]'\/') + '\' + $Child.TrimStart([char[]]'\/')
}

function Test-ScoopShimPath {
    param([Parameter(Mandatory)][string]$Path)

    # A custom SCOOP root need not contain a directory literally named "scoop".
    # Scoop's pwsh shim is still always under a shims directory.
    return $Path -match '(?i)[\\/]shims[\\/]pwsh(?:\.exe)?$'
}

function Invoke-NativeExecutable {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    try {
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            Output   = $_.Exception.Message
        }
    }
}

function Get-PwshRuntimeInfo {
    param([Parameter(Mandatory)][string]$Path)

    $probe = Invoke-NativeExecutable -FilePath $Path -ArgumentList @(
        '-NoProfile', '-NoLogo', '-NonInteractive', '-Command',
        '$PSVersionTable.PSEdition + ''|'' + $PSVersionTable.PSVersion.ToString()'
    )
    if ($probe.ExitCode -ne 0) { return $null }

    $line = @($probe.Output -split "`r?`n" | Where-Object { $_ -match '^.+\|\d+(?:\.\d+){1,3}$' }) |
        Select-Object -Last 1
    if (-not $line) { return $null }

    $parts = $line -split '\|', 2
    try { $version = [version]$parts[1] } catch { return $null }
    return [pscustomobject]@{
        Path    = $Path
        Edition = $parts[0]
        Version = $version
        Valid   = ($parts[0] -eq 'Core' -and $version.Major -ge 7)
    }
}

function Resolve-PwshExecutable {
    $candidates = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # HKLM DefaultShell applies to every SSH account, so prefer the machine-wide
    # MSI installation over a user-owned Scoop path when both are valid.
    if ($env:ProgramFiles) {
        $candidate = Join-WindowsPath -Root $env:ProgramFiles -Child 'PowerShell\7\pwsh.exe'
        if ($seen.Add($candidate)) {
            $candidates.Add([pscustomobject]@{ Path = $candidate; Source = 'MSI' })
        }
    }

    foreach ($scoopRoot in @($env:SCOOP, $(if ($HOME) { Join-WindowsPath -Root $HOME -Child 'scoop' }))) {
        if (-not $scoopRoot) { continue }
        $candidate = Join-WindowsPath -Root $scoopRoot -Child 'apps\pwsh\current\pwsh.exe'
        if ($seen.Add($candidate)) {
            $candidates.Add([pscustomobject]@{ Path = $candidate; Source = 'Scoop' })
        }
    }

    $pathCommand = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $pathCommand) {
        $pathCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($pathCommand) {
        $candidate = if ($pathCommand.Source) { $pathCommand.Source } else { $pathCommand.Path }
        if ($candidate -and $seen.Add($candidate)) {
            $candidates.Add([pscustomobject]@{ Path = $candidate; Source = 'PATH' })
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-ScoopShimPath -Path $candidate.Path) { continue }
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
        $runtime = Get-PwshRuntimeInfo -Path $candidate.Path
        if ($runtime -and $runtime.Valid) {
            return [pscustomobject]@{
                Path    = $candidate.Path
                Source     = $candidate.Source
                Edition    = $runtime.Edition
                Version    = $runtime.Version
                UserScoped = ($candidate.Source -eq 'Scoop')
            }
        }
    }

    return $null
}

function ConvertFrom-SshdServiceCommandLine {
    param([AllowNull()][string]$PathName)

    if (-not $PathName) {
        return [pscustomobject]@{ ExecutablePath = $null; ConfigPath = $null; Arguments = '' }
    }

    $executablePath = $null
    $arguments = ''
    if ($PathName -match '^\s*"([^"]+\.exe)"') {
        $executablePath = $Matches[1]
        $arguments = $PathName.Substring($Matches[0].Length).Trim()
    } elseif ($PathName -match '^\s*(.+?\.exe)(?:\s|$)') {
        $executablePath = $Matches[1].Trim()
        $arguments = $PathName.Substring($Matches[0].Length).Trim()
    }

    $configPath = $null
    if ($arguments -match '(?i)(?:^|\s)-f\s+(?:"([^"]+)"|''([^'']+)''|(\S+))') {
        $configPath = @($Matches[1], $Matches[2], $Matches[3]) |
            Where-Object { $_ } | Select-Object -First 1
    } elseif ($arguments -match '(?i)(?:^|\s)-f(?:"([^"]+)"|''([^'']+)''|(\S+))') {
        # OpenSSH getopt accepts attached -fPATH. For -f=PATH the leading '=' is
        # part of optarg and must not be silently stripped.
        $configPath = @($Matches[1], $Matches[2], $Matches[3]) |
            Where-Object { $_ } | Select-Object -First 1
    }
    return [pscustomobject]@{
        ExecutablePath = $executablePath
        ConfigPath     = $configPath
        Arguments      = $arguments
    }
}

function ConvertFrom-ServiceBinaryPath {
    param([AllowNull()][string]$PathName)
    return (ConvertFrom-SshdServiceCommandLine -PathName $PathName).ExecutablePath
}

function Get-SshdServiceInfo {
    try {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction Stop |
            Select-Object -First 1
        if (-not $service) {
            return [pscustomobject]@{
                Exists = $false; Status = 'Missing'; StartType = 'Missing'
                PathName = $null; ProcessId = 0
            }
        }
        $startType = switch ($service.StartMode.ToString()) {
            'Auto' { 'Automatic' }
            default { $service.StartMode.ToString() }
        }
        return [pscustomobject]@{
            Exists    = $true
            Status    = $service.State.ToString()
            StartType = $startType
            PathName  = $service.PathName
            ProcessId = [uint32]$service.ProcessId
        }
    } catch {
        # Get-Service is enough for diagnostics, but deliberately cannot prove
        # executable identity or listener ownership without Win32_Service data.
        try {
            $service = Get-Service -Name sshd -ErrorAction Stop
            $startType = if ($service.PSObject.Properties.Name -contains 'StartType') {
                $service.StartType.ToString()
            } else {
                'Unknown'
            }
            return [pscustomobject]@{
                Exists    = $true
                Status    = $service.Status.ToString()
                StartType = $startType
                PathName  = $null
                ProcessId = 0
            }
        } catch {
            return [pscustomobject]@{
                Exists = $false; Status = 'Missing'; StartType = 'Missing'
                PathName = $null; ProcessId = 0
            }
        }
    }
}

function Get-SshdExecutableInfo {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $versionInfo = $item.VersionInfo
    } catch {
        return [pscustomobject]@{
            Path = $Path; ProductName = $null; CompanyName = $null
            ProductVersion = $null; AuthenticodeStatus = 'Unavailable'
            SignerSubject = $null; IsMicrosoftOpenSsh = $false
        }
    }

    $productName = [string]$versionInfo.ProductName
    $companyName = [string]$versionInfo.CompanyName
    $isOpenSshForWindows = $productName -match '(?i)^OpenSSH[ _]+for[ _]+Windows$'
    $companyIsMicrosoft = $companyName -match '(?i)^Microsoft(?: Corporation)?$'
    $authenticodeStatus = 'NotChecked'
    $signerSubject = $null
    $signatureIsMicrosoft = $false
    if ($isOpenSshForWindows -and -not $companyIsMicrosoft) {
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $authenticodeStatus = $signature.Status.ToString()
            if ($signature.SignerCertificate) {
                $signerSubject = [string]$signature.SignerCertificate.Subject
            }
            $signatureIsMicrosoft = $authenticodeStatus -eq 'Valid' -and
                $signerSubject -match '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)'
        } catch {
            $authenticodeStatus = 'Unavailable'
        }
    }

    return [pscustomobject]@{
        Path                   = $Path
        ProductName            = $productName
        CompanyName            = $companyName
        ProductVersion         = [string]$versionInfo.ProductVersion
        AuthenticodeStatus     = $authenticodeStatus
        SignerSubject          = $signerSubject
        IsMicrosoftOpenSsh     = [bool]($isOpenSshForWindows -and
            ($companyIsMicrosoft -or $signatureIsMicrosoft))
    }
}

function Get-SshdInstallation {
    $service = Get-SshdServiceInfo
    $serviceCommand = ConvertFrom-SshdServiceCommandLine -PathName $service.PathName
    $servicePath = $serviceCommand.ExecutablePath
    $knownPaths = [System.Collections.Generic.List[string]]::new()
    if ($servicePath) { $knownPaths.Add($servicePath) }
    if ($env:ProgramFiles) {
        $knownPaths.Add((Join-WindowsPath -Root $env:ProgramFiles -Child 'OpenSSH\sshd.exe'))
    }
    if ($env:SystemRoot) {
        $knownPaths.Add((Join-WindowsPath -Root $env:SystemRoot -Child 'System32\OpenSSH\sshd.exe'))
    }

    $existingPaths = @($knownPaths | Select-Object -Unique | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    })
    $servicePathExists = [bool]($servicePath -and ($existingPaths -contains $servicePath))
    $executableInfo = if ($servicePathExists) {
        Get-SshdExecutableInfo -Path $servicePath
    } else {
        $null
    }
    # A known OpenSSH file beside an unidentifiable/Cygwin service is evidence of
    # an existing source, never proof that the service uses that file.
    $executablePath = if ($service.Exists) {
        $servicePath
    } else {
        $existingPaths | Select-Object -First 1
    }
    $source = if (-not $executablePath) {
        'Missing'
    } elseif ($env:SystemRoot -and $executablePath.StartsWith(
        (Join-WindowsPath -Root $env:SystemRoot -Child 'System32\OpenSSH'),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        'WindowsCapability'
    } else {
        'ExistingMicrosoftOpenSSH'
    }
    $usable = [bool]($service.Exists -and $servicePathExists -and
        $executableInfo -and $executableInfo.IsMicrosoftOpenSsh)

    return [pscustomobject]@{
        Service                    = $service
        ExecutablePath             = $executablePath
        ConfigPath                 = $serviceCommand.ConfigPath
        Source                     = $source
        ProductName                = if ($executableInfo) { $executableInfo.ProductName } else { $null }
        ProductVersion             = if ($executableInfo) { $executableInfo.ProductVersion } else { $null }
        AuthenticodeStatus         = if ($executableInfo) { $executableInfo.AuthenticodeStatus } else { $null }
        SignerSubject              = if ($executableInfo) { $executableInfo.SignerSubject } else { $null }
        ExistingSourcePresent      = [bool]($service.Exists -or $existingPaths.Count -gt 0)
        UsableExisting             = $usable
        FreshCapabilityInstalled   = $false
    }
}

function Get-OpenSshCapabilityInfo {
    $capability = $null
    $useFallback = $false
    try {
        $capability = Get-WindowsCapability -Online -Name $script:OpenSshCapabilityName `
            -ErrorAction Stop | Select-Object -First 1
        if (-not $capability) { $useFallback = $true }
    } catch [System.Management.Automation.ParameterBindingException] {
        # Older DISM cmdlet surfaces may not expose -Name. Enumerate only then.
        $useFallback = $true
    } catch {
        return [pscustomobject]@{
            Name = $null; State = 'Unavailable'; Error = $_.Exception.Message
        }
    }

    if ($useFallback) {
        try {
            $capability = Get-WindowsCapability -Online -ErrorAction Stop |
                Where-Object { $_.Name -eq $script:OpenSshCapabilityName } |
                Select-Object -First 1
        } catch {
            return [pscustomobject]@{
                Name = $null; State = 'Unavailable'; Error = $_.Exception.Message
            }
        }
    }
    if (-not $capability) {
        return [pscustomobject]@{
            Name = $null; State = 'Unavailable'; Error = 'Exact OpenSSH.Server capability is not offered.'
        }
    }
    return [pscustomobject]@{
        Name  = $capability.Name
        State = $capability.State.ToString()
        Error = $null
    }
}

function Get-OpenSshInstallDecision {
    param(
        [Parameter(Mandatory)]$Installation,
        [Parameter(Mandatory)]$Capability
    )

    if ($Installation.UsableExisting) { return 'UseExisting' }
    if ($Installation.ExistingSourcePresent) { return 'RepairExisting' }
    if ($Capability.State -eq 'NotPresent') { return 'InstallCapability' }
    if ($Capability.State -eq 'Installed') { return 'RepairCapability' }
    return 'CapabilityUnavailable'
}

function Install-OpenSshCapability {
    param([Parameter(Mandatory)][string]$Name)

    Info "Installing Windows capability $Name"
    Add-WindowsCapability -Online -Name $Name -ErrorAction Stop | Out-Null
}

function Ensure-OpenSshSource {
    param(
        [Parameter(Mandatory)]$Installation,
        [Parameter(Mandatory)]$Capability,
        [System.Collections.Generic.List[string]]$Changes
    )

    $decision = Get-OpenSshInstallDecision -Installation $Installation -Capability $Capability
    switch ($decision) {
        'UseExisting' {
            if ($Installation.PSObject.Properties.Name -notcontains 'FreshCapabilityInstalled') {
                $Installation | Add-Member -NotePropertyName FreshCapabilityInstalled -NotePropertyValue $false
            }
            Info "Preserving existing OpenSSH server at $($Installation.ExecutablePath) (capability state: $($Capability.State))"
            return $Installation
        }
        'InstallCapability' {
            if (-not $Capability.Name) { throw 'OpenSSH.Server capability has no installable name.' }
            Install-OpenSshCapability -Name $Capability.Name
            $Changes.Add("Installed Windows capability $($Capability.Name)")
            $installed = Get-SshdInstallation
            if (-not $installed.UsableExisting) {
                throw 'OpenSSH.Server capability installation completed but no usable sshd service/executable was found.'
            }
            if ($installed.PSObject.Properties.Name -contains 'FreshCapabilityInstalled') {
                $installed.FreshCapabilityInstalled = $true
            } else {
                $installed | Add-Member -NotePropertyName FreshCapabilityInstalled -NotePropertyValue $true
            }
            return $installed
        }
        'RepairExisting' {
            throw 'An existing OpenSSH executable or sshd service is incomplete. Refusing to install a competing Windows capability; repair the existing Microsoft OpenSSH installation, then re-run.'
        }
        'RepairCapability' {
            throw 'OpenSSH.Server capability reports Installed but its sshd service/executable is unusable. Repair the capability, then re-run.'
        }
        default {
            throw "No usable OpenSSH server is present and the Windows capability is unavailable: $($Capability.Error)"
        }
    }
}

function Get-SshdConfigPath {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    return Join-WindowsPath -Root $programData -Child 'ssh\sshd_config'
}

function Resolve-SshdConfigPath {
    param([Parameter(Mandatory)]$Installation)

    if ($Installation.ConfigPath) { return $Installation.ConfigPath }
    return Get-SshdConfigPath
}

function Get-WindowsParentPath {
    param([Parameter(Mandatory)][string]$Path)

    $parent = $Path -replace '[\\/][^\\/]+$', ''
    if (-not $parent -or $parent -eq $Path) {
        throw "Cannot determine parent directory for: $Path"
    }
    return $parent
}

function Test-SshdHostKeyEvidence {
    param([Parameter(Mandatory)][string]$ConfigPath)

    try {
        $keyDirectory = Get-WindowsParentPath -Path $ConfigPath
        return [bool](Get-ChildItem -LiteralPath $keyDirectory -Filter 'ssh_host_*_key' `
            -File -ErrorAction Stop | Select-Object -First 1)
    } catch {
        return $false
    }
}

function Initialize-FreshOpenSshCapability {
    param(
        [Parameter(Mandatory)]$Installation,
        [Parameter(Mandatory)][string]$ConfigPath,
        [System.Collections.Generic.List[string]]$Changes
    )

    if (-not $Installation.FreshCapabilityInstalled) {
        throw 'Refusing pre-start sshd initialization for an existing installation.'
    }
    if (-not $Installation.Service.Exists) { throw 'Fresh OpenSSH capability has no sshd service.' }
    if (-not $Installation.ExecutablePath) { throw 'Fresh OpenSSH capability has no verified sshd executable.' }

    $binaryDirectory = Get-WindowsParentPath -Path $Installation.ExecutablePath
    $defaultConfig = Join-WindowsPath -Root $binaryDirectory -Child 'sshd_config_default'
    $keygenPath = Join-WindowsPath -Root $binaryDirectory -Child 'ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $defaultConfig -PathType Leaf)) {
        throw "Fresh OpenSSH capability is missing adjacent sshd_config_default: $defaultConfig"
    }
    if (-not (Test-Path -LiteralPath $keygenPath -PathType Leaf)) {
        throw "Fresh OpenSSH capability is missing adjacent ssh-keygen.exe: $keygenPath"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $configDirectory = Get-WindowsParentPath -Path $ConfigPath
        New-Item -ItemType Directory -Path $configDirectory -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $defaultConfig -Destination $ConfigPath -ErrorAction Stop
        $Changes.Add("Copied fresh OpenSSH default config to $ConfigPath")
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Fresh OpenSSH config copy was not readable: $ConfigPath"
    }

    Info 'Generating fresh OpenSSH host keys before exposing the sshd service'
    $keygen = Invoke-NativeExecutable -FilePath $keygenPath -ArgumentList @('-A')
    if ($keygen.ExitCode -ne 0) {
        throw "ssh-keygen -A failed with exit code $($keygen.ExitCode): $($keygen.Output)"
    }
    if (-not (Test-SshdHostKeyEvidence -ConfigPath $ConfigPath)) {
        throw 'ssh-keygen -A returned success but no private ssh_host_*_key evidence was found.'
    }
    $Changes.Add('Generated missing OpenSSH host keys before service start')
}

function Resolve-ValidatedSshdRuntime {
    param(
        [Parameter(Mandatory)]$Installation,
        [System.Collections.Generic.List[string]]$Changes
    )

    $configPath = Resolve-SshdConfigPath -Installation $Installation
    if ($Installation.FreshCapabilityInstalled) {
        Initialize-FreshOpenSshCapability -Installation $Installation `
            -ConfigPath $configPath -Changes $Changes
        $Installation = Get-SshdInstallation
        if (-not $Installation.UsableExisting) {
            throw 'Fresh OpenSSH capability became unusable after pre-start initialization.'
        }
        $configPath = Resolve-SshdConfigPath -Installation $Installation
    }
    if (-not (Test-SshdConfiguration `
        -SshdPath $Installation.ExecutablePath -ConfigPath $configPath)) {
        throw "sshd_config is invalid: $configPath"
    }
    return [pscustomobject]@{
        Installation = $Installation
        ConfigPath   = $configPath
    }
}

function Test-SshdConfiguration {
    param(
        [Parameter(Mandatory)][string]$SshdPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $SshdPath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $false }
    $probe = Invoke-NativeExecutable -FilePath $SshdPath -ArgumentList @('-t', '-f', $ConfigPath)
    if ($probe.ExitCode -ne 0 -and $probe.Output) {
        Write-Warning "sshd_config validation failed: $($probe.Output)"
    }
    return ($probe.ExitCode -eq 0)
}

function Wait-SshdServiceStatus {
    param(
        [Parameter(Mandatory)][string]$DesiredStatus,
        [int]$TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-SshdServiceInfo
        if ($service.Exists -and $service.Status -eq $DesiredStatus) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-SshdServiceRunning {
    param([int]$TimeoutSeconds = 15)
    return Wait-SshdServiceStatus -DesiredStatus Running -TimeoutSeconds $TimeoutSeconds
}

function Restore-SshdServiceState {
    param([Parameter(Mandatory)]$Snapshot)

    if (-not $Snapshot.Exists) { return }
    $current = Get-SshdServiceInfo
    if (-not $current.Exists) { throw 'Cannot restore sshd service state because the service disappeared.' }

    $wasRunning = $Snapshot.Status -eq 'Running'
    if (-not $wasRunning -and $current.Status -eq 'Running') {
        Stop-Service -Name sshd -Force -ErrorAction Stop
        if (-not (Wait-SshdServiceStatus -DesiredStatus Stopped)) {
            throw 'sshd did not stop while restoring its prior service state.'
        }
        $current = Get-SshdServiceInfo
    }
    if ($current.StartType -ne $Snapshot.StartType) {
        Set-Service -Name sshd -StartupType $Snapshot.StartType -ErrorAction Stop
    }
    if ($wasRunning) {
        $current = Get-SshdServiceInfo
        if ($current.Status -ne 'Running') {
            Start-Service -Name sshd -ErrorAction Stop
            if (-not (Wait-SshdServiceRunning)) {
                throw 'sshd did not return to its originally Running state during rollback.'
            }
        }
    }

    $readback = Get-SshdServiceInfo
    $statusMatches = if ($wasRunning) {
        $readback.Status -eq 'Running'
    } else {
        $readback.Status -eq $Snapshot.Status
    }
    if (-not $readback.Exists -or -not $statusMatches -or
        $readback.StartType -ne $Snapshot.StartType) {
        throw 'sshd service rollback readback did not match its prior status and startup type.'
    }
}

function Test-Tcp22Listener {
    param([uint32]$SshdProcessId)

    if (-not $SshdProcessId) { return $false }
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    } catch {
        throw "TCP listener inspection failed: $($_.Exception.Message)"
    }
    return [bool]($listeners | Where-Object {
        [int]$_.LocalPort -eq 22 -and [uint32]$_.OwningProcess -eq $SshdProcessId
    } | Select-Object -First 1)
}

function Wait-Tcp22Listener {
    param([int]$TimeoutSeconds = 15)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-SshdServiceInfo
        if ($service.Status -eq 'Running' -and
            (Test-Tcp22Listener -SshdProcessId $service.ProcessId)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Ensure-SshdService {
    param(
        [Parameter(Mandatory)]$Service,
        [Parameter(Mandatory)][bool]$ConfigurationValid,
        [System.Collections.Generic.List[string]]$Changes
    )

    if (-not $ConfigurationValid) {
        throw 'Refusing to start or restart sshd because sshd_config validation failed.'
    }
    if (-not $Service.Exists) { throw 'The sshd service does not exist.' }

    if ($Service.StartType -ne 'Automatic') {
        Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
        $Changes.Add('Set sshd startup type to Automatic')
    }
    if ($Service.Status -ne 'Running') {
        Start-Service -Name sshd -ErrorAction Stop
        $Changes.Add('Started sshd service')
    }
    if (-not (Wait-SshdServiceRunning)) {
        throw 'sshd did not reach the Running state.'
    }
    if (Wait-Tcp22Listener) { return }

    if (Test-SshSession) {
        throw 'TCP 22 is not reported as listening. Refusing to restart sshd from an active SSH session.'
    }

    Info 'sshd is running without a TCP 22 listener — restarting once after successful config validation'
    Restart-Service -Name sshd -Force -ErrorAction Stop
    $Changes.Add('Restarted sshd to recover its TCP 22 listener')
    if (-not (Wait-SshdServiceRunning)) { throw 'sshd did not return to Running after restart.' }
    if (-not (Wait-Tcp22Listener)) { throw 'sshd is Running but TCP 22 is not listening.' }
}

function ConvertTo-TokenList {
    param($Value)

    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($token in ($item.ToString() -split '\s*,\s*')) {
            if ($token) { $tokens.Add($token.Trim()) }
        }
    }
    return @($tokens)
}

function Test-EnabledValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    return ($Value -eq $true -or $Value.ToString() -match '^(?i:true|1)$')
}

function Test-Port22Overlap {
    param($LocalPort)

    foreach ($token in @(ConvertTo-TokenList $LocalPort)) {
        if ($token -eq 'Any' -or $token -eq '22') { return $true }
        if ($token -match '^(\d+)-(\d+)$' -and
            [int]$Matches[1] -le 22 -and [int]$Matches[2] -ge 22) {
            return $true
        }
    }
    return $false
}

function Get-FirewallRuleEvaluation {
    param(
        [Parameter(Mandatory)]$Rule,
        [AllowNull()][string]$SelectedSshdPath,
        [string]$ServiceName = 'sshd'
    )

    $profiles = @(ConvertTo-TokenList $Rule.Profile)
    $protocols = @(ConvertTo-TokenList $Rule.Protocol)
    $ports = @(ConvertTo-TokenList $Rule.LocalPort)
    $remoteAddresses = @(ConvertTo-TokenList $Rule.RemoteAddress)
    $programs = @(ConvertTo-TokenList $Rule.Program)
    $services = @(ConvertTo-TokenList $Rule.Service)
    $interfaces = @(ConvertTo-TokenList $Rule.InterfaceAlias)
    $problems = [System.Collections.Generic.List[string]]::new()

    $enabled = Test-EnabledValue $Rule.Enabled
    $inbound = $Rule.Direction.ToString() -eq 'Inbound'
    $allow = $Rule.Action.ToString() -eq 'Allow'
    $block = $Rule.Action.ToString() -eq 'Block'
    $tcp = [bool]($protocols | Where-Object { $_ -eq 'TCP' -or $_ -eq '6' })
    $tcpOverlap = [bool]($protocols | Where-Object { $_ -in @('TCP', '6', 'Any') })
    $port22 = [bool]($ports | Where-Object { $_ -eq '22' })
    $port22Overlap = Test-Port22Overlap $Rule.LocalPort
    $supportedProfile = [bool]($profiles | Where-Object { $_ -in @('Domain', 'Private', 'Any') })
    $opensPublic = [bool]($profiles | Where-Object { $_ -in @('Public', 'Any') })

    $scopeKnown = Test-EnabledValue $Rule.ScopeKnown
    $expandedSshdPath = if ($SelectedSshdPath) {
        [Environment]::ExpandEnvironmentVariables($SelectedSshdPath).Trim('"')
    } else {
        $null
    }
    $programMatches = [bool]($programs | Where-Object {
        $_ -eq 'Any' -or ($expandedSshdPath -and
            [Environment]::ExpandEnvironmentVariables($_).Trim('"').Equals(
                $expandedSshdPath, [StringComparison]::OrdinalIgnoreCase
            ))
    })
    $packageGeneric = Test-FirewallPackageGeneric $Rule.Package
    $serviceMatches = [bool]($services | Where-Object {
        $_ -eq 'Any' -or $_.Equals($ServiceName, [StringComparison]::OrdinalIgnoreCase)
    })
    $interfaceGeneric = ($interfaces.Count -eq 1 -and $interfaces[0] -eq 'Any')
    $scopeMatches = $scopeKnown -and $programMatches -and $packageGeneric -and
        $serviceMatches -and $interfaceGeneric

    if (-not $enabled) { $problems.Add('disabled') }
    if (-not $inbound) { $problems.Add('not inbound') }
    if (-not $allow) { $problems.Add('not allow') }
    if (-not $tcp) { $problems.Add('not TCP') }
    if (-not $port22) { $problems.Add('not local port 22') }
    if (-not $supportedProfile) { $problems.Add('does not cover Domain or Private') }
    if ($opensPublic) { $problems.Add('includes Public profile') }
    if (-not $scopeKnown) { $problems.Add('application/service/interface filters are unknown') }
    if ($scopeKnown -and -not $programMatches) { $problems.Add('application filter does not target selected sshd') }
    if ($scopeKnown -and -not $packageGeneric) { $problems.Add('application filter is scoped to an AppX package') }
    if ($scopeKnown -and -not $serviceMatches) { $problems.Add('service filter does not target sshd') }
    if ($scopeKnown -and -not $interfaceGeneric) { $problems.Add('interface filter is scoped') }
    $remoteCompatible = [bool]($remoteAddresses | Where-Object { $_ -in @('Any', 'LocalSubnet') })
    if (-not $remoteCompatible) { $problems.Add('remote scope does not cover Any or LocalSubnet') }

    $compatible = $enabled -and $inbound -and $allow -and $tcp -and $port22 -and
        $supportedProfile -and -not $opensPublic -and $scopeMatches -and $remoteCompatible
    $localSubnetOnly = ($remoteAddresses.Count -eq 1 -and $remoteAddresses[0] -eq 'LocalSubnet')
    $overbroadReasons = [System.Collections.Generic.List[string]]::new()
    if (-not $localSubnetOnly) { $overbroadReasons.Add('remote scope is broader than LocalSubnet') }
    $safeProfiles = ($profiles.Count -gt 0 -and -not ($profiles | Where-Object {
        $_ -notin @('Domain', 'Private')
    }))
    $safe = $compatible -and $safeProfiles -and $localSubnetOnly

    # Unknown filters may affect sshd and therefore fail closed. A filter proven
    # to select another program/service or an AppX package cannot apply to sshd.
    $scopeCouldAffectSshd = -not $scopeKnown -or
        ($programMatches -and $packageGeneric -and $serviceMatches)
    $blockingConflict = $enabled -and $inbound -and $block -and $tcpOverlap -and $port22Overlap -and
        $supportedProfile -and $scopeCouldAffectSshd
    $publicExposure = $enabled -and $inbound -and $allow -and $tcpOverlap -and $port22Overlap -and
        $opensPublic -and $scopeCouldAffectSshd

    return [pscustomobject]@{
        Name             = $Rule.Name
        DisplayName      = $Rule.DisplayName
        Compatible       = $compatible
        Safe             = $safe
        Overbroad        = [bool]($compatible -and $overbroadReasons.Count -gt 0)
        PublicExposure   = $publicExposure
        BlockingConflict = $blockingConflict
        ScopeMatches     = $scopeMatches
        ScopeCouldAffectSshd = $scopeCouldAffectSshd
        Problems         = @($problems)
        OverbroadReasons = @($overbroadReasons)
        Rule             = $Rule
    }
}

function Test-FirewallPackageGeneric {
    param($Package)

    $packages = @(ConvertTo-TokenList $Package)
    return ($packages.Count -eq 0 -or [bool]($packages | Where-Object { $_ -eq 'Any' }))
}

function New-FirewallInstanceMap {
    param(
        [object[]]$Items = @(),
        [Parameter(Mandatory)][string]$Kind
    )

    $map = [System.Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in $Items) {
        if ($item.PSObject.Properties.Name -notcontains 'InstanceID' -or -not $item.InstanceID) {
            throw "$Kind entry is missing InstanceID."
        }
        $key = $item.InstanceID.ToString()
        if ($map.ContainsKey($key)) {
            throw "$Kind has duplicate ambiguous InstanceID: $key"
        }
        $map.Add($key, $item)
    }
    return (, $map)
}

function Get-EffectiveSshFirewallRules {
    $normalized = [System.Collections.Generic.List[object]]::new()
    try {
        # All six effective-store classes share InstanceID. Enumerate each once,
        # then hash-join in memory; per-rule CIM associations are prohibitively
        # slow on hosts with hundreds of AppX Any-port rules.
        $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop)
        $portFilters = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore -ErrorAction Stop)
        $addressFilters = @(Get-NetFirewallAddressFilter -PolicyStore ActiveStore -ErrorAction Stop)
        $applicationFilters = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction Stop)
        $serviceFilters = @(Get-NetFirewallServiceFilter -PolicyStore ActiveStore -ErrorAction Stop)
        $interfaceFilters = @(Get-NetFirewallInterfaceFilter -PolicyStore ActiveStore -ErrorAction Stop)

        $ruleMap = New-FirewallInstanceMap -Items $rules -Kind 'Firewall rule store'
        $portMap = New-FirewallInstanceMap -Items $portFilters -Kind 'Port filter store'
        $addressMap = New-FirewallInstanceMap -Items $addressFilters -Kind 'Address filter store'
        $applicationMap = New-FirewallInstanceMap -Items $applicationFilters -Kind 'Application filter store'
        $serviceMap = New-FirewallInstanceMap -Items $serviceFilters -Kind 'Service filter store'
        $interfaceMap = New-FirewallInstanceMap -Items $interfaceFilters -Kind 'Interface filter store'
        $candidateKeys = [System.Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )

        foreach ($entry in $ruleMap.GetEnumerator()) {
            if ("$($entry.Value.Name) $($entry.Value.DisplayName)" -match '(?i)openssh|sshd|ssh server') {
                $null = $candidateKeys.Add($entry.Key)
            }
        }
        foreach ($entry in $portMap.GetEnumerator()) {
            $portFilter = $entry.Value
            if (-not (Test-Port22Overlap $portFilter.LocalPort)) { continue }
            $exactPort22 = [bool](@(ConvertTo-TokenList $portFilter.LocalPort) |
                Where-Object { $_ -eq '22' })
            if ($exactPort22) {
                # Preserve diagnostics for exact-port rules even when package scoped.
                $null = $candidateKeys.Add($entry.Key)
                continue
            }
            if (-not $applicationMap.ContainsKey($entry.Key)) {
                # Cannot prove that broad overlap is harmless AppX scope.
                $null = $candidateKeys.Add($entry.Key)
                continue
            }
            if (Test-FirewallPackageGeneric $applicationMap[$entry.Key].Package) {
                $null = $candidateKeys.Add($entry.Key)
            }
        }

        foreach ($key in $candidateKeys) {
            foreach ($requiredMap in @(
                $ruleMap, $portMap, $addressMap, $applicationMap, $serviceMap, $interfaceMap
            )) {
                if (-not $requiredMap.ContainsKey($key)) {
                    throw "Firewall candidate $key has an incomplete InstanceID filter join."
                }
            }
            $rule = $ruleMap[$key]
            $portFilter = $portMap[$key]
            $addressFilter = $addressMap[$key]
            $applicationFilter = $applicationMap[$key]
            $serviceFilter = $serviceMap[$key]
            $interfaceFilter = $interfaceMap[$key]
            $normalized.Add([pscustomobject]@{
                Name           = $rule.Name
                DisplayName    = $rule.DisplayName
                Enabled        = $rule.Enabled
                Direction      = $rule.Direction
                Action         = $rule.Action
                Profile        = $rule.Profile
                Protocol       = $portFilter.Protocol
                LocalPort      = $portFilter.LocalPort
                RemoteAddress  = $addressFilter.RemoteAddress
                Program        = $applicationFilter.Program
                Package        = $applicationFilter.Package
                Service        = $serviceFilter.Service
                InterfaceAlias = $interfaceFilter.InterfaceAlias
                ScopeKnown     = $true
            })
        }
    } catch {
        throw "Firewall audit incomplete: $($_.Exception.Message)"
    }
    return @($normalized)
}

function Get-SshFirewallStatus {
    param(
        [object[]]$Rules = $(Get-EffectiveSshFirewallRules),
        [AllowNull()][string]$SelectedSshdPath,
        [string]$ServiceName = 'sshd',
        [bool]$AuditComplete = $true
    )

    $evaluations = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in @($Rules)) {
        $evaluation = Get-FirewallRuleEvaluation -Rule $rule `
            -SelectedSshdPath $SelectedSshdPath -ServiceName $ServiceName
        $exactPort22 = [bool](@(ConvertTo-TokenList $rule.LocalPort) |
            Where-Object { $_ -eq '22' })
        $looksRelated = $evaluation.Compatible -or $evaluation.PublicExposure -or
            $evaluation.BlockingConflict -or $exactPort22 -or
            ((Test-Port22Overlap $rule.LocalPort) -and $evaluation.ScopeCouldAffectSshd) -or
            "$($rule.Name) $($rule.DisplayName)" -match '(?i)openssh|sshd|ssh server'
        if (-not $looksRelated) { continue }
        $evaluations.Add($evaluation)
        if ($evaluation.PublicExposure) {
            $findings.Add("$($evaluation.Name): enabled inbound TCP 22 allow rule includes Public profile")
        } elseif ($evaluation.BlockingConflict) {
            $findings.Add("$($evaluation.Name): enabled inbound TCP 22 block rule overlaps Domain/Private")
        } elseif ($evaluation.Overbroad) {
            $findings.Add("$($evaluation.Name): $($evaluation.OverbroadReasons -join '; ')")
        } elseif (-not $evaluation.Compatible) {
            $findings.Add("$($evaluation.Name): $($evaluation.Problems -join '; ')")
        }
    }

    $compatible = @($evaluations | Where-Object Compatible)
    $safe = @($compatible | Where-Object Safe)
    $selected = @($safe + @($compatible | Where-Object { -not $_.Safe })) | Select-Object -First 1
    $publicExposure = [bool]($evaluations | Where-Object PublicExposure)
    $blockingConflict = [bool]($evaluations | Where-Object BlockingConflict)
    return [pscustomobject]@{
        AuditComplete    = $AuditComplete
        Compatible       = [bool]$selected
        Safe             = [bool]($selected -and $selected.Safe)
        Overbroad        = [bool]($selected -and $selected.Overbroad)
        PublicExposure   = $publicExposure
        BlockingConflict = $blockingConflict
        CompatibleRule   = if ($selected) { $selected.Name } else { $null }
        Evaluations      = @($evaluations)
        Findings         = @($findings)
    }
}

function New-SafeSshFirewallRule {
    $name = $script:OpenSshFirewallRuleBaseName
    if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) {
        $name = "$name-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    }
    Info "Creating $name for Domain/Private TCP 22 from LocalSubnet"
    New-NetFirewallRule -Name $name -DisplayName 'OpenSSH Server (sshd) - local subnet' `
        -Enabled True -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
        -Profile Domain,Private -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
    return $name
}

function Ensure-SshFirewall {
    param(
        [Parameter(Mandatory)]$FirewallStatus,
        [System.Collections.Generic.List[string]]$Changes
    )

    if (-not $FirewallStatus.AuditComplete) {
        throw 'Firewall audit is incomplete; refusing to change policy or claim readiness.'
    }
    if ($FirewallStatus.PublicExposure) {
        throw 'An existing enabled inbound TCP 22 allow rule includes Public/Any profile. Refusing to claim readiness or rewrite the pre-existing rule.'
    }
    if ($FirewallStatus.BlockingConflict) {
        throw 'An enabled inbound TCP 22 block rule overlaps Domain/Private. Refusing to claim readiness or rewrite the pre-existing rule.'
    }
    if ($FirewallStatus.Compatible) {
        Info "Preserving compatible firewall rule $($FirewallStatus.CompatibleRule)"
        return $null
    }
    $name = New-SafeSshFirewallRule
    $Changes.Add("Created firewall rule $name")
    return $name
}

function Get-ActiveSshNetworkProfileStatus {
    try {
        $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    } catch {
        throw "Active network profile inspection failed: $($_.Exception.Message)"
    }

    $activeConnectivity = @('Subnet', 'LocalNetwork', 'Internet')
    $activeProfiles = @($profiles | Where-Object {
        $hasConnectivityProperties = $_.PSObject.Properties.Name -contains 'IPv4Connectivity' -or
            $_.PSObject.Properties.Name -contains 'IPv6Connectivity'
        # Real Get-NetConnectionProfile results expose both fields. Retain simple
        # test doubles without them, but never treat NoTraffic as an active path.
        if (-not $hasConnectivityProperties) { return $true }
        $ipv4 = if ($_.PSObject.Properties.Name -contains 'IPv4Connectivity') {
            $_.IPv4Connectivity.ToString()
        } else { 'Disconnected' }
        $ipv6 = if ($_.PSObject.Properties.Name -contains 'IPv6Connectivity') {
            $_.IPv6Connectivity.ToString()
        } else { 'Disconnected' }
        return ($ipv4 -in $activeConnectivity -or $ipv6 -in $activeConnectivity)
    })
    $safeProfiles = @($activeProfiles | Where-Object {
        $_.NetworkCategory.ToString() -in @('Private', 'DomainAuthenticated')
    })
    $categories = @($activeProfiles | ForEach-Object { $_.NetworkCategory.ToString() })
    return [pscustomobject]@{
        AuditComplete        = $true
        HasSafeActiveProfile = ($safeProfiles.Count -gt 0)
        ActiveCategories     = $categories
        PublicOnly           = ($activeProfiles.Count -gt 0 -and
            -not ($categories | Where-Object { $_ -ne 'Public' }))
    }
}

function Get-RegistryValueKind {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name).ToString()
    } catch {
        return $null
    }
}

function Get-OpenSshRegistryState {
    $path = $script:OpenSshRegistryPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            PathExists                        = $false
            DefaultShellExists                = $false
            DefaultShellValue                 = $null
            DefaultShellType                  = $null
            DefaultShellCommandOptionExists   = $false
            DefaultShellCommandOptionValue    = $null
            DefaultShellCommandOptionType     = $null
        }
    }

    try {
        $key = Get-Item -LiteralPath $path -ErrorAction Stop
        $names = @($key.GetValueNames())
        $shellExists = $names -contains 'DefaultShell'
        $optionExists = $names -contains 'DefaultShellCommandOption'
        $rawOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        return [pscustomobject]@{
            PathExists                        = $true
            DefaultShellExists                = $shellExists
            DefaultShellValue                 = if ($shellExists) {
                $key.GetValue('DefaultShell', $null, $rawOptions)
            } else { $null }
            DefaultShellType                  = if ($shellExists) {
                $key.GetValueKind('DefaultShell').ToString()
            } else { $null }
            DefaultShellCommandOptionExists   = $optionExists
            DefaultShellCommandOptionValue    = if ($optionExists) {
                $key.GetValue('DefaultShellCommandOption', $null, $rawOptions)
            } else { $null }
            DefaultShellCommandOptionType     = if ($optionExists) {
                $key.GetValueKind('DefaultShellCommandOption').ToString()
            } else { $null }
        }
    } catch {
        throw "Could not read ${path}: $($_.Exception.Message)"
    }
}

function Set-OpenSshDefaultShell {
    param([Parameter(Mandatory)][string]$PwshPath)

    if (-not (Test-Path -LiteralPath $PwshPath -PathType Leaf)) {
        throw "Refusing to set DefaultShell to a missing executable: $PwshPath"
    }
    New-Item -Path $script:OpenSshRegistryPath -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $script:OpenSshRegistryPath -Name 'DefaultShell' `
        -Value $PwshPath -PropertyType String -Force -ErrorAction Stop | Out-Null

    $readback = Get-OpenSshRegistryState
    if (-not $readback.DefaultShellExists -or $readback.DefaultShellValue -ne $PwshPath -or
        $readback.DefaultShellType -ne 'String') {
        throw 'DefaultShell registry readback did not match the requested pwsh path and String type.'
    }
    return $readback
}

function Restore-OpenSshDefaultShell {
    param([Parameter(Mandatory)]$Snapshot)

    if ($Snapshot.DefaultShellExists) {
        if (-not $Snapshot.DefaultShellType) {
            throw 'Cannot restore DefaultShell without its prior registry type.'
        }
        New-Item -Path $script:OpenSshRegistryPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $script:OpenSshRegistryPath -Name 'DefaultShell' `
            -Value $Snapshot.DefaultShellValue -PropertyType $Snapshot.DefaultShellType `
            -Force -ErrorAction Stop | Out-Null
    } else {
        $current = Get-OpenSshRegistryState
        if ($current.DefaultShellExists) {
            Remove-ItemProperty -Path $script:OpenSshRegistryPath -Name 'DefaultShell' `
                -Force -ErrorAction Stop
        }
    }

    $readback = Get-OpenSshRegistryState
    $matchesSnapshot = if ($Snapshot.DefaultShellExists) {
        $readback.DefaultShellExists -and
            $readback.DefaultShellValue -ceq $Snapshot.DefaultShellValue -and
            $readback.DefaultShellType -ceq $Snapshot.DefaultShellType
    } else {
        -not $readback.DefaultShellExists
    }
    if (-not $matchesSnapshot) {
        throw 'DefaultShell rollback readback did not exactly match its prior existence, value, and type.'
    }
    return $readback
}

function Write-CommandOptionStatus {
    param([Parameter(Mandatory)]$RegistryState)

    if ($RegistryState.DefaultShellCommandOptionExists) {
        Info "DefaultShellCommandOption is present ($($RegistryState.DefaultShellCommandOptionType)): $($RegistryState.DefaultShellCommandOptionValue) — reporting only; it will not be changed"
    } else {
        Info 'DefaultShellCommandOption is absent — reporting only; it will not be created'
    }
}

function Get-OpenSshServerStatus {
    param([switch]$CheckOnly)

    $pwsh = Resolve-PwshExecutable
    $capability = Get-OpenSshCapabilityInfo
    $installation = Get-SshdInstallation
    $configPath = Resolve-SshdConfigPath -Installation $installation
    $configValid = [bool]($installation.UsableExisting -and
        (Test-SshdConfiguration -SshdPath $installation.ExecutablePath -ConfigPath $configPath))
    $service = $installation.Service
    $listener = Test-Tcp22Listener -SshdProcessId $service.ProcessId
    $network = Get-ActiveSshNetworkProfileStatus
    $firewall = Get-SshFirewallStatus -SelectedSshdPath $installation.ExecutablePath
    $registry = Get-OpenSshRegistryState
    $defaultShellMatches = [bool]($pwsh -and $registry.DefaultShellExists -and
        $registry.DefaultShellValue -eq $pwsh.Path -and $registry.DefaultShellType -eq 'String')
    $serviceReady = [bool]($service.Exists -and $service.StartType -eq 'Automatic' -and
        $service.Status -eq 'Running')
    $ready = [bool]($pwsh -and $installation.UsableExisting -and $configValid -and
        $serviceReady -and $listener -and $network.AuditComplete -and
        $network.HasSafeActiveProfile -and $firewall.AuditComplete -and $firewall.Compatible -and
        -not $firewall.PublicExposure -and -not $firewall.BlockingConflict -and
        $defaultShellMatches)

    return [pscustomobject][ordered]@{
        Success                          = $true
        Ready                            = $ready
        CheckOnly                        = [bool]$CheckOnly
        NeedsElevation                   = $false
        ElevatedProcessStarted           = $false
        RecoveryCommand                  = $null
        PwshPath                         = if ($pwsh) { $pwsh.Path } else { $null }
        PwshSource                       = if ($pwsh) { $pwsh.Source } else { $null }
        PwshEdition                      = if ($pwsh) { $pwsh.Edition } else { $null }
        PwshVersion                      = if ($pwsh) { $pwsh.Version.ToString() } else { $null }
        PwshUserScoped                   = [bool]($pwsh -and $pwsh.UserScoped)
        CapabilityName                   = $capability.Name
        CapabilityState                  = $capability.State
        SshdSource                       = $installation.Source
        SshdPath                         = $installation.ExecutablePath
        SshdProductName                  = $installation.ProductName
        SshdProductVersion               = $installation.ProductVersion
        SshdAuthenticodeStatus           = $installation.AuthenticodeStatus
        SshdSignerSubject                = $installation.SignerSubject
        SshdProcessId                    = $service.ProcessId
        ExistingSourcePresent            = $installation.ExistingSourcePresent
        UsableExistingServer             = $installation.UsableExisting
        ConfigPath                       = $configPath
        ConfigValid                      = $configValid
        ServiceExists                    = $service.Exists
        ServiceStartType                 = $service.StartType
        ServiceStatus                    = $service.Status
        Tcp22Listening                    = $listener
        NetworkAuditComplete              = $network.AuditComplete
        HasSafeActiveNetworkProfile       = $network.HasSafeActiveProfile
        ActiveNetworkCategories           = @($network.ActiveCategories)
        PublicOnlyActiveNetwork           = $network.PublicOnly
        FirewallAuditComplete             = $firewall.AuditComplete
        FirewallCompatible               = $firewall.Compatible
        FirewallSafe                     = $firewall.Safe
        FirewallOverbroad                = $firewall.Overbroad
        FirewallPublicExposure           = $firewall.PublicExposure
        FirewallBlockingConflict         = $firewall.BlockingConflict
        FirewallRule                     = $firewall.CompatibleRule
        FirewallFindings                 = @($firewall.Findings)
        DefaultShellExists               = $registry.DefaultShellExists
        DefaultShell                     = $registry.DefaultShellValue
        DefaultShellType                 = $registry.DefaultShellType
        DefaultShellMatches              = $defaultShellMatches
        DefaultShellCommandOptionExists  = $registry.DefaultShellCommandOptionExists
        DefaultShellCommandOption        = $registry.DefaultShellCommandOptionValue
        DefaultShellCommandOptionType    = $registry.DefaultShellCommandOptionType
        Changes                          = @()
        Errors                           = @()
    }
}

function Write-OpenSshStatus {
    param([Parameter(Mandatory)]$Status)

    Info "OpenSSH source: $($Status.SshdSource); capability: $($Status.CapabilityState)"
    if ($Status.PwshUserScoped) {
        Write-Warning 'OpenSSH DefaultShell points to a user-scoped Scoop pwsh. Other SSH accounts may not have permission to execute that path.'
    }
    Info "sshd config valid: $($Status.ConfigValid); service: $($Status.ServiceStatus)/$($Status.ServiceStartType); TCP 22 listener: $($Status.Tcp22Listening)"
    if (-not $Status.HasSafeActiveNetworkProfile) {
        Write-Warning 'No active Private or DomainAuthenticated network exists. Use Windows Settings locally to choose the appropriate Private profile, then rerun; this helper never reclassifies a network or opens Public.'
    }
    if ($Status.FirewallRule) {
        Info "firewall rule: $($Status.FirewallRule) (safe baseline: $($Status.FirewallSafe))"
    } else {
        Write-Warning 'No compatible enabled inbound allow rule for TCP 22 covers Domain or Private.'
    }
    foreach ($finding in @($Status.FirewallFindings)) {
        Write-Warning "Firewall finding: $finding"
    }
    Write-CommandOptionStatus -RegistryState ([pscustomobject]@{
        DefaultShellCommandOptionExists = $Status.DefaultShellCommandOptionExists
        DefaultShellCommandOptionValue  = $Status.DefaultShellCommandOption
        DefaultShellCommandOptionType   = $Status.DefaultShellCommandOptionType
    })
}

function Write-OpenSshSuccess {
    param([Parameter(Mandatory)]$Status)

    Info 'OpenSSH server is locally verified: sshd_config is valid, the service is Automatic/Running, TCP 22 is listening, and an effective inbound firewall rule is compatible.'
    Write-Warning 'External reachability has not been tested. Verify from another host before treating SSH access as ready: ssh <user>@<this-machine-name>'
    if ($Status.FirewallOverbroad) {
        Write-Warning 'The preserved compatible firewall rule is broader than the Domain/Private + LocalSubnet baseline; it was reported but not rewritten to avoid disrupting remote access.'
    }
}

function Invoke-OpenSshServerSetup {
    param([switch]$CheckOnly)

    if ($CheckOnly) {
        try {
            $status = Get-OpenSshServerStatus -CheckOnly
            Write-OpenSshStatus -Status $status
            return $status
        } catch {
            Write-Warning "OpenSSH check failed (non-fatal): $($_.Exception.Message)"
            return [pscustomobject]@{
                Success = $false; Ready = $false; CheckOnly = $true
                Errors = @($_.Exception.Message); Changes = @()
            }
        }
    }

    $changes = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $createdFirewallRule = $null
    $registrySnapshot = $null
    $defaultShellTouched = $false
    $serviceSnapshot = $null
    $serviceMayHaveChanged = $false

    try {
        if (-not (Test-Admin)) { throw 'Administrative privileges are required for OpenSSH setup.' }

        $pwsh = Resolve-PwshExecutable
        if (-not $pwsh) {
            throw 'No real PowerShell Core 7+ pwsh.exe was found (machine-wide MSI, Scoop current, then non-shim PATH were checked).'
        }
        if ($pwsh.UserScoped) {
            Write-Warning 'Using user-scoped Scoop pwsh for HKLM OpenSSH DefaultShell. Other SSH accounts may not have permission to execute it.'
        }

        $capability = Get-OpenSshCapabilityInfo
        $installation = Get-SshdInstallation
        $installation = Ensure-OpenSshSource -Installation $installation -Capability $capability -Changes $changes

        $runtime = Resolve-ValidatedSshdRuntime -Installation $installation -Changes $changes
        $installation = $runtime.Installation

        $network = Get-ActiveSshNetworkProfileStatus
        if (-not $network.AuditComplete -or -not $network.HasSafeActiveProfile) {
            throw 'No active Private or DomainAuthenticated network exists. Use Windows Settings locally to select the appropriate Private profile, then rerun; no network was reclassified and Public was not opened.'
        }

        # Establish firewall safety before the first service start. A pre-existing
        # Public/Any allow or overlapping block rule fails without exposing sshd.
        $firewall = Get-SshFirewallStatus -SelectedSshdPath $installation.ExecutablePath
        foreach ($finding in @($firewall.Findings)) { Write-Warning "Firewall finding: $finding" }
        $createdFirewallRule = Ensure-SshFirewall -FirewallStatus $firewall -Changes $changes

        $serviceSnapshot = [pscustomobject]@{
            Exists = $installation.Service.Exists
            Status = $installation.Service.Status
            StartType = $installation.Service.StartType
        }
        $serviceMayHaveChanged = $true
        Ensure-SshdService -Service $installation.Service -ConfigurationValid $true -Changes $changes

        $registrySnapshot = Get-OpenSshRegistryState
        Write-CommandOptionStatus -RegistryState $registrySnapshot
        if ($registrySnapshot.DefaultShellExists -and -not $registrySnapshot.DefaultShellType) {
            throw 'Refusing to change DefaultShell because its existing registry type could not be snapshotted for exact rollback.'
        }
        if (-not $registrySnapshot.DefaultShellExists -or
            $registrySnapshot.DefaultShellValue -ne $pwsh.Path -or
            $registrySnapshot.DefaultShellType -ne 'String') {
            $defaultShellTouched = $true
            $null = Set-OpenSshDefaultShell -PwshPath $pwsh.Path
            $changes.Add("Set OpenSSH DefaultShell to $($pwsh.Path)")
        }

        $final = Get-OpenSshServerStatus
        $final.Changes = @($changes)
        if (-not $final.Ready) {
            throw 'Final local verification did not pass every required check.'
        }
        Write-OpenSshStatus -Status $final
        Write-OpenSshSuccess -Status $final
        return $final
    } catch {
        $errors.Add($_.Exception.Message)
        if ($serviceMayHaveChanged -and $serviceSnapshot) {
            try {
                Restore-SshdServiceState -Snapshot $serviceSnapshot
                Info 'Restored the prior sshd service status and startup type after failure'
            } catch {
                $errors.Add("sshd service rollback failed: $($_.Exception.Message)")
            }
        }
        if ($defaultShellTouched -and $registrySnapshot) {
            try {
                $null = Restore-OpenSshDefaultShell -Snapshot $registrySnapshot
                Info 'Restored the prior OpenSSH DefaultShell after failure'
            } catch {
                $errors.Add("DefaultShell rollback failed: $($_.Exception.Message)")
            }
        }
        if ($createdFirewallRule) {
            try {
                Remove-NetFirewallRule -Name $createdFirewallRule -ErrorAction Stop
                Info "Removed firewall rule created by this invocation: $createdFirewallRule"
            } catch {
                $errors.Add("Firewall rollback failed for ${createdFirewallRule}: $($_.Exception.Message)")
            }
        }

        Write-Warning "OpenSSH server setup failed (non-fatal): $($errors -join '; ')"
        try {
            $failed = Get-OpenSshServerStatus
            $failed.Success = $false
            $failed.Ready = $false
            $failed.Changes = @($changes)
            $failed.Errors = @($errors)
            return $failed
        } catch {
            return [pscustomobject]@{
                Success = $false; Ready = $false; CheckOnly = $false
                Changes = @($changes); Errors = @($errors)
            }
        }
    }
}

function New-ElevationResult {
    param(
        [bool]$Started = $false,
        [Nullable[int]]$ChildExitCode,
        [bool]$ChildSucceeded = $false,
        [string[]]$Errors = @()
    )

    return [pscustomobject]@{
        Success                = $ChildSucceeded
        Ready                  = $ChildSucceeded
        CheckOnly              = $false
        NeedsElevation         = -not $ChildSucceeded
        ElevatedProcessStarted = $Started
        ElevatedChildExitCode  = $ChildExitCode
        RecoveryCommand        = if ($ChildSucceeded) { $null } else { $script:OpenSshRecoveryCommand }
        Changes                = @()
        Errors                 = @($Errors)
    }
}

function Write-LocalElevationRecovery {
    Write-Warning "OpenSSH is not ready. In a LOCAL elevated PowerShell 7 window on this machine, run exactly: $script:OpenSshRecoveryCommand"
}

function Invoke-OpenSshServerEntry {
    param(
        [switch]$CheckOnly,
        [switch]$Elevated,
        [switch]$RequireSuccess,
        [AllowNull()][string]$ScriptPath
    )

    try {
        if ($CheckOnly) { return Invoke-OpenSshServerSetup -CheckOnly }
        if (Test-Admin) { return Invoke-OpenSshServerSetup }

        if ($Elevated -or (Test-SshSession) -or -not $ScriptPath) {
            Write-LocalElevationRecovery
            return New-ElevationResult
        }

        $pwsh = Resolve-PwshExecutable
        if (-not $pwsh) {
            Write-LocalElevationRecovery
            return New-ElevationResult -Errors @('No real PowerShell Core 7+ executable is available for elevation.')
        }

        Info 'OpenSSH needs admin — requesting elevation once (approve the local UAC prompt).'
        $quotedScriptPath = '"' + $ScriptPath.Replace('"', '\"') + '"'
        $childArguments = @('-NoProfile', '-NoLogo', '-File', $quotedScriptPath, '-Elevated')
        if ($RequireSuccess) { $childArguments += '-RequireSuccess' }
        try {
            $child = Start-Process -FilePath $pwsh.Path -Verb RunAs -Wait -PassThru `
                -ErrorAction Stop -ArgumentList $childArguments
        } catch {
            Write-LocalElevationRecovery
            return New-ElevationResult -Errors @('Elevation was declined, cancelled, or unavailable.')
        }
        if ($child.ExitCode -eq 0) {
            Info 'Elevated OpenSSH child reported successful local verification.'
            return New-ElevationResult -Started $true -ChildExitCode 0 -ChildSucceeded $true
        }
        Write-LocalElevationRecovery
        return New-ElevationResult -Started $true -ChildExitCode $child.ExitCode `
            -Errors @("Elevated OpenSSH setup failed with exit code $($child.ExitCode).")
    } catch {
        Write-Warning "OpenSSH entry failed (non-fatal): $($_.Exception.Message)"
        Write-LocalElevationRecovery
        return New-ElevationResult -Errors @($_.Exception.Message)
    }
}

# InvocationName is '.' only when Pester (or a caller) dot-sources this helper.
# The included chezmoi body and direct `pwsh -File` execution both take this path.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Continue'
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $entryResult = Invoke-OpenSshServerEntry -CheckOnly:$CheckOnly -Elevated:$Elevated `
        -RequireSuccess:$RequireSuccess -ScriptPath $PSCommandPath
    if ($CheckOnly) { $entryResult }
    # The explicitly elevated child and documented direct recovery command
    # communicate readiness via exit code. Embedded chezmoi execution passes
    # neither flag and therefore remains nonfatal even when setup fails.
    if ($Elevated -or $RequireSuccess) {
        if ($entryResult.Ready) { exit 0 }
        exit 1
    }
}
