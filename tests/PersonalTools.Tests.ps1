#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $RepoRoot 'scripts/personal-tools.ps1')
    function Install-DevCli {}
    function Scoop-Install { param([string[]]$apps) }
    function Register-Failure { param($what) }
    function Install-WindowsCliRelease { param($Name, [switch]$Upgrade) }
    function scoop { $global:LASTEXITCODE = 0 }
}

Describe 'Authoritative personal suite selection' {
    It 'selects all six independently of Herdr and the old translation switch' {
        $tools = @(Get-SelectedPersonalTools @{ installPersonalTools = $true; installHerdr = $false; installTranslate = $false })
        $tools.Count | Should -Be 6
        $tools.Id | Should -Not -Contain 'exp-cli'
        $tools.Id | Should -Contain 'lazychezmoi'
        ($tools | Where-Object Id -EQ 'dev-cli').Binary | Should -BeExactly 'dev-cli'
    }
    It 'treats explicit false as authoritative even with both old selectors enabled' {
        @(Get-SelectedPersonalTools @{ installPersonalTools = $false; installHerdr = $true; installTranslate = $true }).Count | Should -Be 0
    }
    It 'uses legacy selections only while the new key is missing' {
        @(Get-SelectedPersonalTools @{ installHerdr = $true; installTranslate = $false }).Id | Should -BeExactly 'dev-cli'
        @(Get-SelectedPersonalTools @{ installHerdr = $false; installTranslate = $true }).Id | Should -BeExactly 'translate'
        @(Get-SelectedPersonalTools @{}).Count | Should -Be 0
    }
}

Describe 'Install and upgrade boundaries' {
    BeforeEach {
        Mock Install-DevCli {}
        Mock Install-WindowsCliRelease {}
        Mock Scoop-Install {}
        Mock Register-Failure {}
        Mock scoop { $global:LASTEXITCODE = 0 }
    }
    It 'does nothing for an explicitly disabled suite' {
        Install-SelectedPersonalTools @{ installPersonalTools = $false; installHerdr = $true; installTranslate = $true }
        Should -Invoke Install-DevCli -Times 0 -Exactly
        Should -Invoke Scoop-Install -Times 0 -Exactly
        Should -Invoke scoop -Times 0 -Exactly
    }
    It 'preserves unknown installations without invoking their executable or manager' {
        Mock Get-PersonalToolOwner { [pscustomobject]@{Kind='unmanaged';Path='untrusted';Id=$Tool.Id} }
        Mock Get-PersonalToolVersion { throw 'must not execute an unknown binary' }
        Install-SelectedPersonalTools @{ installPersonalTools=$true }
        $results=@(Update-SelectedPersonalTools @{ installPersonalTools=$true })
        $results.Count | Should -Be 6
        @($results | Where-Object Status -NE 'skipped').Count | Should -Be 0
        Should -Invoke Get-PersonalToolVersion -Times 0 -Exactly
        Should -Invoke Install-DevCli -Times 0 -Exactly
        Should -Invoke scoop -Times 0 -Exactly
    }
    It 'never installs a missing tool during an explicit aggregate upgrade' {
        Mock Get-PersonalToolOwner { [pscustomobject]@{Kind='missing';Path='missing';Id=$Tool.Id} }
        $results=@(Update-SelectedPersonalTools @{ installPersonalTools=$true })
        $results.Count | Should -Be 6
        Should -Invoke Install-WindowsCliRelease -Times 0 -Exactly
        Should -Invoke Scoop-Install -Times 0 -Exactly
        Should -Invoke scoop -Times 0 -Exactly
    }
    It 'previews owned upgrades without executing binaries or changing managers' {
        Mock Get-PersonalToolOwner { [pscustomobject]@{Kind=$Tool.Manager;Path='owned';Id=$Tool.Id} }
        Mock Get-PersonalToolVersion { throw 'preview must be read-only' }
        $null=Update-SelectedPersonalTools @{ installPersonalTools=$true } -WhatIf
        Should -Invoke Get-PersonalToolVersion -Times 0 -Exactly
        Should -Invoke scoop -Times 0 -Exactly
        Should -Invoke Install-WindowsCliRelease -Times 0 -Exactly
    }
    It 'continues after an owned upgrade failure and records the failure' {
        Mock Get-PersonalToolOwner { [pscustomobject]@{Kind=$Tool.Manager;Path='owned';Id=$Tool.Id} }
        Mock Get-PersonalToolVersion { "$($Tool.VersionName) version v1.0.0" }
        Mock Install-WindowsCliRelease { throw 'fixture download failed' }
        $results=@(Update-SelectedPersonalTools @{ installPersonalTools=$true })
        ($results | Where-Object Tool -EQ 'dev-cli').Status | Should -Be 'failed'
        @($results | Where-Object Status -EQ 'unchanged').Count | Should -Be 5
        Should -Invoke scoop -Times 6 -Exactly
    }
    It 'captures Scoop host-stream errors even when the script exits zero' {
        Mock Get-PersonalToolOwner { [pscustomobject]@{Kind='scoop';Path='owned';Id=$Tool.Id} }
        Mock Get-PersonalToolVersion { 'translate version v1.0.0' }
        Mock scoop { Write-Host 'ERROR Hash check failed!'; $global:LASTEXITCODE=0 }
        $results=@(Update-SelectedPersonalTools @{ installTranslate=$true })
        $results[0].Status | Should -Be 'failed'
    }

    It 'reports Scoop running-process skips as failures despite exit zero' {
        Mock Get-PersonalToolOwner { [pscustomobject]@{Kind='scoop';Path='owned';Id=$Tool.Id} }
        Mock Get-PersonalToolVersion { 'translate version v1.0.0' }
        Mock scoop { $global:LASTEXITCODE=0; 'Running process detected, skip updating.' }
        $results=@(Update-SelectedPersonalTools @{ installTranslate=$true })
        $results[0].Status | Should -Be 'failed'
    }
}

Describe 'Scoop ownership and shadows' {
    It 'does not adopt another bucket or a same-named PATH executable' {
        $root=Join-Path $TestDrive 'scoop'
        $current=Join-Path $root 'apps/lazymlflow/current'
        New-Item -ItemType Directory -Force $current | Out-Null
        Set-Content (Join-Path $current 'lazymlflow.exe') 'fixture; never executed'
        Set-Content (Join-Path $current 'install.json') '{"bucket":"another"}'
        $tool=Get-PersonalTools | Where-Object Id -EQ 'lazymlflow'
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'lazymlflow' }
        (Get-PersonalToolOwner $tool -ScoopRoot $root -BinRoot $TestDrive).Kind | Should -Be 'unmanaged'
        Set-Content (Join-Path $current 'install.json') '{"bucket":"daviddwlee84"}'
        (Get-PersonalToolOwner $tool -ScoopRoot $root -BinRoot $TestDrive).Kind | Should -Be 'scoop'
        Mock Get-Command { [pscustomobject]@{Source='/some/other/lazymlflow.exe'} } -ParameterFilter { $Name -eq 'lazymlflow' }
        (Get-PersonalToolOwner $tool -ScoopRoot $root -BinRoot $TestDrive).Kind | Should -Be 'unmanaged'
    }
}
