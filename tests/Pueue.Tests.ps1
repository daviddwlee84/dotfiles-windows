# Pester tests for the shared pueue daemon bootstrap and installer regressions.

BeforeAll {
    $RepoRoot = Join-Path $PSScriptRoot '..'
    $Bootstrap = Join-Path $RepoRoot 'scripts' 'pueue-bootstrap.ps1'
    $PackageTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $ProfileTemplate = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '12_pueue.ps1.tmpl'
    $SpecstoryScript = Join-Path $RepoRoot 'scripts' 'build-specstory.ps1'
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

    It 'installs and starts the built-in service during an elevated apply' {
        Mock Test-PueueAdministrator { return $true }
        $script:ServiceLookups = 0
        Mock Get-Service {
            $script:ServiceLookups++
            if ($script:ServiceLookups -ge 2) { return [pscustomobject]@{ Name = 'pueued' } }
        }

        Start-PueuedIfNeeded -InstallService -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
        $script:DaemonCalls | Should -HaveCount 2
        $script:DaemonCalls[0] | Should -Be 'service install'
        $script:DaemonCalls[1] | Should -Be 'service start'
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

Describe 'Pueue readiness process timeout' {
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

    It 'starts pueued during apply and from future PowerShell profiles' {
        $package | Should -Match 'Start-PueuedIfNeeded -InstallService'
        $profileSource | Should -Match 'Start-PueuedIfNeeded -Quiet'
        $package | Should -Match 'include "scripts/pueue-bootstrap\.ps1"'
        $profileSource | Should -Match 'include "scripts/pueue-bootstrap\.ps1"'
    }

    It 'does not implicitly upgrade already-installed npm agents during apply' {
        $package | Should -Match 'npm root -g'
        $package | Should -Match '\$packageManifest'
        $package | Should -Match 'already installed -- skipping'
        $package | Should -Match 'just upgrade-npm-agents'
    }

    It 'fetches SpecStory into a remote ref before detached checkout' {
        foreach ($source in @($package, $specstory)) {
            $source | Should -Match 'refs/remotes/origin/pr-'
            $source | Should -Match 'checkout --detach --force'
            $source | Should -Not -Match 'pull/191/head:pr-191'
        }
    }
}
