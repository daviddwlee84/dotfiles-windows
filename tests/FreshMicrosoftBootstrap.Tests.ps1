#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot
    . (Join-Path $script:Repo 'bootstrap.ps1')
}

Describe 'Fresh Microsoft workstation contract' {
    It 'allows explicit workstation unattended setup only for Microsoft' {
        $bound = @{ Role = 'workstation'; Name = 'Test'; Email = 'test@example.com' }
        { Assert-BootstrapParameters -BoundParameters $bound -NonInteractive -Role workstation -Name Test -Email test@example.com -OrganizationProfile microsoft } | Should -Not -Throw
        { Assert-BootstrapParameters -BoundParameters $bound -NonInteractive -Role workstation -Name Test -Email test@example.com -OrganizationProfile none } | Should -Throw '*explicit -Role minimal*'
    }
    It 'keeps bootstrap prerequisites aligned with the reviewed catalog' {
        $catalog = (Get-Content -Raw (Join-Path $script:Repo '.chezmoidata/windows-tool-sources.json') | ConvertFrom-Json).windowsToolSources.tools
        $packages = Get-OrganizationBootstrapPackages
        @($packages.Keys)[0] | Should -Be pwsh
        foreach ($name in $packages.Keys) {
            $id = if ($name -eq '7z') { '7zip' } else { $name }
            $entry = $catalog | Where-Object id -EQ $id
            $entry.provider | Should -Be winget
            $entry.packageId | Should -Be $packages[$name]
        }
        $packages.Keys | Should -Contain python
        $packages.Keys | Should -Contain bun
    }
    It 'recognizes the in-box Store Python alias but not a real vendor interpreter' {
        Test-BootstrapPythonAlias 'C:\Users\Test\AppData\Local\Microsoft\WindowsApps\python.exe' | Should -BeTrue
        Test-BootstrapPythonAlias 'C:\Users\Test\AppData\Local\Programs\Python\Python314\python.exe' | Should -BeFalse
    }
}

Describe 'Same-session registered runtime discovery' {
    BeforeEach {
        Mock Get-Command { @() }
    }
    It 'finds a registered PowerShell entry point when PATH is stale' {
        $candidate = Join-Path $TestDrive 'Microsoft/WindowsApps/pwsh.exe'
        New-Item -ItemType Directory -Force (Split-Path $candidate) | Out-Null
        New-Item -ItemType File $candidate | Out-Null
        $script:StablePwsh = $candidate
        Mock Get-BootstrapRegisteredCandidates { $script:StablePwsh }
        Resolve-BootstrapOrganizationCommand pwsh | Should -Be $candidate
    }
    It 'does not mistake the Python Store stub for a satisfied dependency' {
        $stub = Join-Path $TestDrive 'Microsoft/WindowsApps/python.exe'
        $python = Join-Path $TestDrive 'Python314/python.exe'
        New-Item -ItemType Directory -Force (Split-Path $stub), (Split-Path $python) | Out-Null
        New-Item -ItemType File $stub, $python | Out-Null
        $script:PythonStub = $stub; $script:RegisteredPython = $python
        Mock Get-Command { [pscustomobject]@{ Source = $script:PythonStub } }
        Mock Get-BootstrapRegisteredCandidates { $script:RegisteredPython }
        Resolve-BootstrapOrganizationCommand python | Should -Be $python
    }
}

