#Requires -Version 7.4
#Requires -PSEdition Core
# Pester tests for the shared pueue daemon bootstrap and installer regressions.

BeforeAll {
    $RepoRoot = Join-Path $PSScriptRoot '..'
    $Bootstrap = Join-Path $RepoRoot 'scripts' 'pueue-bootstrap.ps1'
    $PackageTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $ProfileTemplate = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '12_pueue.ps1.tmpl'
    $SpecstoryScript = Join-Path $RepoRoot 'scripts' 'build-specstory.ps1'

    # The shadow reporter intentionally lives only in the package template. Load
    # that plain PowerShell function without executing the installer template.
    $packageSource = Get-Content -Raw -LiteralPath $PackageTemplate
    $tokens = $null
    $parseErrors = $null
    $packageAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $packageSource,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $showFunctionAst = $packageAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Show-UnmanagedPueueShadows'
    }, $true)
    if (-not $showFunctionAst) { throw 'Package template is missing Show-UnmanagedPueueShadows' }
    $ShowFunctionSource = $showFunctionAst.Extent.Text
    . ([scriptblock]::Create($ShowFunctionSource))
}

Describe 'Pueue Scoop-first command resolution' {
    BeforeEach {
        . $Bootstrap
        $script:ScoopPrefix = Join-Path $TestDrive 'scoop/apps/pueue/current'
        $script:ScoopClient = Join-Path $script:ScoopPrefix 'pueue.exe'
        $script:ScoopDaemon = Join-Path $script:ScoopPrefix 'pueued.exe'
        New-Item -ItemType Directory -Force -Path $script:ScoopPrefix | Out-Null
        Set-Content -LiteralPath $script:ScoopClient -Value 'current client'
        Set-Content -LiteralPath $script:ScoopDaemon -Value 'current daemon'

        function global:Invoke-FakeScoop {
            param([string]$Action, [string]$Package)
            if ($Action -eq 'prefix' -and $Package -eq 'pueue') {
                $script:ScoopPrefix
                $global:LASTEXITCODE = 0
            } else {
                $global:LASTEXITCODE = 1
            }
        }

        Mock Get-Command {
            if ($Name -eq 'scoop') {
                return [pscustomobject]@{
                    Name        = 'scoop'
                    Path        = 'Invoke-FakeScoop'
                    Source      = 'Invoke-FakeScoop'
                    CommandType = 'Application'
                }
            }
            if ($Name -eq 'pueue') {
                return [pscustomobject]@{ Source = (Join-Path $HOME 'bin/pueue.exe') }
            }
            if ($Name -eq 'pueued') {
                return [pscustomobject]@{ Source = (Join-Path $HOME 'bin/pueued.exe') }
            }
        }
    }

    AfterEach {
        Remove-Item Function:\Invoke-FakeScoop -ErrorAction SilentlyContinue
    }

    It 'selects one Scoop current pair before shadowing PATH applications' {
        Resolve-PueueCommand -Name pueue | Should -BeExactly $script:ScoopClient
        Resolve-PueueCommand -Name pueued | Should -BeExactly $script:ScoopDaemon
        (Split-Path -Parent (Resolve-PueueCommand -Name pueue)) |
            Should -BeExactly (Split-Path -Parent (Resolve-PueueCommand -Name pueued))

        Should -Invoke Get-Command -Times 0 -Exactly -ParameterFilter {
            $Name -in @('pueue', 'pueued')
        }
    }
}

