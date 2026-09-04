#Requires -Version 7
# Pester coverage for the testable OpenSSH Server bootstrap.

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $script:SshdScript = Join-Path $script:RepoRoot 'scripts' 'enable-sshd.ps1'
    $script:CreatedCommandStubs = [System.Collections.Generic.List[string]]::new()

    # NetSecurity and DISM cmdlets do not exist on the macOS development host.
    # Define only the command shapes needed by mocks; remove them after the suite.
    if (-not (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallRule {
            param($Name, $PolicyStore, $AssociatedNetFirewallPortFilter, $ErrorAction)
            $null = $Name, $PolicyStore, $AssociatedNetFirewallPortFilter, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetFirewallRule')
    }
    if (-not (Get-Command Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallPortFilter {
            param($PolicyStore, $AssociatedNetFirewallRule, $ErrorAction)
            $null = $PolicyStore, $AssociatedNetFirewallRule, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetFirewallPortFilter')
    }
    if (-not (Get-Command Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallAddressFilter {
            param($PolicyStore, $AssociatedNetFirewallRule, $ErrorAction)
            $null = $PolicyStore, $AssociatedNetFirewallRule, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetFirewallAddressFilter')
    }
    if (-not (Get-Command Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallApplicationFilter {
            param($PolicyStore, $AssociatedNetFirewallRule, $ErrorAction)
            $null = $PolicyStore, $AssociatedNetFirewallRule, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetFirewallApplicationFilter')
    }
    if (-not (Get-Command Get-NetFirewallServiceFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallServiceFilter {
            param($PolicyStore, $AssociatedNetFirewallRule, $ErrorAction)
            $null = $PolicyStore, $AssociatedNetFirewallRule, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetFirewallServiceFilter')
    }
    if (-not (Get-Command Get-NetFirewallInterfaceFilter -ErrorAction SilentlyContinue)) {
        function global:Get-NetFirewallInterfaceFilter {
            param($PolicyStore, $AssociatedNetFirewallRule, $ErrorAction)
            $null = $PolicyStore, $AssociatedNetFirewallRule, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetFirewallInterfaceFilter')
    }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        function global:Get-NetTCPConnection {
            param($State, $LocalPort, $ErrorAction)
            $null = $State, $LocalPort, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetTCPConnection')
    }
    if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
        function global:Get-AuthenticodeSignature {
            param($LiteralPath, $ErrorAction)
            $null = $LiteralPath, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-AuthenticodeSignature')
    }
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        function global:New-NetFirewallRule {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSAvoidAssignmentToAutomaticVariable', 'Profile',
                Justification = 'The Linux-only stub must mirror the Windows cmdlet parameter name for Pester mocks.'
            )]
            param(
                $Name, $DisplayName, $Enabled, $Direction, $Action, $Protocol,
                $LocalPort, $Profile, $RemoteAddress, $ErrorAction
            )
            $null = $Name, $DisplayName, $Enabled, $Direction, $Action, $Protocol,
                $LocalPort, $Profile, $RemoteAddress, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('New-NetFirewallRule')
    }
    if (-not (Get-Command Remove-NetFirewallRule -ErrorAction SilentlyContinue)) {
        function global:Remove-NetFirewallRule {
            param($Name, $ErrorAction)
            $null = $Name, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Remove-NetFirewallRule')
    }
    if (-not (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue)) {
        function global:Get-WindowsCapability {
            param([switch]$Online, $Name, $ErrorAction)
            $null = $Online, $Name, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-WindowsCapability')
    }
    if (-not (Get-Command Add-WindowsCapability -ErrorAction SilentlyContinue)) {
        function global:Add-WindowsCapability {
            param([switch]$Online, $Name, $ErrorAction)
            $null = $Online, $Name, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Add-WindowsCapability')
    }
    if (-not (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        function global:Get-NetConnectionProfile {
            param($ErrorAction)
            $null = $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Get-NetConnectionProfile')
    }
    if (-not (Get-Command Set-Service -ErrorAction SilentlyContinue)) {
        function global:Set-Service {
            param($Name, $StartupType, $ErrorAction)
            $null = $Name, $StartupType, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Set-Service')
    }
    if (-not (Get-Command Start-Service -ErrorAction SilentlyContinue)) {
        function global:Start-Service {
            param($Name, $ErrorAction)
            $null = $Name, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Start-Service')
    }
    if (-not (Get-Command Stop-Service -ErrorAction SilentlyContinue)) {
        function global:Stop-Service {
            param($Name, $Force, $ErrorAction)
            $null = $Name, $Force, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Stop-Service')
    }
    if (-not (Get-Command Restart-Service -ErrorAction SilentlyContinue)) {
        function global:Restart-Service {
            param($Name, $Force, $ErrorAction)
            $null = $Name, $Force, $ErrorAction
        }
        $script:CreatedCommandStubs.Add('Restart-Service')
    }

    . $script:SshdScript

    function New-TestSshdStatus {
        param(
            [switch]$Ready,
            [switch]$CheckOnly,
            [switch]$FirewallOverbroad
        )

        return [pscustomobject][ordered]@{
            Success                         = $true
            Ready                           = $Ready
            CheckOnly                       = $CheckOnly
            NeedsElevation                  = $false
            ElevatedProcessStarted          = $false
            RecoveryCommand                 = $null
            PwshPath                        = 'C:\Program Files\PowerShell\7\pwsh.exe'
            PwshSource                      = 'MSI'
            PwshEdition                     = 'Core'
            PwshVersion                     = '7.5.2'
            PwshUserScoped                  = $false
            CapabilityName                  = 'OpenSSH.Server~~~~0.0.1.0'
            CapabilityState                 = 'NotPresent'
            SshdSource                      = 'ExistingMicrosoftOpenSSH'
            SshdPath                        = 'C:\Program Files\OpenSSH\sshd.exe'
            SshdProductName                 = 'OpenSSH for Windows'
            SshdProductVersion              = '9.5.0.0'
            SshdAuthenticodeStatus          = 'Valid'
            SshdSignerSubject               = 'O=Microsoft Corporation'
            SshdProcessId                   = 4321
            ExistingSourcePresent           = $true
            UsableExistingServer            = $true
            ConfigPath                      = 'C:\ProgramData\ssh\sshd_config'
            ConfigValid                     = $true
            ServiceExists                   = $true
            ServiceStartType                = 'Automatic'
            ServiceStatus                   = 'Running'
            Tcp22Listening                   = $true
            NetworkAuditComplete             = $true
            HasSafeActiveNetworkProfile      = $true
            ActiveNetworkCategories          = @('Private')
            PublicOnlyActiveNetwork          = $false
            FirewallAuditComplete            = $true
            FirewallCompatible              = $true
            FirewallSafe                    = -not $FirewallOverbroad
            FirewallOverbroad               = $FirewallOverbroad
            FirewallPublicExposure          = $false
            FirewallBlockingConflict        = $false
            FirewallRule                    = 'OpenSSH-Server-Preview-In-TCP'
            FirewallFindings                = if ($FirewallOverbroad) {
                @('OpenSSH-Server-Preview-In-TCP: remote scope is broader than LocalSubnet')
            } else { @() }
            DefaultShellExists              = $true
            DefaultShell                    = 'C:\Program Files\PowerShell\7\pwsh.exe'
            DefaultShellType                = 'String'
            DefaultShellMatches             = $true
            DefaultShellCommandOptionExists = $true
            DefaultShellCommandOption       = '-sshs'
            DefaultShellCommandOptionType   = 'String'
            Changes                         = @()
            Errors                          = @()
        }
    }
}

AfterAll {
    foreach ($name in $script:CreatedCommandStubs) {
        Remove-Item "Function:\global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'enable-sshd loading and check-only behavior' {
    It 'does not perform setup when dot-sourced' {
        Mock Start-Process {}
        Mock Add-WindowsCapability {}
        Mock New-NetFirewallRule {}
        Mock New-ItemProperty {}
        $previousPreference = $ErrorActionPreference

        try {
            $ErrorActionPreference = 'Stop'
            . $script:SshdScript

            $ErrorActionPreference | Should -BeExactly 'Stop'
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Add-WindowsCapability -Times 0 -Exactly
            Should -Invoke New-NetFirewallRule -Times 0 -Exactly
            Should -Invoke New-ItemProperty -Times 0 -Exactly
        } finally {
            $ErrorActionPreference = $previousPreference
        }
    }

    It 'returns structured status and makes no changes in check-only mode' {
        $expected = New-TestSshdStatus -CheckOnly
        Mock Get-OpenSshServerStatus { $expected }
        Mock Write-OpenSshStatus {}
        Mock Ensure-OpenSshSource {}
        Mock Ensure-SshdService {}
        Mock Ensure-SshFirewall {}
        Mock Set-OpenSshDefaultShell {}
        Mock Add-WindowsCapability {}
        Mock New-NetFirewallRule {}

        $result = Invoke-OpenSshServerSetup -CheckOnly

        $result.CheckOnly | Should -BeTrue
        $result.Changes | Should -HaveCount 0
        $result.SshdPath | Should -BeExactly 'C:\Program Files\OpenSSH\sshd.exe'
        Should -Invoke Ensure-OpenSshSource -Times 0 -Exactly
        Should -Invoke Ensure-SshdService -Times 0 -Exactly
        Should -Invoke Ensure-SshFirewall -Times 0 -Exactly
        Should -Invoke Set-OpenSshDefaultShell -Times 0 -Exactly
        Should -Invoke Add-WindowsCapability -Times 0 -Exactly
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
    }

    It 'uses RequireSuccess only for the documented just recovery path' {
        $justfile = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'justfile')
        $wrapper = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.chezmoiscripts' 'run_onchange_after_40_openssh_server.ps1.tmpl')

        $justfile | Should -Match '(?ms)^enable-sshd:\s+pwsh .*enable-sshd\.ps1 -RequireSuccess'
        $wrapper | Should -Not -Match 'RequireSuccess'
    }
}

Describe 'one-shot elevation and recovery guidance' {
    BeforeEach {
        Mock Test-Admin { $false }
        Mock Test-SshSession { $false }
        Mock Resolve-PwshExecutable {
            [pscustomobject]@{
                Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
                Source = 'MSI'; Edition = 'Core'; Version = [version]'7.5.2'
            }
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It 'propagates successful local verification from the elevated child' {
        $result = Invoke-OpenSshServerEntry -RequireSuccess `
            -ScriptPath 'C:\src dir\scripts\enable-sshd.ps1'

        $result.Ready | Should -BeTrue
        $result.Success | Should -BeTrue
        $result.ElevatedProcessStarted | Should -BeTrue
        $result.ElevatedChildExitCode | Should -Be 0
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and
            $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
            ($ArgumentList -contains '-Elevated') -and
            ($ArgumentList -contains '-RequireSuccess')
        }
    }

    It 'does not recurse when an Elevated child is still non-admin' {
        $result = Invoke-OpenSshServerEntry -Elevated -ScriptPath 'C:\src\enable-sshd.ps1'

        $result.Ready | Should -BeFalse
        $result.RecoveryCommand | Should -BeExactly 'just enable-sshd'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'returns the one local recovery command when UAC is cancelled' {
        Mock Start-Process { throw 'The operation was canceled by the user.' }

        $result = Invoke-OpenSshServerEntry -ScriptPath 'C:\src\enable-sshd.ps1'

        $result.Ready | Should -BeFalse
        $result.RecoveryCommand | Should -BeExactly 'just enable-sshd'
        $result.Errors | Should -Contain 'Elevation was declined, cancelled, or unavailable.'
    }

    It 'propagates an elevated child setup failure without failing the parent process' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 23 } }

        $result = Invoke-OpenSshServerEntry -ScriptPath 'C:\src\enable-sshd.ps1'

        $result.Ready | Should -BeFalse
        $result.Success | Should -BeFalse
        $result.ElevatedProcessStarted | Should -BeTrue
        $result.ElevatedChildExitCode | Should -Be 23
        $result.RecoveryCommand | Should -BeExactly 'just enable-sshd'
        $result.Errors[0] | Should -Match 'exit code 23'
    }

    It 'does not attempt UAC when the embedded script has no usable path' {
        $result = Invoke-OpenSshServerEntry -ScriptPath $null

        $result.RecoveryCommand | Should -BeExactly 'just enable-sshd'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'never tries UAC or claims readiness from an SSH session' {
        Mock Test-SshSession { $true }

        $result = Invoke-OpenSshServerEntry -ScriptPath 'C:\src\enable-sshd.ps1'

        $result.Ready | Should -BeFalse
        $result.RecoveryCommand | Should -BeExactly 'just enable-sshd'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'reports recovery when no verified pwsh elevation path exists' {
        Mock Resolve-PwshExecutable { $null }

        $result = Invoke-OpenSshServerEntry -ScriptPath 'C:\src\enable-sshd.ps1'

        $result.Ready | Should -BeFalse
        $result.Errors[0] | Should -Match 'PowerShell Core 7'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

Describe 'OpenSSH installation source selection' {
    It 'preserves a running Microsoft MSI service when the capability is NotPresent' {
        $installation = [pscustomobject]@{
            UsableExisting = $true; ExistingSourcePresent = $true
            ExecutablePath = 'C:\Program Files\OpenSSH\sshd.exe'
        }
        $capability = [pscustomobject]@{ State = 'NotPresent'; Name = 'OpenSSH.Server~~~~0.0.1.0' }

        Get-OpenSshInstallDecision -Installation $installation -Capability $capability |
            Should -BeExactly 'UseExisting'
    }

    It 'installs the capability only when no executable or service exists' {
        $missing = [pscustomobject]@{
            UsableExisting = $false; ExistingSourcePresent = $false; ExecutablePath = $null
        }
        $capability = [pscustomobject]@{ State = 'NotPresent'; Name = 'OpenSSH.Server~~~~0.0.1.0' }
        $installed = [pscustomobject]@{
            UsableExisting = $true; ExistingSourcePresent = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Install-OpenSshCapability {}
        Mock Get-SshdInstallation { $installed }

        $result = Ensure-OpenSshSource -Installation $missing -Capability $capability -Changes $changes

        $result.ExecutablePath | Should -BeExactly 'C:\Windows\System32\OpenSSH\sshd.exe'
        $result.FreshCapabilityInstalled | Should -BeTrue
        $changes | Should -HaveCount 1
        Should -Invoke Install-OpenSshCapability -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'OpenSSH.Server~~~~0.0.1.0'
        }
    }

    It 'queries the exact OpenSSH capability name without enumerating' {
        Mock Get-WindowsCapability {
            [pscustomobject]@{ Name = 'OpenSSH.Server~~~~0.0.1.0'; State = 'NotPresent' }
        }

        $result = Get-OpenSshCapabilityInfo

        $result.Name | Should -BeExactly 'OpenSSH.Server~~~~0.0.1.0'
        Should -Invoke Get-WindowsCapability -Times 1 -Exactly -ParameterFilter {
            $Online -and $Name -eq 'OpenSSH.Server~~~~0.0.1.0'
        }
        Should -Invoke Get-WindowsCapability -Times 0 -Exactly -ParameterFilter {
            $Online -and -not $Name
        }
    }

    It 'falls back to exact-match enumeration only when Name binding is unsupported' {
        Mock Get-WindowsCapability {
            if ($Name) {
                throw [System.Management.Automation.ParameterBindingException]::new('Name unsupported')
            }
            return @(
                [pscustomobject]@{ Name = 'OpenSSH.Client~~~~0.0.1.0'; State = 'Installed' },
                [pscustomobject]@{ Name = 'OpenSSH.Server~~~~0.0.1.0'; State = 'Installed' }
            )
        }

        $result = Get-OpenSshCapabilityInfo

        $result.State | Should -BeExactly 'Installed'
        Should -Invoke Get-WindowsCapability -Times 2 -Exactly
    }

    It 'refuses a competing install when an existing source is incomplete' {
        $broken = [pscustomobject]@{
            UsableExisting = $false; ExistingSourcePresent = $true
            ExecutablePath = 'C:\Program Files\OpenSSH\sshd.exe'
        }
        $capability = [pscustomobject]@{ State = 'NotPresent'; Name = 'OpenSSH.Server~~~~0.0.1.0' }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Install-OpenSshCapability {}

        { Ensure-OpenSshSource -Installation $broken -Capability $capability -Changes $changes } |
            Should -Throw '*competing Windows capability*'
        Should -Invoke Install-OpenSshCapability -Times 0 -Exactly
    }

    It 'parses the service executable and quoted custom config path together' {
        $parsed = ConvertFrom-SshdServiceCommandLine `
            -PathName '"C:\Program Files\OpenSSH\sshd.exe" -f "D:\SSH Config\sshd_config" -E sshd.log'

        $parsed.ExecutablePath | Should -BeExactly 'C:\Program Files\OpenSSH\sshd.exe'
        $parsed.ConfigPath | Should -BeExactly 'D:\SSH Config\sshd_config'
    }

    It 'parses attached -fPATH and preserves equals in -f=PATH getopt arguments' {
        $attached = ConvertFrom-SshdServiceCommandLine `
            -PathName 'C:\OpenSSH\sshd.exe -fD:\ssh\attached.conf'
        $withEquals = ConvertFrom-SshdServiceCommandLine `
            -PathName 'C:\OpenSSH\sshd.exe -f=D:\ssh\equals.conf'

        $attached.ConfigPath | Should -BeExactly 'D:\ssh\attached.conf'
        $withEquals.ConfigPath | Should -BeExactly '=D:\ssh\equals.conf'
    }

    It '<Expectation> executable product identity' -TestCases @(
        @{
            ProductName = 'OpenSSH_for_Windows'; CompanyName = 'Microsoft Corporation'
            SignatureStatus = 'NotSigned'; SignerSubject = $null
            Expected = $true; Expectation = 'accepts Microsoft CompanyName'
        }
        @{
            ProductName = 'OpenSSH for Windows'; CompanyName = ''
            SignatureStatus = 'Valid'; SignerSubject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'
            Expected = $true; Expectation = 'accepts the genuine blank-company signed MSI'
        }
        @{
            ProductName = 'OpenSSH for Windows'; CompanyName = ''
            SignatureStatus = 'HashMismatch'; SignerSubject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'
            Expected = $false; Expectation = 'rejects an invalid Microsoft signature'
        }
        @{
            ProductName = 'OpenSSH for Windows'; CompanyName = ''
            SignatureStatus = 'Valid'; SignerSubject = 'CN=Other Vendor, O=Other Vendor, C=US'
            Expected = $false; Expectation = 'rejects a valid non-Microsoft signature'
        }
        @{
            ProductName = 'Cygwin'; CompanyName = ''
            SignatureStatus = 'Valid'; SignerSubject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'
            Expected = $false; Expectation = 'rejects a signed non-OpenSSH product'
        }
    ) {
        param(
            $ProductName, $CompanyName, $SignatureStatus, $SignerSubject,
            $Expected, $Expectation
        )
        $script:TestProductName = $ProductName
        $script:TestCompanyName = $CompanyName
        $script:TestSignatureStatus = $SignatureStatus
        $script:TestSignerSubject = $SignerSubject
        Mock Get-Item {
            [pscustomobject]@{
                VersionInfo = [pscustomobject]@{
                    ProductName = $script:TestProductName
                    CompanyName = $script:TestCompanyName
                    ProductVersion = '9.5.0.0'
                }
            }
        }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = $script:TestSignatureStatus
                SignerCertificate = if ($script:TestSignerSubject) {
                    [pscustomobject]@{ Subject = $script:TestSignerSubject }
                } else { $null }
            }
        }

        $result = Get-SshdExecutableInfo -Path 'C:\OpenSSH\sshd.exe'

        $Expectation | Should -Not -BeNullOrEmpty
        $result.IsMicrosoftOpenSsh | Should -Be $Expected
        if (-not $CompanyName -and $ProductName -match 'OpenSSH') {
            $result.AuthenticodeStatus | Should -BeExactly $SignatureStatus
        }
    }

    It 'requires the exact service executable to identify as OpenSSH for Windows' {
        Mock Get-SshdServiceInfo {
            [pscustomobject]@{
                Exists = $true; Status = 'Running'; StartType = 'Automatic'; ProcessId = 4321
                PathName = '"C:\Program Files\OpenSSH\sshd.exe" -f D:\ssh\custom.conf'
            }
        }
        Mock Test-Path { $LiteralPath -eq 'C:\Program Files\OpenSSH\sshd.exe' }
        Mock Get-SshdExecutableInfo {
            [pscustomobject]@{
                ProductName = 'OpenSSH for Windows'; ProductVersion = '9.5.0.0'
                IsMicrosoftOpenSsh = $true
            }
        }

        $result = Get-SshdInstallation

        $result.UsableExisting | Should -BeTrue
        $result.ExecutablePath | Should -BeExactly 'C:\Program Files\OpenSSH\sshd.exe'
        $result.ConfigPath | Should -BeExactly 'D:\ssh\custom.conf'
        $result.ProductVersion | Should -BeExactly '9.5.0.0'
    }

    It 'does not pair an unidentifiable or Cygwin service with a known OpenSSH file' {
        $oldProgramFiles = $env:ProgramFiles
        $env:ProgramFiles = 'C:\Program Files'
        Mock Get-SshdServiceInfo {
            [pscustomobject]@{
                Exists = $true; Status = 'Running'; StartType = 'Automatic'; ProcessId = 77
                PathName = 'C:\cygwin64\usr\sbin\sshd.exe'
            }
        }
        Mock Test-Path {
            $LiteralPath -in @(
                'C:\cygwin64\usr\sbin\sshd.exe',
                'C:\Program Files\OpenSSH\sshd.exe'
            )
        }
        Mock Get-SshdExecutableInfo {
            [pscustomobject]@{
                ProductName = 'Cygwin'; ProductVersion = '3.5.0'; IsMicrosoftOpenSsh = $false
            }
        }

        try {
            $result = Get-SshdInstallation
        } finally {
            $env:ProgramFiles = $oldProgramFiles
        }

        $result.UsableExisting | Should -BeFalse
        $result.ExecutablePath | Should -BeExactly 'C:\cygwin64\usr\sbin\sshd.exe'
        $result.ExistingSourcePresent | Should -BeTrue
    }
}

Describe 'real PowerShell 7 executable resolution' {
    BeforeEach {
        $script:OldScoop = $env:SCOOP
        $script:OldProgramFiles = $env:ProgramFiles
        $env:SCOOP = 'C:\CustomScoop'
        $env:ProgramFiles = 'C:\Program Files'
        Mock Get-Command { $null } -ParameterFilter { $Name -in @('pwsh.exe', 'pwsh') }
        Mock Get-PwshRuntimeInfo {
            [pscustomobject]@{ Path = $Path; Edition = 'Core'; Version = [version]'7.5.2'; Valid = $true }
        }
    }

    AfterEach {
        $env:SCOOP = $script:OldScoop
        $env:ProgramFiles = $script:OldProgramFiles
    }

    It 'permits the real Scoop executable only as a user-scoped fallback' {
        Mock Test-Path { $LiteralPath -eq 'C:\CustomScoop\apps\pwsh\current\pwsh.exe' }

        $result = Resolve-PwshExecutable

        $result.Source | Should -BeExactly 'Scoop'
        $result.Path | Should -BeExactly 'C:\CustomScoop\apps\pwsh\current\pwsh.exe'
        $result.UserScoped | Should -BeTrue
    }

    It 'prefers machine-wide MSI when both MSI and Scoop are valid' {
        Mock Test-Path {
            $LiteralPath -in @(
                'C:\Program Files\PowerShell\7\pwsh.exe',
                'C:\CustomScoop\apps\pwsh\current\pwsh.exe'
            )
        }

        $result = Resolve-PwshExecutable

        $result.Source | Should -BeExactly 'MSI'
        $result.UserScoped | Should -BeFalse
        Should -Invoke Get-PwshRuntimeInfo -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\Program Files\PowerShell\7\pwsh.exe'
        }
    }

    It 'reports the cross-account caveat for a user-scoped Scoop DefaultShell' {
        $status = New-TestSshdStatus
        $status.PwshUserScoped = $true

        $text = (& { Write-OpenSshStatus -Status $status } *>&1 | Out-String)

        $text | Should -Match 'user-scoped Scoop pwsh'
        $text | Should -Match 'Other SSH accounts may not have permission'
    }

    It 'uses the PowerShell 7 MSI path when available' {
        Mock Test-Path { $LiteralPath -eq 'C:\Program Files\PowerShell\7\pwsh.exe' }

        $result = Resolve-PwshExecutable

        $result.Source | Should -BeExactly 'MSI'
        $result.Path | Should -BeExactly 'C:\Program Files\PowerShell\7\pwsh.exe'
        $result.UserScoped | Should -BeFalse
    }

    It 'uses a real PATH executable after Scoop and MSI paths' {
        Mock Get-Command {
            [pscustomobject]@{ Source = 'D:\Tools\pwsh.exe'; Path = 'D:\Tools\pwsh.exe' }
        } -ParameterFilter { $Name -eq 'pwsh.exe' }
        Mock Test-Path { $LiteralPath -eq 'D:\Tools\pwsh.exe' }

        $result = Resolve-PwshExecutable

        $result.Source | Should -BeExactly 'PATH'
        $result.Path | Should -BeExactly 'D:\Tools\pwsh.exe'
    }

    It 'rejects a Scoop shim returned from PATH' {
        Mock Get-Command {
            [pscustomobject]@{
                Source = 'C:\Users\tester\scoop\shims\pwsh.exe'
                Path = 'C:\Users\tester\scoop\shims\pwsh.exe'
            }
        } -ParameterFilter { $Name -eq 'pwsh.exe' }
        Mock Test-Path { $LiteralPath -eq 'C:\Users\tester\scoop\shims\pwsh.exe' }
        Mock Get-PwshRuntimeInfo {
            throw 'A rejected shim must never be launched.'
        }

        Resolve-PwshExecutable | Should -BeNullOrEmpty
        Should -Invoke Get-PwshRuntimeInfo -Times 0 -Exactly
    }

    It 'rejects Windows PowerShell or a Core version below 7' {
        Mock Test-Path { $LiteralPath -eq 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-PwshRuntimeInfo {
            [pscustomobject]@{ Path = $Path; Edition = 'Desktop'; Version = [version]'5.1'; Valid = $false }
        }

        Resolve-PwshExecutable | Should -BeNullOrEmpty
    }
}

Describe 'sshd configuration, service, and listener checks' {
    It 'accepts sshd_config only when sshd -t succeeds' {
        Mock Test-Path { $true }
        Mock Invoke-NativeExecutable { [pscustomobject]@{ ExitCode = 0; Output = '' } }

        Test-SshdConfiguration -SshdPath 'C:\OpenSSH\sshd.exe' -ConfigPath 'C:\ProgramData\ssh\sshd_config' |
            Should -BeTrue
        Should -Invoke Invoke-NativeExecutable -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\OpenSSH\sshd.exe' -and
            ($ArgumentList -join '|') -eq '-t|-f|C:\ProgramData\ssh\sshd_config'
        }
    }

    It 'initializes fresh config and host keys without starting the service' {
        $fresh = [pscustomobject]@{
            FreshCapabilityInstalled = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true; StartType = 'Manual'; Status = 'Stopped' }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        $script:FreshConfigChecks = 0
        Mock Test-Path {
            if ($LiteralPath -eq 'C:\ProgramData\ssh\sshd_config') {
                $script:FreshConfigChecks++
                return ($script:FreshConfigChecks -ge 2)
            }
            return $true
        }
        Mock New-Item {}
        Mock Copy-Item {}
        Mock Invoke-NativeExecutable { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Test-SshdHostKeyEvidence { $true }
        Mock Set-Service {}
        Mock Start-Service {}

        Initialize-FreshOpenSshCapability -Installation $fresh `
            -ConfigPath 'C:\ProgramData\ssh\sshd_config' -Changes $changes

        Should -Invoke Copy-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'C:\Windows\System32\OpenSSH\sshd_config_default' -and
            $Destination -eq 'C:\ProgramData\ssh\sshd_config'
        }
        Should -Invoke Invoke-NativeExecutable -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Windows\System32\OpenSSH\ssh-keygen.exe' -and
            ($ArgumentList -join ' ') -eq '-A'
        }
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Set-Service -Times 0 -Exactly
        $changes | Should -HaveCount 2
    }

    It 'fails before service start when adjacent <MissingArtifact> is missing' -TestCases @(
        @{ MissingArtifact = 'sshd_config_default' }
        @{ MissingArtifact = 'ssh-keygen.exe' }
    ) {
        param($MissingArtifact)
        $fresh = [pscustomobject]@{
            FreshCapabilityInstalled = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Test-Path { -not $LiteralPath.EndsWith($MissingArtifact) }
        Mock Invoke-NativeExecutable {}
        Mock Start-Service {}

        { Initialize-FreshOpenSshCapability -Installation $fresh `
            -ConfigPath 'C:\ProgramData\ssh\sshd_config' -Changes $changes } |
            Should -Throw "*missing adjacent $MissingArtifact*"
        Should -Invoke Invoke-NativeExecutable -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'fails before service start when ssh-keygen returns nonzero' {
        $fresh = [pscustomobject]@{
            FreshCapabilityInstalled = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Test-Path { $true }
        Mock Invoke-NativeExecutable { [pscustomobject]@{ ExitCode = 7; Output = 'keygen failed' } }
        Mock Start-Service {}

        { Initialize-FreshOpenSshCapability -Installation $fresh `
            -ConfigPath 'C:\ProgramData\ssh\sshd_config' -Changes $changes } |
            Should -Throw '*ssh-keygen -A failed with exit code 7*'
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'fails before service start when ssh-keygen produces no host-key evidence' {
        $fresh = [pscustomobject]@{
            FreshCapabilityInstalled = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Test-Path { $true }
        Mock Invoke-NativeExecutable { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock Test-SshdHostKeyEvidence { $false }
        Mock Start-Service {}

        { Initialize-FreshOpenSshCapability -Installation $fresh `
            -ConfigPath 'C:\ProgramData\ssh\sshd_config' -Changes $changes } |
            Should -Throw '*no private ssh_host_*_key evidence*'
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'reacquires and validates the generated config after fresh pre-start initialization' {
        $fresh = [pscustomobject]@{
            FreshCapabilityInstalled = $true; ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            ConfigPath = $null; Service = [pscustomobject]@{ Exists = $true }
        }
        $refreshed = [pscustomobject]@{
            FreshCapabilityInstalled = $false; UsableExisting = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            ConfigPath = 'C:\ProgramData\ssh\sshd_config'
            Service = [pscustomobject]@{ Exists = $true }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Resolve-SshdConfigPath {
            if ($Installation.ConfigPath) { return $Installation.ConfigPath }
            return 'C:\ProgramData\ssh\sshd_config'
        }
        Mock Test-Path { $false }
        Mock Initialize-FreshOpenSshCapability {}
        Mock Get-SshdInstallation { $refreshed }
        Mock Test-SshdConfiguration { $true }

        $result = Resolve-ValidatedSshdRuntime -Installation $fresh -Changes $changes

        $result.Installation | Should -Be $refreshed
        $result.ConfigPath | Should -BeExactly 'C:\ProgramData\ssh\sshd_config'
        Should -Invoke Initialize-FreshOpenSshCapability -Times 1 -Exactly
        Should -Invoke Test-SshdConfiguration -Times 1 -Exactly -ParameterFilter {
            $SshdPath -eq $refreshed.ExecutablePath -and $ConfigPath -eq $refreshed.ConfigPath
        }
    }

    It 'never uses first-start initialization to bypass existing-server validation' {
        $existing = [pscustomobject]@{
            FreshCapabilityInstalled = $false
            Service = [pscustomobject]@{ Exists = $true; StartType = 'Manual'; Status = 'Stopped' }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Start-Service {}

        { Initialize-FreshOpenSshCapability -Installation $existing `
            -ConfigPath 'C:\ProgramData\ssh\sshd_config' -Changes $changes } |
            Should -Throw '*existing installation*'
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'fails an existing missing or invalid config without invoking fresh initialization' {
        $existing = [pscustomobject]@{
            FreshCapabilityInstalled = $false; UsableExisting = $true
            ExecutablePath = 'C:\Program Files\OpenSSH\sshd.exe'
            ConfigPath = 'D:\ssh\existing.conf'; Service = [pscustomobject]@{ Exists = $true }
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Initialize-FreshOpenSshCapability {}
        Mock Test-SshdConfiguration { $false }

        { Resolve-ValidatedSshdRuntime -Installation $existing -Changes $changes } |
            Should -Throw '*sshd_config is invalid*'
        Should -Invoke Initialize-FreshOpenSshCapability -Times 0 -Exactly
        Should -Invoke Test-SshdConfiguration -Times 1 -Exactly -ParameterFilter {
            $ConfigPath -eq 'D:\ssh\existing.conf'
        }
    }

    It 'accepts only a TCP 22 listener owned by the current sshd service process' {
        Mock Get-NetTCPConnection {
            @(
                [pscustomobject]@{ LocalPort = 22; OwningProcess = 9001 },
                [pscustomobject]@{ LocalPort = 22; OwningProcess = 4321 },
                [pscustomobject]@{ LocalPort = 2222; OwningProcess = 4321 }
            )
        }

        Test-Tcp22Listener -SshdProcessId 4321 | Should -BeTrue
        Test-Tcp22Listener -SshdProcessId 7777 | Should -BeFalse
        Should -Invoke Get-NetTCPConnection -Times 2 -Exactly -ParameterFilter {
            $State -eq 'Listen' -and $null -eq $LocalPort
        }
    }

    It 'propagates listener inspection failure instead of treating it as no listener' {
        Mock Get-NetTCPConnection { throw 'TCP table access denied' }

        { Test-Tcp22Listener -SshdProcessId 4321 } |
            Should -Throw '*TCP listener inspection failed*'
    }

    It 'does not restart sshd when listener inspection fails' {
        $service = [pscustomobject]@{ Exists = $true; StartType = 'Automatic'; Status = 'Running' }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Wait-SshdServiceRunning { $true }
        Mock Wait-Tcp22Listener { throw 'TCP listener inspection failed: denied' }
        Mock Restart-Service {}

        { Ensure-SshdService -Service $service -ConfigurationValid $true -Changes $changes } |
            Should -Throw '*TCP listener inspection failed*'
        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It 'refuses service changes when sshd_config is invalid' {
        $service = [pscustomobject]@{ Exists = $true; StartType = 'Manual'; Status = 'Stopped' }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Set-Service {}
        Mock Start-Service {}
        Mock Restart-Service {}

        { Ensure-SshdService -Service $service -ConfigurationValid $false -Changes $changes } |
            Should -Throw '*config validation failed*'
        Should -Invoke Set-Service -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It 'sets Automatic, starts the service, and requires a listener' {
        $service = [pscustomobject]@{ Exists = $true; StartType = 'Manual'; Status = 'Stopped' }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Set-Service {}
        Mock Start-Service {}
        Mock Restart-Service {}
        Mock Wait-SshdServiceRunning { $true }
        Mock Wait-Tcp22Listener { $true }

        Ensure-SshdService -Service $service -ConfigurationValid $true -Changes $changes

        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'sshd' -and $StartupType -eq 'Automatic'
        }
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'sshd' }
        Should -Invoke Restart-Service -Times 0 -Exactly
        $changes | Should -HaveCount 2
    }

    It 'restarts once locally when a running service has no listener' {
        $service = [pscustomobject]@{ Exists = $true; StartType = 'Automatic'; Status = 'Running' }
        $changes = [System.Collections.Generic.List[string]]::new()
        $script:ListenerChecks = 0
        Mock Wait-SshdServiceRunning { $true }
        Mock Wait-Tcp22Listener {
            $script:ListenerChecks++
            return ($script:ListenerChecks -ge 2)
        }
        Mock Test-SshSession { $false }
        Mock Restart-Service {}

        Ensure-SshdService -Service $service -ConfigurationValid $true -Changes $changes

        Should -Invoke Restart-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'sshd' }
    }

    It 'does not restart sshd from an active SSH connection' {
        $service = [pscustomobject]@{ Exists = $true; StartType = 'Automatic'; Status = 'Running' }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock Wait-SshdServiceRunning { $true }
        Mock Wait-Tcp22Listener { $false }
        Mock Test-SshSession { $true }
        Mock Restart-Service {}

        { Ensure-SshdService -Service $service -ConfigurationValid $true -Changes $changes } |
            Should -Throw '*active SSH session*'
        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It 'establishes firewall safety before service assurance on a fresh install' {
        $script:SetupOrder = [System.Collections.Generic.List[string]]::new()
        $installation = [pscustomobject]@{
            FreshCapabilityInstalled = $true; UsableExisting = $true
            ExistingSourcePresent = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true; StartType = 'Manual'; Status = 'Stopped' }
        }
        $final = New-TestSshdStatus -Ready
        Mock Test-Admin { $true }
        Mock Resolve-PwshExecutable {
            [pscustomobject]@{
                Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
                Source = 'MSI'; Edition = 'Core'; Version = [version]'7.5.2'
            }
        }
        Mock Get-OpenSshCapabilityInfo {
            [pscustomobject]@{ State = 'NotPresent'; Name = 'OpenSSH.Server~~~~0.0.1.0' }
        }
        Mock Get-SshdInstallation { $installation }
        Mock Ensure-OpenSshSource { $installation }
        Mock Resolve-ValidatedSshdRuntime {
            $script:SetupOrder.Add('config-validated')
            [pscustomobject]@{ Installation = $installation; ConfigPath = 'C:\ProgramData\ssh\sshd_config' }
        }
        Mock Get-ActiveSshNetworkProfileStatus {
            $script:SetupOrder.Add('network-safe')
            [pscustomobject]@{ AuditComplete = $true; HasSafeActiveProfile = $true }
        }
        Mock Get-SshFirewallStatus {
            $script:SetupOrder.Add('firewall-inspected')
            [pscustomobject]@{
                AuditComplete = $true
                Compatible = $true; PublicExposure = $false; BlockingConflict = $false
                Findings = @(); CompatibleRule = 'Safe'
            }
        }
        Mock Ensure-SshFirewall {
            $script:SetupOrder.Add('firewall-safe')
            return $null
        }
        Mock Ensure-SshdService { $script:SetupOrder.Add('service-assured') }
        Mock Get-OpenSshRegistryState {
            [pscustomobject]@{
                DefaultShellExists = $true
                DefaultShellValue = 'C:\Program Files\PowerShell\7\pwsh.exe'
                DefaultShellType = 'String'
                DefaultShellCommandOptionExists = $false
            }
        }
        Mock Write-CommandOptionStatus {}
        Mock Get-OpenSshServerStatus { $final }
        Mock Write-OpenSshStatus {}
        Mock Write-OpenSshSuccess {}
        Mock Start-Service {}

        $result = Invoke-OpenSshServerSetup

        $result.Ready | Should -BeTrue
        $script:SetupOrder | Should -Be @(
            'config-validated', 'network-safe', 'firewall-inspected', 'firewall-safe', 'service-assured'
        )
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'blocks a fresh service start when a Public allow rule is detected' {
        $installation = [pscustomobject]@{
            FreshCapabilityInstalled = $true; UsableExisting = $true
            ExistingSourcePresent = $true
            ExecutablePath = 'C:\Windows\System32\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true; StartType = 'Manual'; Status = 'Stopped' }
        }
        $failed = New-TestSshdStatus
        Mock Test-Admin { $true }
        Mock Resolve-PwshExecutable {
            [pscustomobject]@{
                Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
                Source = 'MSI'; Edition = 'Core'; Version = [version]'7.5.2'
            }
        }
        Mock Get-OpenSshCapabilityInfo {
            [pscustomobject]@{ State = 'NotPresent'; Name = 'OpenSSH.Server~~~~0.0.1.0' }
        }
        Mock Get-SshdInstallation { $installation }
        Mock Ensure-OpenSshSource { $installation }
        Mock Resolve-ValidatedSshdRuntime {
            [pscustomobject]@{ Installation = $installation; ConfigPath = 'C:\ProgramData\ssh\sshd_config' }
        }
        Mock Get-ActiveSshNetworkProfileStatus {
            [pscustomobject]@{ AuditComplete = $true; HasSafeActiveProfile = $true }
        }
        Mock Get-SshFirewallStatus {
            [pscustomobject]@{
                AuditComplete = $true
                Compatible = $false; PublicExposure = $true; BlockingConflict = $false
                Findings = @('Public: enabled inbound TCP 22 allow rule includes Public profile')
            }
        }
        Mock Ensure-SshdService {}
        Mock Start-Service {}
        Mock New-SafeSshFirewallRule {}
        Mock Get-OpenSshServerStatus { $failed }

        $result = Invoke-OpenSshServerSetup

        $result.Ready | Should -BeFalse
        Should -Invoke Ensure-SshdService -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke New-SafeSshFirewallRule -Times 0 -Exactly
    }
}

Describe 'sshd service rollback' {
    It 'stops a service started by setup and restores prior <PriorStartType>' -TestCases @(
        @{ PriorStartType = 'Manual' }
        @{ PriorStartType = 'Disabled' }
    ) {
        param($PriorStartType)
        $snapshot = [pscustomobject]@{
            Exists = $true; Status = 'Stopped'; StartType = $PriorStartType
        }
        $script:ServiceRollbackReads = 0
        $script:PriorStartType = $PriorStartType
        Mock Get-SshdServiceInfo {
            $script:ServiceRollbackReads++
            if ($script:ServiceRollbackReads -eq 1) {
                return [pscustomobject]@{
                    Exists = $true; Status = 'Running'; StartType = 'Automatic'
                }
            }
            if ($script:ServiceRollbackReads -eq 2) {
                return [pscustomobject]@{
                    Exists = $true; Status = 'Stopped'; StartType = 'Automatic'
                }
            }
            return [pscustomobject]@{
                Exists = $true; Status = 'Stopped'; StartType = $script:PriorStartType
            }
        }
        Mock Stop-Service {}
        Mock Set-Service {}
        Mock Wait-SshdServiceStatus { $true }

        Restore-SshdServiceState -Snapshot $snapshot

        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'sshd' -and $Force
        }
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'sshd' -and $StartupType -eq $script:PriorStartType
        }
    }

    It 'restores startup type without stopping an originally running service' {
        $snapshot = [pscustomobject]@{
            Exists = $true; Status = 'Running'; StartType = 'Manual'
        }
        $script:ServiceRollbackReads = 0
        Mock Get-SshdServiceInfo {
            $script:ServiceRollbackReads++
            if ($script:ServiceRollbackReads -eq 1) {
                return [pscustomobject]@{
                    Exists = $true; Status = 'Running'; StartType = 'Automatic'
                }
            }
            return [pscustomobject]@{
                Exists = $true; Status = 'Running'; StartType = 'Manual'
            }
        }
        Mock Stop-Service {}
        Mock Set-Service {}
        Mock Start-Service {}

        Restore-SshdServiceState -Snapshot $snapshot

        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter {
            $StartupType -eq 'Manual'
        }
        Should -Invoke Start-Service -Times 0 -Exactly
    }
}

Describe 'active network profile readiness' {
    It 'accepts an active Private or DomainAuthenticated profile' {
        Mock Get-NetConnectionProfile {
            @(
                [pscustomobject]@{ NetworkCategory = 'Public' },
                [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' }
            )
        }

        $status = Get-ActiveSshNetworkProfileStatus

        $status.AuditComplete | Should -BeTrue
        $status.HasSafeActiveProfile | Should -BeTrue
        $status.ActiveCategories | Should -Contain 'DomainAuthenticated'
    }

    It 'does not let a NoTraffic Private profile mask the active Public network' {
        Mock Get-NetConnectionProfile {
            @(
                [pscustomobject]@{
                    NetworkCategory = 'Private'
                    IPv4Connectivity = 'NoTraffic'
                    IPv6Connectivity = 'NoTraffic'
                },
                [pscustomobject]@{
                    NetworkCategory = 'Public'
                    IPv4Connectivity = 'Internet'
                    IPv6Connectivity = 'NoTraffic'
                }
            )
        }

        $status = Get-ActiveSshNetworkProfileStatus

        $status.HasSafeActiveProfile | Should -BeFalse
        $status.PublicOnly | Should -BeTrue
        $status.ActiveCategories | Should -Be @('Public')
    }

    It 'reports Public-only active networks as not locally ready with explicit guidance' {
        Mock Get-NetConnectionProfile {
            [pscustomobject]@{ NetworkCategory = 'Public' }
        }
        $network = Get-ActiveSshNetworkProfileStatus
        $status = New-TestSshdStatus
        $status.HasSafeActiveNetworkProfile = $network.HasSafeActiveProfile
        $status.PublicOnlyActiveNetwork = $network.PublicOnly
        $status.ActiveNetworkCategories = $network.ActiveCategories

        $text = (& { Write-OpenSshStatus -Status $status } *>&1 | Out-String)

        $network.HasSafeActiveProfile | Should -BeFalse
        $network.PublicOnly | Should -BeTrue
        $text | Should -Match 'Windows Settings locally'
        $text | Should -Match 'never reclassifies a network or opens Public'
    }

    It 'fails closed when active network inspection errors' {
        Mock Get-NetConnectionProfile { throw 'network query denied' }

        { Get-ActiveSshNetworkProfileStatus } |
            Should -Throw '*Active network profile inspection failed*'
    }

    It 'contains no network reclassification command' {
        (Get-Content -Raw -LiteralPath $script:SshdScript) |
            Should -Not -Match 'Set-NetConnectionProfile'
    }
}

Describe 'semantic firewall handling' {
    It 'preserves the Preview-named Private TCP 22 rule and reports RemoteAddress Any' {
        $rule = [pscustomobject]@{
            Name = 'OpenSSH-Server-Preview-In-TCP'; DisplayName = 'OpenSSH SSH Server Preview'
            Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'Any'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }

        $status = Get-SshFirewallStatus -Rules @($rule)

        $status.Compatible | Should -BeTrue
        $status.Safe | Should -BeFalse
        $status.Overbroad | Should -BeTrue
        $status.CompatibleRule | Should -BeExactly 'OpenSSH-Server-Preview-In-TCP'
        $status.Findings[0] | Should -Match 'broader than LocalSubnet'
    }

    It 'rejects a single unrelated remote IP and creates the safe baseline rule' {
        $rule = [pscustomobject]@{
            Name = 'NarrowOtherHost'; DisplayName = 'Narrow other host'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = '203.0.113.10'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock New-SafeSshFirewallRule { 'Dotfiles-Safe' }

        $status = Get-SshFirewallStatus -Rules @($rule)
        $created = Ensure-SshFirewall -FirewallStatus $status -Changes $changes

        $status.Compatible | Should -BeFalse
        ($status.Findings -join "`n") | Should -Match 'remote scope does not cover Any or LocalSubnet'
        $created | Should -BeExactly 'Dotfiles-Safe'
    }

    It 'fails readiness when a Public or Any-profile allow rule exists beside a safe rule' {
        $safe = [pscustomobject]@{
            Name = 'Safe'; DisplayName = 'Safe SSH'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }
        $public = [pscustomobject]@{
            Name = 'Public'; DisplayName = 'Public SSH'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'
            Protocol = 'Any'; LocalPort = '22'; RemoteAddress = 'Any'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock New-SafeSshFirewallRule {}

        $status = Get-SshFirewallStatus -Rules @($safe, $public) `
            -SelectedSshdPath 'C:\Program Files\OpenSSH\sshd.exe'

        $status.Compatible | Should -BeTrue
        $status.PublicExposure | Should -BeTrue
        ($status.Findings -join "`n") | Should -Match 'includes Public profile'
        { Ensure-SshFirewall -FirewallStatus $status -Changes $changes } |
            Should -Throw '*Public/Any profile*'
        Should -Invoke New-SafeSshFirewallRule -Times 0 -Exactly
    }

    It 'ignores AppX-scoped Any-protocol Any-port rules for SSH exposure' {
        $appx = [pscustomobject]@{
            Name = 'Store-App'; DisplayName = 'Microsoft Store'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'
            Protocol = 'Any'; LocalPort = 'Any'; RemoteAddress = 'Any'
            Program = 'Any'; Package = 'S-1-15-2-12345'; Service = 'Any'
            InterfaceAlias = 'Any'; ScopeKnown = $true
        }

        $status = Get-SshFirewallStatus -Rules @($appx) `
            -SelectedSshdPath 'C:\Program Files\OpenSSH\sshd.exe'

        $status.Compatible | Should -BeFalse
        $status.PublicExposure | Should -BeFalse
        $status.BlockingConflict | Should -BeFalse
        $status.Findings | Should -HaveCount 0
    }

    It 'fails readiness for an enabled overlapping Domain Private TCP 22 block rule' {
        $allow = [pscustomobject]@{
            Name = 'Allow'; DisplayName = 'Allow SSH'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }
        $block = [pscustomobject]@{
            Name = 'Block'; DisplayName = 'Block SSH'; Enabled = $true
            Direction = 'Inbound'; Action = 'Block'; Profile = @('Domain', 'Private')
            Protocol = 'Any'; LocalPort = 'Any'; RemoteAddress = 'Any'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        Mock New-SafeSshFirewallRule {}

        $status = Get-SshFirewallStatus -Rules @($allow, $block) `
            -SelectedSshdPath 'C:\Program Files\OpenSSH\sshd.exe'

        $status.Compatible | Should -BeTrue
        $status.BlockingConflict | Should -BeTrue
        ($status.Findings -join "`n") | Should -Match 'block rule overlaps Domain/Private'
        { Ensure-SshFirewall -FirewallStatus $status -Changes $changes } |
            Should -Throw '*block rule overlaps*'
        Should -Invoke New-SafeSshFirewallRule -Times 0 -Exactly
    }

    It 'never marks final status Ready with <Conflict>' -TestCases @(
        @{ Conflict = 'Public exposure'; PublicExposure = $true; BlockingConflict = $false }
        @{ Conflict = 'an overlapping block'; PublicExposure = $false; BlockingConflict = $true }
    ) {
        param($Conflict, $PublicExposure, $BlockingConflict)
        $script:TestPublicExposure = $PublicExposure
        $script:TestBlockingConflict = $BlockingConflict
        Mock Resolve-PwshExecutable {
            [pscustomobject]@{
                Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Source = 'MSI'
                Edition = 'Core'; Version = [version]'7.5.2'
            }
        }
        Mock Get-OpenSshCapabilityInfo {
            [pscustomobject]@{ Name = 'OpenSSH.Server~~~~0.0.1.0'; State = 'NotPresent' }
        }
        Mock Get-SshdInstallation {
            [pscustomobject]@{
                UsableExisting = $true; ExistingSourcePresent = $true
                ExecutablePath = 'C:\Program Files\OpenSSH\sshd.exe'
                ConfigPath = $null; Source = 'ExistingMicrosoftOpenSSH'
                ProductName = 'OpenSSH for Windows'; ProductVersion = '9.5.0.0'
                Service = [pscustomobject]@{
                    Exists = $true; StartType = 'Automatic'; Status = 'Running'; ProcessId = 4321
                }
            }
        }
        Mock Resolve-SshdConfigPath { 'C:\ProgramData\ssh\sshd_config' }
        Mock Test-SshdConfiguration { $true }
        Mock Test-Tcp22Listener { $true }
        Mock Get-ActiveSshNetworkProfileStatus {
            [pscustomobject]@{
                AuditComplete = $true; HasSafeActiveProfile = $true
                ActiveCategories = @('Private'); PublicOnly = $false
            }
        }
        Mock Get-SshFirewallStatus {
            [pscustomobject]@{
                AuditComplete = $true
                Compatible = $true; Safe = $true; Overbroad = $false
                PublicExposure = $script:TestPublicExposure
                BlockingConflict = $script:TestBlockingConflict
                CompatibleRule = 'Safe'; Findings = @()
            }
        }
        Mock Get-OpenSshRegistryState {
            [pscustomobject]@{
                DefaultShellExists = $true
                DefaultShellValue = 'C:\Program Files\PowerShell\7\pwsh.exe'
                DefaultShellType = 'String'
                DefaultShellCommandOptionExists = $false
                DefaultShellCommandOptionValue = $null
                DefaultShellCommandOptionType = $null
            }
        }

        $status = Get-OpenSshServerStatus

        $Conflict | Should -Not -BeNullOrEmpty
        $status.Ready | Should -BeFalse
    }

    It 'accepts a rule proven to target the selected sshd executable and service' {
        $rule = [pscustomobject]@{
            Name = 'ScopedSshd'; DisplayName = 'Scoped sshd'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
            Program = 'C:\Program Files\OpenSSH\sshd.exe'; Service = 'sshd'
            InterfaceAlias = 'Any'; ScopeKnown = $true
        }

        $status = Get-SshFirewallStatus -Rules @($rule) `
            -SelectedSshdPath 'C:\Program Files\OpenSSH\sshd.exe'

        $status.Compatible | Should -BeTrue
    }

    It 'rejects allow rules with <Case>' -TestCases @(
        @{
            Case = 'unknown filters'; ScopeKnown = $false; Program = $null
            Service = $null; InterfaceAlias = $null; Expected = 'filters are unknown'
        }
        @{
            Case = 'another application'; ScopeKnown = $true; Program = 'C:\Other\server.exe'
            Service = 'Any'; InterfaceAlias = 'Any'; Expected = 'does not target selected sshd'
        }
        @{
            Case = 'another service'; ScopeKnown = $true; Program = 'Any'
            Service = 'OtherService'; InterfaceAlias = 'Any'; Expected = 'does not target sshd'
        }
        @{
            Case = 'a specific interface'; ScopeKnown = $true; Program = 'Any'
            Service = 'Any'; InterfaceAlias = 'Ethernet'; Expected = 'interface filter is scoped'
        }
    ) {
        param($Case, $ScopeKnown, $Program, $Service, $InterfaceAlias, $Expected)
        $rule = [pscustomobject]@{
            Name = "Scoped-$Case"; DisplayName = "Scoped $Case"; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
            Program = $Program; Service = $Service; InterfaceAlias = $InterfaceAlias
            ScopeKnown = $ScopeKnown
        }

        $status = Get-SshFirewallStatus -Rules @($rule) `
            -SelectedSshdPath 'C:\Program Files\OpenSSH\sshd.exe'

        $status.Compatible | Should -BeFalse
        ($status.Findings -join "`n") | Should -Match ([regex]::Escape($Expected))
    }

    It 'detects disabled and wrong-direction rules instead of trusting their names' {
        $rules = @(
            [pscustomobject]@{
                Name = 'OpenSSH-Server-In-TCP'; DisplayName = 'OpenSSH Server'
                Enabled = $false; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
                Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
                Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
            },
            [pscustomobject]@{
                Name = 'Friendly-SSH'; DisplayName = 'Friendly SSH'
                Enabled = $true; Direction = 'Outbound'; Action = 'Allow'; Profile = 'Private'
                Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
                Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
            }
        )

        $status = Get-SshFirewallStatus -Rules $rules

        $status.Compatible | Should -BeFalse
        ($status.Findings -join "`n") | Should -Match 'disabled'
        ($status.Findings -join "`n") | Should -Match 'not inbound'
    }

    It 'rejects a named rule with <Case>' -TestCases @(
        @{
            Case = 'UDP protocol'; Protocol = 'UDP'; LocalPort = '22'
            Action = 'Allow'; RuleProfile = 'Private'; Expected = 'not TCP'
        }
        @{
            Case = 'the wrong port'; Protocol = 'TCP'; LocalPort = '2222'
            Action = 'Allow'; RuleProfile = 'Private'; Expected = 'not local port 22'
        }
        @{
            Case = 'a block action'; Protocol = 'TCP'; LocalPort = '22'
            Action = 'Block'; RuleProfile = 'Private'; Expected = 'block rule overlaps Domain/Private'
        }
        @{
            Case = 'a Public-only profile'; Protocol = 'TCP'; LocalPort = '22'
            Action = 'Allow'; RuleProfile = 'Public'; Expected = 'includes Public profile'
        }
    ) {
        param($Case, $Protocol, $LocalPort, $Action, $RuleProfile, $Expected)
        $rule = [pscustomobject]@{
            Name = "OpenSSH-$Case"; DisplayName = "OpenSSH $Case"; Enabled = $true
            Direction = 'Inbound'; Action = $Action; Profile = $RuleProfile
            Protocol = $Protocol; LocalPort = $LocalPort; RemoteAddress = 'LocalSubnet'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }

        $status = Get-SshFirewallStatus -Rules @($rule)

        $status.Compatible | Should -BeFalse
        ($status.Findings -join "`n") | Should -Match ([regex]::Escape($Expected))
    }

    It 'enumerates six stores once, hash-joins candidates, and skips AppX Any-port noise' {
        $namedRule = [pscustomobject]@{
            InstanceID = 'named-malformed'; Name = 'OpenSSH-Broken'; DisplayName = 'OpenSSH broken rule'
            Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
        }
        $port22Rule = [pscustomobject]@{
            InstanceID = 'port-22'; Name = 'Corp-Remote-Admin'; DisplayName = 'Remote admin'
            Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
        }
        $appxRule = [pscustomobject]@{
            InstanceID = 'appx-any'; Name = 'Store-App'; DisplayName = 'Store app'
            Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'
        }
        $unrelated = 1..50 | ForEach-Object {
            [pscustomobject]@{
                InstanceID = "unrelated-$_"; Name = "Unrelated-$_"; DisplayName = "Unrelated $_"
                Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            }
        }
        $allRules = @($unrelated) + @($namedRule, $port22Rule, $appxRule)
        $portFilters = @(
            [pscustomobject]@{ InstanceID = 'named-malformed'; Protocol = 'UDP'; LocalPort = '2222' },
            [pscustomobject]@{ InstanceID = 'port-22'; Protocol = 'TCP'; LocalPort = '22' },
            [pscustomobject]@{ InstanceID = 'appx-any'; Protocol = 'Any'; LocalPort = 'Any' },
            [pscustomobject]@{ InstanceID = 'unrelated-1'; Protocol = 'TCP'; LocalPort = '443' }
        )
        $addresses = @(
            [pscustomobject]@{ InstanceID = 'named-malformed'; RemoteAddress = 'LocalSubnet' },
            [pscustomobject]@{ InstanceID = 'port-22'; RemoteAddress = 'LocalSubnet' }
        )
        $applications = @(
            [pscustomobject]@{ InstanceID = 'named-malformed'; Program = 'Any'; Package = 'Any' },
            [pscustomobject]@{ InstanceID = 'port-22'; Program = 'Any'; Package = 'Any' },
            [pscustomobject]@{ InstanceID = 'appx-any'; Program = 'Any'; Package = 'S-1-15-2-12345' }
        )
        $services = @(
            [pscustomobject]@{ InstanceID = 'named-malformed'; Service = 'Any' },
            [pscustomobject]@{ InstanceID = 'port-22'; Service = 'Any' }
        )
        $interfaces = @(
            [pscustomobject]@{ InstanceID = 'named-malformed'; InterfaceAlias = 'Any' },
            [pscustomobject]@{ InstanceID = 'port-22'; InterfaceAlias = 'Any' }
        )
        Mock Get-NetFirewallRule { $allRules }
        Mock Get-NetFirewallPortFilter { $portFilters }
        Mock Get-NetFirewallAddressFilter { $addresses }
        Mock Get-NetFirewallApplicationFilter { $applications }
        Mock Get-NetFirewallServiceFilter { $services }
        Mock Get-NetFirewallInterfaceFilter { $interfaces }

        $rules = @(Get-EffectiveSshFirewallRules)
        $status = Get-SshFirewallStatus -Rules $rules

        $rules | Should -HaveCount 2
        $status.Compatible | Should -BeTrue
        ($rules.Name -join ',') | Should -Not -Match 'Store-App'
        ($status.Findings -join "`n") | Should -Match 'OpenSSH-Broken: not TCP; not local port 22'
        Should -Invoke Get-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Get-NetFirewallPortFilter -Times 1 -Exactly -ParameterFilter {
            $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Get-NetFirewallAddressFilter -Times 1 -Exactly -ParameterFilter {
            $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Get-NetFirewallApplicationFilter -Times 1 -Exactly -ParameterFilter {
            $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Get-NetFirewallServiceFilter -Times 1 -Exactly -ParameterFilter {
            $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Get-NetFirewallInterfaceFilter -Times 1 -Exactly -ParameterFilter {
            $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Get-NetFirewallRule -Times 0 -Exactly -ParameterFilter {
            $null -ne $AssociatedNetFirewallPortFilter
        }
        Should -Invoke Get-NetFirewallPortFilter -Times 0 -Exactly -ParameterFilter {
            $null -ne $AssociatedNetFirewallRule
        }
        Should -Invoke Get-NetFirewallAddressFilter -Times 0 -Exactly -ParameterFilter {
            $null -ne $AssociatedNetFirewallRule
        }
        Should -Invoke Get-NetFirewallApplicationFilter -Times 0 -Exactly -ParameterFilter {
            $null -ne $AssociatedNetFirewallRule
        }
        Should -Invoke Get-NetFirewallServiceFilter -Times 0 -Exactly -ParameterFilter {
            $null -ne $AssociatedNetFirewallRule
        }
        Should -Invoke Get-NetFirewallInterfaceFilter -Times 0 -Exactly -ParameterFilter {
            $null -ne $AssociatedNetFirewallRule
        }
        Get-Command Get-FirewallRulesForPortFilter -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
        Get-Command Get-FirewallFiltersForRule -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'catches generic Any-port Public exposure while ignoring equivalent AppX scope' {
        $rules = @(
            [pscustomobject]@{
                InstanceID = 'generic-any'; Name = 'Generic'; DisplayName = 'Generic'
                Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'
            },
            [pscustomobject]@{
                InstanceID = 'appx-any'; Name = 'AppX'; DisplayName = 'AppX'
                Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'
            },
            [pscustomobject]@{
                InstanceID = 'appx-exact'; Name = 'AppXExact'; DisplayName = 'AppX exact port'
                Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'
            }
        )
        $ports = @(
            [pscustomobject]@{ InstanceID = 'generic-any'; Protocol = 'Any'; LocalPort = 'Any' },
            [pscustomobject]@{ InstanceID = 'appx-any'; Protocol = 'Any'; LocalPort = 'Any' },
            [pscustomobject]@{ InstanceID = 'appx-exact'; Protocol = 'Any'; LocalPort = '22' }
        )
        $applications = @(
            [pscustomobject]@{ InstanceID = 'generic-any'; Program = 'Any'; Package = 'Any' },
            [pscustomobject]@{ InstanceID = 'appx-any'; Program = 'Any'; Package = 'S-1-15-2-12345' },
            [pscustomobject]@{ InstanceID = 'appx-exact'; Program = 'Any'; Package = 'S-1-15-2-67890' }
        )
        Mock Get-NetFirewallRule { $rules }
        Mock Get-NetFirewallPortFilter { $ports }
        Mock Get-NetFirewallAddressFilter {
            @(
                [pscustomobject]@{ InstanceID = 'generic-any'; RemoteAddress = 'Any' },
                [pscustomobject]@{ InstanceID = 'appx-exact'; RemoteAddress = 'Any' }
            )
        }
        Mock Get-NetFirewallApplicationFilter { $applications }
        Mock Get-NetFirewallServiceFilter {
            @(
                [pscustomobject]@{ InstanceID = 'generic-any'; Service = 'Any' },
                [pscustomobject]@{ InstanceID = 'appx-exact'; Service = 'Any' }
            )
        }
        Mock Get-NetFirewallInterfaceFilter {
            @(
                [pscustomobject]@{ InstanceID = 'generic-any'; InterfaceAlias = 'Any' },
                [pscustomobject]@{ InstanceID = 'appx-exact'; InterfaceAlias = 'Any' }
            )
        }

        $normalized = @(Get-EffectiveSshFirewallRules)
        $status = Get-SshFirewallStatus -Rules $normalized

        $normalized | Should -HaveCount 2
        ($normalized.Name -join ',') | Should -Match 'Generic'
        ($normalized.Name -join ',') | Should -Match 'AppXExact'
        ($normalized.Name -join ',') | Should -Not -Match '(^|,)AppX(,|$)'
        $status.PublicExposure | Should -BeTrue
        ($status.Findings -join "`n") | Should -Match 'AppXExact.*application filter is scoped to an AppX package'
    }

    It 'fails the entire firewall audit when a candidate map join is incomplete' {
        $rule = [pscustomobject]@{
            InstanceID = 'broken-audit'; Name = 'OpenSSH-Audit'; DisplayName = 'OpenSSH audit'
            Enabled = $true; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
        }
        Mock Get-NetFirewallRule { $rule }
        Mock Get-NetFirewallPortFilter {
            [pscustomobject]@{ InstanceID = 'broken-audit'; Protocol = 'TCP'; LocalPort = '22' }
        }
        Mock Get-NetFirewallAddressFilter { @() }
        Mock Get-NetFirewallApplicationFilter {
            [pscustomobject]@{ InstanceID = 'broken-audit'; Program = 'Any'; Package = 'Any' }
        }
        Mock Get-NetFirewallServiceFilter {
            [pscustomobject]@{ InstanceID = 'broken-audit'; Service = 'Any' }
        }
        Mock Get-NetFirewallInterfaceFilter {
            [pscustomobject]@{ InstanceID = 'broken-audit'; InterfaceAlias = 'Any' }
        }

        { Get-EffectiveSshFirewallRules } |
            Should -Throw '*Firewall audit incomplete*incomplete InstanceID filter join*'
    }

    It 'fails the entire firewall audit on duplicate InstanceID ambiguity' {
        Mock Get-NetFirewallRule {
            @(
                [pscustomobject]@{ InstanceID = 'duplicate'; Name = 'One'; DisplayName = 'One' },
                [pscustomobject]@{ InstanceID = 'DUPLICATE'; Name = 'Two'; DisplayName = 'Two' }
            )
        }
        Mock Get-NetFirewallPortFilter { @() }
        Mock Get-NetFirewallAddressFilter { @() }
        Mock Get-NetFirewallApplicationFilter { @() }
        Mock Get-NetFirewallServiceFilter { @() }
        Mock Get-NetFirewallInterfaceFilter { @() }

        { Get-EffectiveSshFirewallRules } |
            Should -Throw '*duplicate ambiguous InstanceID*'
    }

    It 'never treats a compatible rule from an incomplete audit as ready' {
        $rule = [pscustomobject]@{
            Name = 'Safe'; DisplayName = 'Safe SSH'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Private'
            Protocol = 'TCP'; LocalPort = '22'; RemoteAddress = 'LocalSubnet'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }
        $changes = [System.Collections.Generic.List[string]]::new()
        $status = Get-SshFirewallStatus -Rules @($rule) -AuditComplete $false

        $status.Compatible | Should -BeTrue
        $status.AuditComplete | Should -BeFalse
        { Ensure-SshFirewall -FirewallStatus $status -Changes $changes } |
            Should -Throw '*Firewall audit is incomplete*'
    }

    It 'recognizes the Domain Private LocalSubnet baseline as safe' {
        $rule = [pscustomobject]@{
            Name = 'Safe'; DisplayName = 'Safe SSH'; Enabled = $true
            Direction = 'Inbound'; Action = 'Allow'; Profile = @('Domain', 'Private')
            Protocol = '6'; LocalPort = 22; RemoteAddress = 'LocalSubnet'
            Program = 'Any'; Service = 'Any'; InterfaceAlias = 'Any'; ScopeKnown = $true
        }

        $status = Get-SshFirewallStatus -Rules @($rule)

        $status.Compatible | Should -BeTrue
        $status.Safe | Should -BeTrue
        $status.Overbroad | Should -BeFalse
    }

    It 'creates only a Domain Private LocalSubnet rule when none is compatible' {
        Mock Get-NetFirewallRule { $null }
        Mock New-NetFirewallRule {}

        $name = New-SafeSshFirewallRule

        $name | Should -BeExactly 'Dotfiles-OpenSSH-Server-In-TCP'
        Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $Direction -eq 'Inbound' -and $Action -eq 'Allow' -and
            $Protocol -eq 'TCP' -and (@($LocalPort) -join ',') -eq '22' -and
            ((@($Profile) -join ',') -replace '\s', '') -eq 'Domain,Private' -and
            (@($RemoteAddress) -join ',') -eq 'LocalSubnet'
        }
    }
}

Describe 'DefaultShell readback and rollback' {
    It 'reads REG_EXPAND_SZ values without expanding environment names' {
        $script:RawRegistryOptions = [System.Collections.Generic.List[string]]::new()
        $key = [pscustomobject]@{}
        $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value {
            @('DefaultShell', 'DefaultShellCommandOption')
        }
        $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
            param($name, $defaultValue, $options)
            $null = $defaultValue
            $script:RawRegistryOptions.Add($options.ToString())
            if ($name -eq 'DefaultShell') { return '%SystemRoot%\System32\cmd.exe' }
            return '/c'
        }
        $key | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value {
            param($name)
            if ($name -eq 'DefaultShell') {
                return [Microsoft.Win32.RegistryValueKind]::ExpandString
            }
            return [Microsoft.Win32.RegistryValueKind]::String
        }
        Mock Test-Path { $true }
        Mock Get-Item { $key }

        $result = Get-OpenSshRegistryState

        $result.DefaultShellValue | Should -BeExactly '%SystemRoot%\System32\cmd.exe'
        $result.DefaultShellType | Should -BeExactly 'ExpandString'
        $result.DefaultShellCommandOptionValue | Should -BeExactly '/c'
        $script:RawRegistryOptions | Should -Be @(
            'DoNotExpandEnvironmentNames', 'DoNotExpandEnvironmentNames'
        )
    }

    It 'writes only DefaultShell and verifies value and type by readback' {
        $readback = [pscustomobject]@{
            DefaultShellExists = $true
            DefaultShellValue = 'C:\Program Files\PowerShell\7\pwsh.exe'
            DefaultShellType = 'String'
        }
        Mock Test-Path { $true }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Get-OpenSshRegistryState { $readback }

        $result = Set-OpenSshDefaultShell -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe'

        $result.DefaultShellValue | Should -BeExactly 'C:\Program Files\PowerShell\7\pwsh.exe'
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'DefaultShell' -and
            $Value -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and
            $PropertyType -eq 'String'
        }
    }

    It 'restores the exact prior DefaultShell value and registry type' {
        $snapshot = [pscustomobject]@{
            DefaultShellExists = $true
            DefaultShellValue = '%SystemRoot%\System32\cmd.exe'
            DefaultShellType = 'ExpandString'
        }
        $readback = [pscustomobject]@{
            DefaultShellExists = $true
            DefaultShellValue = '%SystemRoot%\System32\cmd.exe'
            DefaultShellType = 'ExpandString'
        }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Get-OpenSshRegistryState { $readback }

        $result = Restore-OpenSshDefaultShell -Snapshot $snapshot

        $result.DefaultShellValue | Should -BeExactly '%SystemRoot%\System32\cmd.exe'
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'DefaultShell' -and
            $Value -eq '%SystemRoot%\System32\cmd.exe' -and
            $PropertyType -eq 'ExpandString'
        }
    }

    It 'removes DefaultShell on rollback when it did not previously exist' {
        $snapshot = [pscustomobject]@{
            DefaultShellExists = $false; DefaultShellValue = $null; DefaultShellType = $null
        }
        $script:RollbackRegistryReads = 0
        Mock Get-OpenSshRegistryState {
            $script:RollbackRegistryReads++
            if ($script:RollbackRegistryReads -eq 1) {
                return [pscustomobject]@{
                    DefaultShellExists = $true; DefaultShellValue = 'temporary'; DefaultShellType = 'String'
                }
            }
            return [pscustomobject]@{
                DefaultShellExists = $false; DefaultShellValue = $null; DefaultShellType = $null
            }
        }
        Mock Remove-ItemProperty {}

        $result = Restore-OpenSshDefaultShell -Snapshot $snapshot

        $result.DefaultShellExists | Should -BeFalse
        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'DefaultShell' -and $ErrorAction -eq 'Stop'
        }
    }

    It 'throws when rollback readback does not match the prior value or type' {
        $snapshot = [pscustomobject]@{
            DefaultShellExists = $true
            DefaultShellValue = '%SystemRoot%\System32\cmd.exe'
            DefaultShellType = 'ExpandString'
        }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Get-OpenSshRegistryState {
            [pscustomobject]@{
                DefaultShellExists = $true
                DefaultShellValue = '%SystemRoot%\System32\cmd.exe'
                DefaultShellType = 'String'
            }
        }

        { Restore-OpenSshDefaultShell -Snapshot $snapshot } |
            Should -Throw '*rollback readback did not exactly match*'
    }

    It 'propagates permission errors while removing a newly created DefaultShell' {
        $snapshot = [pscustomobject]@{
            DefaultShellExists = $false; DefaultShellValue = $null; DefaultShellType = $null
        }
        Mock Get-OpenSshRegistryState {
            [pscustomobject]@{
                DefaultShellExists = $true; DefaultShellValue = 'temporary'; DefaultShellType = 'String'
            }
        }
        Mock Remove-ItemProperty { throw 'Requested registry access is not allowed.' }

        { Restore-OpenSshDefaultShell -Snapshot $snapshot } |
            Should -Throw '*registry access is not allowed*'
    }

    It 'contains no writer for DefaultShellCommandOption' {
        $source = Get-Content -Raw -LiteralPath $script:SshdScript
        $source | Should -Not -Match '(?is)New-ItemProperty.{0,250}-Name\s+[''\"]DefaultShellCommandOption'
        $source | Should -Not -Match '(?is)Set-ItemProperty.{0,250}-Name\s+[''\"]DefaultShellCommandOption'
    }

    It 'rolls back DefaultShell and only the firewall rule created by this invocation' {
        $installation = [pscustomobject]@{
            UsableExisting = $true; ExistingSourcePresent = $true
            ExecutablePath = 'C:\Program Files\OpenSSH\sshd.exe'
            Service = [pscustomobject]@{ Exists = $true; StartType = 'Automatic'; Status = 'Running' }
        }
        $snapshot = [pscustomobject]@{
            DefaultShellExists = $false; DefaultShellValue = $null; DefaultShellType = $null
            DefaultShellCommandOptionExists = $true
            DefaultShellCommandOptionValue = '-sshs'
            DefaultShellCommandOptionType = 'String'
        }
        $final = New-TestSshdStatus -Ready:$false
        Mock Test-Admin { $true }
        Mock Resolve-PwshExecutable {
            [pscustomobject]@{
                Path = 'C:\Program Files\PowerShell\7\pwsh.exe'
                Source = 'MSI'; Edition = 'Core'; Version = [version]'7.5.2'
            }
        }
        Mock Get-OpenSshCapabilityInfo {
            [pscustomobject]@{ State = 'NotPresent'; Name = 'OpenSSH.Server~~~~0.0.1.0'; Error = $null }
        }
        Mock Get-SshdInstallation { $installation }
        Mock Ensure-OpenSshSource { $installation }
        Mock Resolve-ValidatedSshdRuntime {
            [pscustomobject]@{
                Installation = $installation
                ConfigPath = 'C:\ProgramData\ssh\sshd_config'
            }
        }
        Mock Get-ActiveSshNetworkProfileStatus {
            [pscustomobject]@{ AuditComplete = $true; HasSafeActiveProfile = $true }
        }
        Mock Ensure-SshdService {}
        Mock Get-SshFirewallStatus {
            [pscustomobject]@{ Compatible = $false; Findings = @() }
        }
        Mock Ensure-SshFirewall { 'Dotfiles-created-this-run' }
        Mock Get-OpenSshRegistryState { $snapshot }
        Mock Write-CommandOptionStatus {}
        Mock Set-OpenSshDefaultShell { $snapshot }
        Mock Get-OpenSshServerStatus { $final }
        Mock Restore-SshdServiceState { throw 'service rollback denied' }
        Mock Restore-OpenSshDefaultShell {}
        Mock Remove-NetFirewallRule {}

        $result = Invoke-OpenSshServerSetup

        $result.Success | Should -BeFalse
        $result.Ready | Should -BeFalse
        ($result.Errors -join "`n") | Should -Match 'sshd service rollback failed: service rollback denied'
        Should -Invoke Restore-OpenSshDefaultShell -Times 1 -Exactly -ParameterFilter {
            $Snapshot.DefaultShellExists -eq $false
        }
        Should -Invoke Remove-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Dotfiles-created-this-run'
        }
    }
}

Describe 'truthful verification messages' {
    It 'states local verification and explicitly withholds external reachability' {
        $status = New-TestSshdStatus -Ready -FirewallOverbroad

        $text = (& { Write-OpenSshSuccess -Status $status } *>&1 | Out-String)

        $text | Should -Match 'locally verified'
        $text | Should -Match 'External reachability has not been tested'
        $text | Should -Match 'preserved compatible firewall rule is broader'
        $text | Should -Not -Match 'ready\. From another host'
    }

    It 'never presents the non-admin recovery result as ready' {
        $result = New-ElevationResult

        $result.Ready | Should -BeFalse
        $result.Success | Should -BeFalse
        $result.RecoveryCommand | Should -BeExactly 'just enable-sshd'
    }
}
