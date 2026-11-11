#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/herdr-installers.ps1')
}

Describe 'Herdr installers: install-only lifecycle' {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $TestDrive
        # $TestDrive persists within a block; start every test with no install.
        Remove-Item -LiteralPath (Join-Path $TestDrive 'Programs') -Recurse -Force -ErrorAction SilentlyContinue
        Mock Get-Command { $null }
        Mock Invoke-WebRequest {}
        Mock Get-HerdrOsArchitecture { 'X64' }
        Mock Invoke-HerdrInstallerScriptProcess { 0 }
    }
    AfterEach { $env:LOCALAPPDATA = $script:SavedLocalAppData }

    Context '<Fn>' -ForEach @(
        @{ Fn = 'Install-Sheprd'; Exe = 'Programs\Herdr UI\sheprd.exe'; Sha = 'SheprdInstallerSha256'; Cmd = 'sheprd' }
        @{ Fn = 'Install-HerdrCore'; Exe = 'Programs\herdr-core\herdr-core.exe'; Sha = 'HerdrCoreInstallerSha256'; Cmd = 'herdr-core' }
        @{ Fn = 'Install-HerdrApp'; Exe = 'Programs\herdr-app\herdr-app.exe'; Sha = 'HerdrAppInstallerSha256'; Cmd = 'herdr-app' }
    ) {
        BeforeEach {
            $script:Sum = Get-Variable -Scope Script -Name $Sha -ValueOnly
            Mock Get-FileHash { @{ Hash = $script:Sum } }
            $script:Target = Join-Path $TestDrive $Exe
        }

        It 'skips a PATH installation without contacting the network' {
            Mock Get-Command { @{ Source = "portable/$Cmd.exe" } } -ParameterFilter { $Name -eq $Cmd }
            & $Fn
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-HerdrInstallerScriptProcess -Times 0 -Exactly
        }
        It 'skips the standard installation even when PATH is stale' {
            New-Item -ItemType File -Force -Path $script:Target | Out-Null
            & $Fn
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
        It 'refuses installer checksum mismatch' {
            Mock Get-FileHash { @{ Hash = 'bad' } }
            { & $Fn } | Should -Throw '*checksum mismatch*'
            Should -Invoke Invoke-HerdrInstallerScriptProcess -Times 0 -Exactly
        }
        It 'propagates download failures without executing the installer' {
            Mock Invoke-WebRequest { throw 'download failed' }
            { & $Fn } | Should -Throw '*download failed*'
            Should -Invoke Invoke-HerdrInstallerScriptProcess -Times 0 -Exactly
        }
        It 'propagates installer failure' {
            Mock Invoke-HerdrInstallerScriptProcess { 9 }
            { & $Fn } | Should -Throw '*exit 9*'
        }
        It 'does not claim success when the executable is missing' {
            { & $Fn } | Should -Throw '*did not produce*'
        }
        It 'verifies the downloaded installer and checks the installed executable' {
            Mock Invoke-HerdrInstallerScriptProcess {
                New-Item -ItemType File -Force -Path $script:Target | Out-Null
                0
            }
            & $Fn
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Get-FileHash -Times 1 -Exactly
            Should -Invoke Invoke-HerdrInstallerScriptProcess -Times 1 -Exactly
        }
    }

    It 'treats the legacy herdr-gpui.exe as an installed Sheprd' {
        New-Item -ItemType File -Force -Path (Join-Path $TestDrive 'Programs\Herdr UI\herdr-gpui.exe') | Out-Null
        Install-Sheprd
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'installs Sheprd on ARM64 (upstream ships ARM64 builds)' {
        Mock Get-HerdrOsArchitecture { 'Arm64' }
        Mock Get-FileHash { @{ Hash = $script:SheprdInstallerSha256 } }
        Mock Invoke-HerdrInstallerScriptProcess {
            New-Item -ItemType File -Force -Path (Join-Path $TestDrive 'Programs\Herdr UI\sheprd.exe') | Out-Null
            0
        }
        Install-Sheprd
        Should -Invoke Invoke-HerdrInstallerScriptProcess -Times 1 -Exactly
    }

    It '<Fn> skips non-x64 hosts without downloading' -ForEach @(
        @{ Fn = 'Install-HerdrCore' }, @{ Fn = 'Install-HerdrApp' }
    ) {
        Mock Get-HerdrOsArchitecture { 'Arm64' }
        & $Fn
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'pins every installer to a full commit and a 64-hex SHA-256' {
        foreach ($uri in $script:SheprdInstallerUri, $script:HerdrCoreInstallerUri, $script:HerdrAppInstallerUri) {
            $uri | Should -Match '^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/'
        }
        foreach ($sum in $script:SheprdInstallerSha256, $script:HerdrCoreInstallerSha256, $script:HerdrAppInstallerSha256) {
            $sum | Should -Match '^[0-9A-F]{64}$'
        }
    }
}

Describe 'Update-HerdrCore' {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $TestDrive
    }
    AfterEach { $env:LOCALAPPDATA = $script:SavedLocalAppData }

    It 'skips when no installer-managed core exists' {
        Update-HerdrCore | Should -Be 0
    }
}