Describe 'Fresh prerequisite install ordering' {
    BeforeEach {
        $script:Installed = @{}
        $script:Events = [Collections.Generic.List[string]]::new()
        Mock Resolve-BootstrapOrganizationCommand {
            param($Name)
            if ($Name -eq 'winget') { return 'C:\Approved\winget.exe' }
            if ($script:Installed.ContainsKey($Name)) { return "C:\Approved\$Name.exe" }
            $null
        }
        Mock Invoke-OrganizationBootstrapWinget {
            param($Winget, $PackageId)
            $map = Get-OrganizationBootstrapPackages
            $key = @($map.Keys | Where-Object { $map[$_] -eq $PackageId })[0]
            $script:Installed[$key] = $true
            $script:Events.Add("install:$key")
        }
        Mock Update-OrganizationBootstrapPath {}
        Mock Test-OrganizationBootstrapRuntime { param($Name, $Path) $script:Events.Add("probe:$Name") }
    }
    It 'installs and verifies the foundation before returning paths for full apply' {
        $result = Install-OrganizationBaselineTools
        $result.PowerShellExecutable | Should -Be 'C:\Approved\pwsh.exe'
        $result.PythonExecutable | Should -Be 'C:\Approved\python.exe'
        $result.ChezmoiExecutable | Should -Be 'C:\Approved\chezmoi.exe'
        $result.Executables.Count | Should -Be 7
        $script:Events[0] | Should -Be 'install:pwsh'
        $script:Events[1] | Should -Be 'probe:pwsh'
        Should -Invoke Invoke-OrganizationBootstrapWinget -Times 7 -Exactly
        Should -Invoke Test-OrganizationBootstrapRuntime -Times 7 -Exactly
        Should -Invoke Update-OrganizationBootstrapPath -ParameterFilter { 'C:\Approved\python.exe' -in $ExecutablePaths } -Times 1
    }
    It 'preserves supplied runtime owners instead of reinstalling them' {
        $result = Install-OrganizationBaselineTools -PowerShellExecutable 'C:\Custom\pwsh.exe' -PythonExecutable 'C:\Custom\python.exe'
        $result.PowerShellExecutable | Should -Be 'C:\Custom\pwsh.exe'
        $result.PythonExecutable | Should -Be 'C:\Custom\python.exe'
        Should -Invoke Invoke-OrganizationBootstrapWinget -Times 0 -Exactly -ParameterFilter { $PackageId -in 'Microsoft.PowerShell', 'Python.Python.3.14' }
    }
    It 'stops on policy denial without switching source or starting apply' {
        Mock Invoke-OrganizationBootstrapWinget { throw 'IT policy denied this package' }
        { Install-OrganizationBaselineTools } | Should -Throw '*policy denied*'
        Should -Invoke Invoke-OrganizationBootstrapWinget -Times 1 -Exactly
        Should -Invoke Test-OrganizationBootstrapRuntime -Times 0
    }
    It 'stops when install succeeds but registration is unavailable' {
        Mock Invoke-OrganizationBootstrapWinget {}
        { Install-OrganizationBaselineTools } | Should -Throw '*executable is unavailable*'
        Should -Invoke Invoke-OrganizationBootstrapWinget -Times 1 -Exactly
    }
    It 'does not accept an obsolete or blocked pwsh because a file exists' {
        $script:Installed['pwsh'] = $true
        Mock Test-OrganizationBootstrapRuntime { throw 'PowerShell Core 7.4 required' }
        { Install-OrganizationBaselineTools } | Should -Throw '*7.4 required*'
        Should -Invoke Invoke-OrganizationBootstrapWinget -Times 0
    }
}