Describe 'Unmanaged Pueue shadow reporting' {
    BeforeEach {
        . $Bootstrap
        $script:ScoopPrefix = Join-Path $TestDrive 'scoop/apps/pueue/current'
        $script:ScoopClient = Join-Path $script:ScoopPrefix 'pueue.exe'
        $script:ScoopDaemon = Join-Path $script:ScoopPrefix 'pueued.exe'
        $script:LegacyRoots = @(
            (Join-Path $TestDrive 'bin'),
            (Join-Path $TestDrive '.local/bin')
        )
        $script:LegacyCandidates = @(
            foreach ($root in $script:LegacyRoots) {
                Join-Path $root 'pueue.exe'
                Join-Path $root 'pueued.exe'
            }
        )

        Mock Resolve-PueueCommand {
            if (-not $ScoopOnly) { throw 'shadow reporting must request Scoop-only paths' }
            if ($Name -eq 'pueue') { return $script:ScoopClient }
            return $script:ScoopDaemon
        }
        Mock Test-Path {
            return $LiteralPath -in $script:LegacyCandidates
        }
        Mock Remove-Item {}
    }

    It 'warns about and preserves every exact known shadow without executing it' {
        $warningRecords = @()
        $shadows = @(Show-UnmanagedPueueShadows -LegacyRoots $script:LegacyRoots `
            -WarningAction Continue -WarningVariable warningRecords)
        $warningText = $warningRecords -join "`n"

        $shadows | Should -HaveCount 4
        foreach ($candidate in $script:LegacyCandidates) {
            $shadows | Should -Contain $candidate
            $warningText | Should -Match ([regex]::Escape($candidate))
        }
        $warningText | Should -Match 'Unmanaged Pueue PATH shadow\(s\) preserved'
        $warningText | Should -Match 'coherent Scoop current pair'
        $warningText | Should -Match ([regex]::Escape($script:ScoopPrefix))
        Should -Invoke Test-Path -Times 4 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly

        # Provenance boundary: the helper has no operation that could execute or
        # mutate an unmanaged binary. Only literal-path existence is inspected.
        $ShowFunctionSource | Should -Not -Match 'Remove-Item|Get-Command|--version'
        $ShowFunctionSource | Should -Not -Match '(?m)^\s*&\s*\$'
    }

    It 'preserves and warns when Scoop current is incomplete' {
        Mock Resolve-PueueCommand { return $null }
        $warningRecords = @()

        $shadows = @(Show-UnmanagedPueueShadows -LegacyRoots $script:LegacyRoots `
            -WarningAction Continue -WarningVariable warningRecords)

        $shadows | Should -HaveCount 4
        ($warningRecords -join "`n") | Should -Match 'coherent Scoop current pair is unavailable'
        ($warningRecords -join "`n") | Should -Match 'were not executed or changed'
        Should -Invoke Remove-Item -Times 0 -Exactly
    }
}

Describe 'Pueue daemon bootstrap' {
    BeforeEach {
        . $Bootstrap
        $script:ClientCalls = 0
        $script:ReadyAfter = 2
        $script:DaemonCalls = [System.Collections.Generic.List[string]]::new()

        function global:Invoke-FakePueue {
            $script:ClientCalls++
            $global:LASTEXITCODE = if ($script:ClientCalls -ge $script:ReadyAfter) { 0 } else { 1 }
        }
        function global:Invoke-FakePueued {
            $script:DaemonCalls.Add(($args -join ' '))
            $global:LASTEXITCODE = 0
        }
        $script:CreatedGetServiceStub = -not [bool](Get-Command Get-Service -ErrorAction SilentlyContinue)
        if ($script:CreatedGetServiceStub) {
            function global:Get-Service {
                [CmdletBinding()]
                param([string]$Name)
                $null = $Name
            }
        }

        Mock Resolve-PueueCommand {
            if ($Name -eq 'pueue') { return 'Invoke-FakePueue' }
            return 'Invoke-FakePueued'
        }
        Mock Test-PueueAdministrator { return $false }
        Mock Test-PueuedReady {
            $script:ClientCalls++
            return ($script:ClientCalls -ge $script:ReadyAfter)
        }
        Mock Start-Process {}
        Mock Start-Sleep {}
    }

    AfterEach {
        Remove-Item Function:\Invoke-FakePueue, Function:\Invoke-FakePueued -ErrorAction SilentlyContinue
        if ($script:CreatedGetServiceStub) {
            Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'starts detached daemon mode without waiting on inherited stdio' {
        Start-PueuedIfNeeded -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'Invoke-FakePueued' -and
            $ArgumentList -eq '--daemonize' -and
            $WindowStyle -eq 'Hidden' -and
            -not $Wait
        }
        $script:DaemonCalls | Should -HaveCount 0
    }

    It 'does nothing when the daemon is already ready' {
        $script:ReadyAfter = 1
        Start-PueuedIfNeeded -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
        Should -Invoke Start-Process -Times 0 -Exactly
        $script:DaemonCalls | Should -HaveCount 0
    }

    It 'uses the resolved pair to install and start the service despite PATH shadows' {
        Mock Test-PueueAdministrator { return $true }
        $script:ServiceLookups = 0
        Mock Get-Service {
            $script:ServiceLookups++
            if ($script:ServiceLookups -ge 2) { return [pscustomobject]@{ Name = 'pueued' } }
        }

        Start-PueuedIfNeeded -InstallService -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
        $script:DaemonCalls | Should -Be @('service install', 'service start')
        Should -Invoke Resolve-PueueCommand -Times 1 -Exactly -ParameterFilter { $Name -eq 'pueue' }
        Should -Invoke Resolve-PueueCommand -Times 1 -Exactly -ParameterFilter { $Name -eq 'pueued' }
    }

    It 'falls back immediately to the resolved daemon and verifies readiness when service install leaves no service' {
        Mock Test-PueueAdministrator { return $true }
        Mock Get-Service { return $null }

        Start-PueuedIfNeeded -InstallService -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
        $script:DaemonCalls | Should -Be @('service install')
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'Invoke-FakePueued' -and $ArgumentList -eq '--daemonize'
        }
        Should -Invoke Test-PueuedReady -Times 2 -Exactly -ParameterFilter {
            $ClientPath -eq 'Invoke-FakePueue'
        }
    }

    It 'does not race a successfully started service with a detached daemon' {
        Mock Test-PueueAdministrator { return $true }
        Mock Get-Service { [pscustomobject]@{ Name = 'pueued' } }
        Mock Wait-PueuedReady { $false }

        Start-PueuedIfNeeded -InstallService -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeFalse
        $script:DaemonCalls | Should -Be @('service start')
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

Describe 'Pueue readiness process timeout' -Skip:(-not $IsWindows) {
    BeforeEach { . $Bootstrap }

    It 'bounds a hung native status probe and terminates only the probe tree' {
        $client = Join-Path $TestDrive 'hung-pueue.cmd'
        "@ping -n 6 127.0.0.1 >nul`r`n@exit /b 0" | Set-Content -LiteralPath $client
        $clock = [System.Diagnostics.Stopwatch]::StartNew()

        Test-PueuedReady -ClientPath $client -TimeoutMilliseconds 100 | Should -BeFalse

        $clock.ElapsedMilliseconds | Should -BeLessThan 1500
    }

    It 'accepts a native status probe that exits successfully' {
        $client = Join-Path $TestDrive 'ready-pueue.cmd'
        '@exit /b 0' | Set-Content -LiteralPath $client

        Test-PueuedReady -ClientPath $client -TimeoutMilliseconds 500 | Should -BeTrue
    }
}

Describe 'Package installer regressions' {
    BeforeAll {
        $package = Get-Content -Raw -LiteralPath $PackageTemplate
        $profileSource = Get-Content -Raw -LiteralPath $ProfileTemplate
        $specstory = Get-Content -Raw -LiteralPath $SpecstoryScript
    }

    It 'reports unmanaged shadows after Scoop installation and before immediate startup' {
        $coreStart = $package.IndexOf('# Core CLI toolset')
        $install = $package.IndexOf('Scoop-Install @(', $coreStart)
        $report = $package.IndexOf('$null = Show-UnmanagedPueueShadows', $install)
        $startup = $package.IndexOf('Start-PueuedIfNeeded -InstallService', $report)
        $betweenReportAndStartup = $package.Substring($report, $startup - $report)

        $install | Should -BeGreaterThan $coreStart
        $report | Should -BeGreaterThan $install
        $startup | Should -BeGreaterThan $report
        $betweenReportAndStartup | Should -Not -Match 'Register-Failure'
    }

    It 'never executes or deletes unmanaged legacy Pueue binaries' {
        $package | Should -Not -Match 'Get-PueueBinaryInfo|Remove-LegacyPueueBinaries'
        $ShowFunctionSource | Should -Match 'Join-Path \$HOME ''bin'''
        $ShowFunctionSource | Should -Match 'Join-Path \$HOME ''\.local\\bin'''
        $ShowFunctionSource | Should -Not -Match 'Remove-Item|--version'
    }

    It 'starts pueued during apply and from future PowerShell profiles' {
        $package | Should -Match 'Start-PueuedIfNeeded -InstallService'
        $profileSource | Should -Match 'Start-PueuedIfNeeded -Quiet'
        $package | Should -Match 'include "scripts/pueue-bootstrap\.ps1"'
        $profileSource | Should -Match 'include "scripts/pueue-bootstrap\.ps1"'
    }

    It 'does not implicitly upgrade already-installed npm agents during apply' {
        $package | Should -Match 'Get-NpmGlobalExecutionContext'
        $package | Should -Match '\$npm\.Root'
        $package | Should -Match '\$packageManifest'
        $package | Should -Match 'already installed -- skipping'
        $package | Should -Match 'just upgrade-npm-agents'
    }

    It 'uses official SpecStory releases for apply and the compatibility command' {
        foreach ($source in @($package, $specstory)) {
            $source | Should -Match 'Install-WindowsCliRelease -Name specstory'
            $source | Should -Not -Match 'pull/191/head'
        }
    }
}
