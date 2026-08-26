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
        Mock Start-Sleep {}
    }

    AfterEach {
        Remove-Item Function:\Invoke-FakePueue, Function:\Invoke-FakePueued -ErrorAction SilentlyContinue
        if ($script:CreatedGetServiceStub) {
            Remove-Item Function:\Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'starts detached daemon mode when the client is not ready' {
        Start-PueuedIfNeeded -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
        $script:DaemonCalls | Should -HaveCount 1
        $script:DaemonCalls[0] | Should -Be '--daemonize'
    }

    It 'does nothing when the daemon is already ready' {
        $script:ReadyAfter = 1
        Start-PueuedIfNeeded -Quiet -ReadyTimeoutMilliseconds 100 | Should -BeTrue
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
