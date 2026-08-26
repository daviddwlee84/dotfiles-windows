BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'scripts' 'herdr-skill-sync.ps1')
    . (Join-Path $RepoRoot 'scripts' 'herdr-upgrade-core.ps1')
}

Describe 'Herdr verified upgrade orchestration' {
    BeforeEach {
        $script:SavedHerdrEnv = $env:HERDR_ENV
        $script:SavedPaneId = $env:HERDR_PANE_ID
        Remove-Item env:HERDR_ENV, env:HERDR_PANE_ID -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:SavedHerdrEnv) { Remove-Item env:HERDR_ENV -ErrorAction SilentlyContinue }
        else { $env:HERDR_ENV = $script:SavedHerdrEnv }
        if ($null -eq $script:SavedPaneId) { Remove-Item env:HERDR_PANE_ID -ErrorAction SilentlyContinue }
        else { $env:HERDR_PANE_ID = $script:SavedPaneId }
    }

    It 'skips cleanly when Herdr is not installed' {
        Mock Resolve-HerdrExecutable { $null }
        Mock Invoke-HerdrOfficialInstaller {}
        Mock Sync-HerdrSkill { $true }

        Invoke-HerdrUpgrade | Should -Be 0
        Should -Invoke Invoke-HerdrOfficialInstaller -Times 0 -Exactly
        Should -Invoke Sync-HerdrSkill -Times 0 -Exactly
    }

    It 'refuses to replace the server from inside a Herdr pane' {
        $env:HERDR_ENV = 'active'
        Mock Resolve-HerdrExecutable { 'C:\fake\herdr.exe' }
        Mock Invoke-HerdrOfficialInstaller {}

        Invoke-HerdrUpgrade | Should -Be 0
        Should -Invoke Invoke-HerdrOfficialInstaller -Times 0 -Exactly
    }

    It 'uses the preview installer, probes the new binary, and synchronizes once' {
        Mock Resolve-HerdrExecutable { 'C:\fake\herdr.exe' }
        Mock Invoke-HerdrOfficialInstaller {}
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\fake\herdr.exe' }
        Mock Get-HerdrVersion { 'herdr 0.8.2-preview.test' }
        Mock Sync-HerdrSkill { $true }

        Invoke-HerdrUpgrade | Should -Be 0
        Should -Invoke Invoke-HerdrOfficialInstaller -Times 1 -Exactly -ParameterFilter { $Channel -eq 'preview' }
        Should -Invoke Get-HerdrVersion -Times 1 -Exactly
        Should -Invoke Sync-HerdrSkill -Times 1 -Exactly -ParameterFilter { $HerdrPath -eq 'C:\fake\herdr.exe' }
    }

    It 'does not synchronize after installer failure' {
        Mock Resolve-HerdrExecutable { 'C:\fake\herdr.exe' }
        Mock Invoke-HerdrOfficialInstaller { throw 'installer failed' }
        Mock Sync-HerdrSkill { $true }

        Invoke-HerdrUpgrade -ErrorAction SilentlyContinue | Should -Be 1
        Should -Invoke Sync-HerdrSkill -Times 0 -Exactly
    }

    It 'does not synchronize when the post-install executable is missing' {
        $script:ResolveCalls = 0
        Mock Resolve-HerdrExecutable {
            $script:ResolveCalls++
            if ($script:ResolveCalls -eq 1) { return 'C:\fake\old-herdr.exe' }
            return $null
        }
        Mock Invoke-HerdrOfficialInstaller {}
        Mock Sync-HerdrSkill { $true }

        Invoke-HerdrUpgrade -ErrorAction SilentlyContinue | Should -Be 1
        Should -Invoke Sync-HerdrSkill -Times 0 -Exactly
    }

    It 'does not synchronize after a failed version probe' {
        Mock Resolve-HerdrExecutable { 'C:\fake\herdr.exe' }
        Mock Invoke-HerdrOfficialInstaller {}
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\fake\herdr.exe' }
        Mock Get-HerdrVersion { throw 'broken binary' }
        Mock Sync-HerdrSkill { $true }

        Invoke-HerdrUpgrade -ErrorAction SilentlyContinue | Should -Be 1
        Should -Invoke Sync-HerdrSkill -Times 0 -Exactly
    }

    It 'returns failure when the installed skill cannot be synchronized' {
        Mock Resolve-HerdrExecutable { 'C:\fake\herdr.exe' }
        Mock Invoke-HerdrOfficialInstaller {}
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'C:\fake\herdr.exe' }
        Mock Get-HerdrVersion { 'herdr 0.8.2-preview.test' }
        Mock Sync-HerdrSkill { $false }

        Invoke-HerdrUpgrade -ErrorAction SilentlyContinue | Should -Be 1
        Should -Invoke Sync-HerdrSkill -Times 1 -Exactly
    }

    It 'verifies installer bytes, passes preview, and removes the temporary script' {
        $content = "param([string]`$Channel)`n"
        $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content)))
        $script:DownloadedInstaller = $null
        Mock Invoke-WebRequest {
            $script:DownloadedInstaller = $OutFile
            [IO.File]::WriteAllText($OutFile, $content, [Text.UTF8Encoding]::new($false))
        }
        Mock Invoke-HerdrInstallerProcess { 0 }

        Invoke-HerdrOfficialInstaller -Channel preview -InstallerUri 'https://example.invalid/install.ps1' -ExpectedSha256 $expected

        Should -Invoke Invoke-HerdrInstallerProcess -Times 1 -Exactly -ParameterFilter { $Channel -eq 'preview' }
        Test-Path -LiteralPath $script:DownloadedInstaller | Should -BeFalse
    }

    It 'fails closed and cleans up when the installer hash differs' {
        $script:DownloadedInstaller = $null
        Mock Invoke-WebRequest {
            $script:DownloadedInstaller = $OutFile
            [IO.File]::WriteAllText($OutFile, 'changed')
        }
        Mock Invoke-HerdrInstallerProcess { 0 }

        { Invoke-HerdrOfficialInstaller -ExpectedSha256 ('0' * 64) } | Should -Throw '*installer changed*'
        Should -Invoke Invoke-HerdrInstallerProcess -Times 0 -Exactly
        Test-Path -LiteralPath $script:DownloadedInstaller | Should -BeFalse
    }

    It 'fails closed and cleans up when the installer exits nonzero' {
        $content = 'installer'
        $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content)))
        $script:DownloadedInstaller = $null
        Mock Invoke-WebRequest {
            $script:DownloadedInstaller = $OutFile
            [IO.File]::WriteAllText($OutFile, $content, [Text.UTF8Encoding]::new($false))
        }
        Mock Invoke-HerdrInstallerProcess { 42 }

        { Invoke-HerdrOfficialInstaller -ExpectedSha256 $expected } | Should -Throw '*exit 42*'
        Test-Path -LiteralPath $script:DownloadedInstaller | Should -BeFalse
    }

    It 'does not call the legacy manifest parser path' {
        $entry = Get-Content -Raw (Join-Path $RepoRoot 'scripts' 'upgrade-herdr.ps1')
        $entry | Should -Not -Match 'update\s+--handoff'
        $entry | Should -Match 'Invoke-HerdrUpgrade -Channel preview'
    }
}
