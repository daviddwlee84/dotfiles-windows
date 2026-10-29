#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/herdr-gui-install.ps1')
}
Describe 'Herdr UI install-only lifecycle' {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $TestDrive
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'herdr-gpui' }
        Mock Invoke-WebRequest {}
        Mock Get-FileHash { @{ Hash = $script:HerdrGuiInstallerSha256 } }
        Mock Invoke-HerdrGuiInstallerProcess { 0 }
    }
    AfterEach { $env:LOCALAPPDATA = $script:SavedLocalAppData }

    It 'skips a PATH installation without contacting the network' {
        Mock Get-Command { @{ Source = 'portable/herdr-gpui.exe' } } -ParameterFilter { $Name -eq 'herdr-gpui' }
        Install-HerdrGui
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-HerdrGuiInstallerProcess -Times 0 -Exactly
    }
    It 'skips the standard installation even when PATH is stale' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*herdr-gpui.exe' }
        Install-HerdrGui
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'refuses installer checksum mismatch' {
        Mock Get-FileHash { @{ Hash = 'bad' } }
        { Install-HerdrGui } | Should -Throw '*checksum mismatch*'
        Should -Invoke Invoke-HerdrGuiInstallerProcess -Times 0 -Exactly
    }
    It 'propagates download failures without executing the installer' {
        Mock Invoke-WebRequest { throw 'download failed' }
        { Install-HerdrGui } | Should -Throw '*download failed*'
        Should -Invoke Invoke-HerdrGuiInstallerProcess -Times 0 -Exactly
    }
    It 'propagates installer failure' {
        Mock Invoke-HerdrGuiInstallerProcess { 9 }
        { Install-HerdrGui } | Should -Throw '*exit 9*'
    }
    It 'does not claim success when the executable is missing' {
        { Install-HerdrGui } | Should -Throw '*did not produce*'
    }
    It 'verifies the downloaded installer and checks the installed executable' {
        Mock Test-Path { $script:Installed } -ParameterFilter { $LiteralPath -like '*herdr-gpui.exe' }
        $script:Installed = $false
        Mock Invoke-HerdrGuiInstallerProcess { $script:Installed = $true; 0 }
        Install-HerdrGui
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Get-FileHash -Times 1 -Exactly
        Should -Invoke Invoke-HerdrGuiInstallerProcess -Times 1 -Exactly
    }
}