Describe 'Verified full apply boundary' {
    BeforeEach {
        $script:Stages = [Collections.Generic.List[string]]::new()
        $script:Invocations = [Collections.Generic.List[object]]::new()
        Mock Invoke-ChezmoiCommand { $script:Stages.Add($ArgumentList[0]); $script:Invocations.Add(@($ArgumentList)) }
        Mock Assert-MicrosoftChezmoiConfiguration { $script:Stages.Add('verify') }
        Mock Test-ChezmoiSourceRepo { $false }
    }
    It 'initializes, verifies, then applies every target without excluding scripts' {
        Invoke-ChezmoiSetup -ChezmoiPath 'C:\Approved\chezmoi.exe' -Source $TestDrive -OrganizationProfile microsoft `
            -PowerShellExecutable 'C:\Approved\pwsh.exe' -PythonExecutable 'C:\Approved\python.exe' `
            -NonInteractive -Role workstation -Name Test -Email test@example.com
        ($script:Stages -join ',') | Should -Be 'init,verify,apply'
        $script:Invocations[0] | Should -Not -Contain '--apply'
        $script:Invocations[1] | Should -Not -Contain '--exclude'
        Should -Invoke Assert-MicrosoftChezmoiConfiguration -Times 1 -Exactly -ParameterFilter { $Source -eq $TestDrive -and $PythonExecutable -eq 'C:\Approved\python.exe' }
    }
    It 'does not apply an older source that ignores the organization settings' {
        Mock Assert-MicrosoftChezmoiConfiguration { throw 'Source/config does not support Microsoft' }
        { Invoke-ChezmoiSetup -ChezmoiPath 'C:\Approved\chezmoi.exe' -Source $TestDrive -OrganizationProfile microsoft `
            -PowerShellExecutable 'C:\Approved\pwsh.exe' -PythonExecutable 'C:\Approved\python.exe' } | Should -Throw '*does not support Microsoft*'
        Should -Invoke Invoke-ChezmoiCommand -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'apply' }
    }
    It 'suppresses implicit apply when updating an existing checkout' {
        Mock Test-ChezmoiSourceRepo { $true }
        Invoke-ChezmoiSetup -ChezmoiPath 'C:\Approved\chezmoi.exe' -OrganizationProfile microsoft `
            -PowerShellExecutable 'C:\Approved\pwsh.exe' -PythonExecutable 'C:\Approved\python.exe'
        ($script:Stages -join ',') | Should -Be 'update,verify,apply'
        $script:Invocations[0] | Should -Contain '--apply=false'
    }
}

Describe 'Real Windows PowerShell 5.1 bootstrap entry' {
    It 'reaches full Microsoft workstation apply only after all fresh prerequisites, with installers faked' -Skip:(-not $IsWindows) {
        $harness = Join-Path $TestDrive 'bootstrap-51.ps1'
        @'
param([string]$Bootstrap)
$ErrorActionPreference = 'Stop'
. $Bootstrap
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Expected in-box Windows PowerShell 5.1' }
$script:Installed = @{}
function Get-BootstrapPowerShellOverride { $null }
function Get-BootstrapPythonOverride { $null }
function Update-BootstrapPath {}
function Update-OrganizationBootstrapPath { param($ExecutablePaths) }
function Assert-UnattendedFreshState { param([switch]$NonInteractive) }
function Resolve-BootstrapOrganizationCommand {
    param($Name)
    if ($Name -eq 'winget') { return 'C:\Approved\winget.exe' }
    if ($script:Installed.ContainsKey($Name)) { return "C:\Approved\$Name.exe" }
}
function Invoke-OrganizationBootstrapWinget {
    param($Winget, $PackageId)
    $map = Get-OrganizationBootstrapPackages
    $key = @($map.Keys | Where-Object { $map[$_] -eq $PackageId })[0]
    $script:Installed[$key] = $true
}
function Test-OrganizationBootstrapRuntime { param($Name, $Path) }
function Initialize-Scoop { throw 'Scoop must never be reached' }
function Set-ExecutionPolicy { throw 'Execution policy must not change' }
function Invoke-ChezmoiSetup {
    param($ChezmoiPath, $Repo, $Branch, $Source, $Role, [switch]$NonInteractive,
        $Name, $Email, $OrganizationProfile, $PowerShellExecutable, $PythonExecutable)
    if ($script:Installed.Count -ne 7) { throw 'Apply began before prerequisites were ready' }
    if ($Role -ne 'workstation' -or $OrganizationProfile -ne 'microsoft' -or -not $NonInteractive) { throw 'Wrong full-apply selection' }
    if ($PowerShellExecutable -ne 'C:\Approved\pwsh.exe' -or $PythonExecutable -ne 'C:\Approved\python.exe') { throw 'Runtime paths were not forwarded' }
    '__FRESH_MICROSOFT_51__' + (@{ Role = $Role; Count = $script:Installed.Count; HostMajor = $PSVersionTable.PSVersion.Major } | ConvertTo-Json -Compress)
}
Invoke-Bootstrap -OrganizationProfile microsoft -NonInteractive -Role workstation -Name Test -Email test@example.com -Source C:\Fixture
'@ | Set-Content -LiteralPath $harness -Encoding utf8
        $host51 = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $output = @(& $host51 -NoLogo -NoProfile -NonInteractive -File $harness -Bootstrap (Join-Path $script:Repo 'bootstrap.ps1') 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match '__FRESH_MICROSOFT_51__'
        $output | Should -Match '"Count":7'
        $output | Should -Match '"HostMajor":5'
    }
}
