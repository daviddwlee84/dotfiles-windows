#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:OriginalPath = $env:PATH
    $script:OriginalHold = $env:HERDR_RUN_HOLD
    $script:OriginalCwd = $env:HERDR_ACTIVE_PANE_CWD
    $script:Fixture = Join-Path $TestDrive 'space in home/.config'
    $null = New-Item -ItemType Directory -Force -Path "$script:Fixture/herdr", "$script:Fixture/powershell/profile.d"
    Copy-Item (Join-Path $script:Repo 'dot_config/herdr/lazygit.ps1') "$script:Fixture/herdr/lazygit.ps1"
    @'
function Resolve-HerdrPane { 'fixture-pane' }
function Resolve-HerdrCwd { param($PaneId) $env:HERDR_ACTIVE_PANE_CWD }
'@ | Set-Content "$script:Fixture/herdr/_common.ps1"
    '$env:PATH = "managed-first;" + $env:PATH' | Set-Content "$script:Fixture/powershell/profile.d/00_env.ps1"
    . "$script:Fixture/herdr/lazygit.ps1"
}
AfterAll {
    $env:PATH = $script:OriginalPath
    $env:HERDR_RUN_HOLD = $script:OriginalHold
    $env:HERDR_ACTIVE_PANE_CWD = $script:OriginalCwd
}

Describe 'Herdr LazyGit launcher' {
    BeforeEach {
        $env:PATH = $script:OriginalPath
        $env:HERDR_RUN_HOLD = 'never'
        $env:HERDR_ACTIVE_PANE_CWD = Split-Path $script:Fixture
        Mock Get-Command { [pscustomobject]@{Source='managed-lazygit.exe'} } -ParameterFilter { $Name -eq 'lazygit' }
        Mock Get-Command { [pscustomobject]@{Source='managed-git.exe'} } -ParameterFilter { $Name -eq 'git' }
        Mock Start-HerdrLazyGitProcess { 0 }
        Mock Write-Host {}
        Mock Read-Host {}
    }

    It 'loads only environment setup and uses focused cwd, including spaces' {
        $before = (Get-Location).Path
        Invoke-HerdrLazyGit | Should -Be 0
        $env:PATH | Should -BeLike 'managed-first;*'
        (Get-Location).Path | Should -Be $before
        Should -Invoke Start-HerdrLazyGitProcess -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'managed-lazygit.exe' -and $WorkingDirectory -eq $env:HERDR_ACTIVE_PANE_CWD
        }
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'preserves a nonzero exit code and emits executable diagnostics' {
        Mock Start-HerdrLazyGitProcess { 17 }
        Invoke-HerdrLazyGit | Should -Be 17
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*managed-lazygit.exe*' }
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*managed-git.exe*' }
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*[exit 17]*' }
    }

    It 'takes the first executable when command discovery returns multiple installations' {
        Mock Get-Command { @([pscustomobject]@{Source='managed-lazygit.exe'}, [pscustomobject]@{Source='legacy-lazygit.exe'}) } -ParameterFilter { $Name -eq 'lazygit' }
        Mock Get-Command { @([pscustomobject]@{Source='managed-git.exe'}, [pscustomobject]@{Source='legacy-git.exe'}) } -ParameterFilter { $Name -eq 'git' }
        Invoke-HerdrLazyGit | Should -Be 0
        Should -Invoke Start-HerdrLazyGitProcess -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'managed-lazygit.exe'
        }
    }

    It 'reports resolution failure rather than trying to launch a missing executable' {
        Mock Get-Command { throw 'not found' } -ParameterFilter { $Name -eq 'lazygit' }
        Invoke-HerdrLazyGit | Should -Be 1
        Should -Invoke Start-HerdrLazyGitProcess -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*not found*' }
    }

    It 'uses an absolute rendered script path in the keymap, not the bare TUI name' {
        $source = Get-Content (Join-Path $script:Repo '.chezmoitemplates/herdr/config.toml') -Raw
        $source | Should -Match '(?s)key = "prefix\+G"\s+type = "pane"\s+command = ''pwsh -NoProfile -File "\{\{ \$herdrDir \}\}/lazygit.ps1"'''
    }
}
