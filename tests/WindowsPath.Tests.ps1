#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $PathHelper = Join-Path $RepoRoot 'scripts' 'windows-path-precedence.ps1'
    $ProfileTemplate = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '00_env.ps1.tmpl'
    $PackagesTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $BootstrapPath = Join-Path $RepoRoot 'bootstrap.ps1'

    . $PathHelper
    . $BootstrapPath
}

Describe 'Windows PATH entry normalization' {
    BeforeEach {
        $script:OriginalPath = $env:PATH
        $script:OriginalAdaRoot = $env:ADA_PATH_ROOT
        $env:ADA_PATH_ROOT = Join-Path $TestDrive 'Ada'
    }

    AfterEach {
        $env:PATH = $script:OriginalPath
        if ($null -eq $script:OriginalAdaRoot) {
            Remove-Item Env:ADA_PATH_ROOT -ErrorAction SilentlyContinue
        } else {
            $env:ADA_PATH_ROOT = $script:OriginalAdaRoot
        }
    }

    It 'expands variables, drops empty entries, and deduplicates case-insensitively' {
        $entries = @(ConvertTo-WindowsPathEntries -PathValues @(
            ' ;%ADA_PATH_ROOT%\Tools;;C:\Users\Ada\Portable\bin '
            '%ADA_PATH_ROOT%\TOOLS;c:\users\ada\portable\BIN; '
        ))

        $entries | Should -HaveCount 2
        $entries[0] | Should -BeExactly "$env:ADA_PATH_ROOT\Tools"
        $entries[1] | Should -BeExactly 'C:\Users\Ada\Portable\bin'
    }

    It 'orders process-only, managed, stored User, then Machine entries' {
        $processPath = @(
            'C:\Users\Ada\Portable\bin'
            'C:\Users\Ada\Machine\OldBin'
            'C:\Users\Ada\Apps\Second'
            'C:\Users\Ada\scoop\shims'
        ) -join ';'
        $managedPaths = @(
            'C:\Users\Ada\scoop\shims'
            'C:\Users\Ada\.local\bin'
        )
        $userPath = @(
            'C:\Users\Ada\Apps\First'
            'C:\Users\Ada\Apps\Second'
            'c:\users\ada\SCOOP\SHIMS'
        ) -join ';'
        $machinePath = @(
            'c:\users\ada\machine\oldbin'
            'C:\Users\Ada\Machine\SystemBin'
            'C:\USERS\ADA\APPS\FIRST'
        ) -join ';'

        Set-WindowsPathPrecedence -ProcessPath $processPath -ManagedPaths $managedPaths `
            -UserPath $userPath -MachinePath $machinePath

        $env:PATH | Should -BeExactly (@(
            'C:\Users\Ada\Portable\bin'
            'C:\Users\Ada\scoop\shims'
            'C:\Users\Ada\.local\bin'
            'C:\Users\Ada\Apps\First'
            'C:\Users\Ada\Apps\Second'
            'c:\users\ada\machine\oldbin'
            'C:\Users\Ada\Machine\SystemBin'
        ) -join ';')
    }

    It 'preserves multiple process-only entries in their inherited order' {
        Set-WindowsPathPrecedence `
            -ProcessPath 'C:\Users\Ada\Portable\One;C:\Users\Ada\Machine\Bin;C:\Users\Ada\Portable\Two' `
            -UserPath 'C:\Users\Ada\User\Bin' `
            -MachinePath 'C:\Users\Ada\Machine\Bin'

        $env:PATH | Should -BeExactly (@(
            'C:\Users\Ada\Portable\One'
            'C:\Users\Ada\Portable\Two'
            'C:\Users\Ada\User\Bin'
            'C:\Users\Ada\Machine\Bin'
        ) -join ';')
    }

    It 'only mutates the process PATH and contains no registry write call' {
        $source = Get-Content -Raw -LiteralPath $PathHelper
        $source | Should -Not -Match 'SetEnvironmentVariable'

        Set-WindowsPathPrecedence -ProcessPath '' -UserPath 'C:\Users\Ada\User\Bin' -MachinePath ''
        $env:PATH | Should -BeExactly 'C:\Users\Ada\User\Bin'
    }
}

Describe 'profile and no-profile package integration' {
    It 'includes and calls the shared helper before profile command resolution' {
        $source = Get-Content -Raw -LiteralPath $ProfileTemplate
        $include = $source.IndexOf('{{ include "scripts/windows-path-precedence.ps1" | replace ')
        $call = $source.IndexOf('Set-WindowsPathPrecedence -ManagedPaths $ProfilePaths')
        $commandLookup = $source.IndexOf('Get-Command nvim')
        $profilePaths = $source.IndexOf('$ProfilePaths = @(')
        $scoopShims = $source.IndexOf("Join-Path `$HOME 'scoop/shims'", $profilePaths)
        $localBin = $source.IndexOf("Join-Path `$HOME '.local/bin'", $profilePaths)

        $include | Should -BeGreaterOrEqual 0
        $call | Should -BeGreaterThan $include
        $commandLookup | Should -BeGreaterThan $call
        $profilePaths | Should -BeGreaterOrEqual 0
        $scoopShims | Should -BeGreaterThan $profilePaths
        $localBin | Should -BeGreaterThan $scoopShims
        $source | Should -Not -Match 'function Set-ManagedPathPrecedence'
    }

    It 'normalizes a direct no-profile package run before command lookup and after Scoop writes PATH' {
        $source = Get-Content -Raw -LiteralPath $PackagesTemplate
        $include = $source.IndexOf('{{ include "scripts/windows-path-precedence.ps1" | replace ')
        $firstCall = $source.IndexOf('Set-WindowsPathPrecedence')
        $have = $source.IndexOf('function Have')

        $include | Should -BeGreaterOrEqual 0
        $firstCall | Should -BeGreaterThan $include
        $have | Should -BeGreaterThan $firstCall
        $source | Should -Match '(?s)function Ensure-Scoop.*?Set-WindowsPathPrecedence.*?foreach \(\$b in'
        $source | Should -Match '(?s)function Scoop-Install.*?scoop install @missing.*?Set-WindowsPathPrecedence'
    }
}

Describe 'self-contained bootstrap PATH mirror' {
    BeforeEach {
        $script:OriginalPath = $env:PATH
        $script:BootstrapUserPath = ''
        $script:BootstrapMachinePath = ''
        Mock Get-PersistedBootstrapPath {
            if ($Scope -eq 'User') { return $script:BootstrapUserPath }
            return $script:BootstrapMachinePath
        }
    }

    AfterEach {
        $env:PATH = $script:OriginalPath
    }

    It 'matches the shared process-only, User, Machine algorithm' {
        $processPath = @(
            'C:\Users\Ada\Portable\One'
            'C:\Users\Ada\Machine\OldBin'
            'C:\Users\Ada\User\Second'
            'C:\Users\Ada\Portable\Two'
        ) -join ';'
        $script:BootstrapUserPath = 'C:\Users\Ada\User\First;C:\Users\Ada\User\Second'
        $script:BootstrapMachinePath = 'c:\users\ada\machine\OLDBIN;C:\Users\Ada\Machine\SystemBin'

        Set-WindowsPathPrecedence -ProcessPath $processPath `
            -UserPath $script:BootstrapUserPath -MachinePath $script:BootstrapMachinePath
        $sharedPath = $env:PATH

        $env:PATH = $processPath
        Update-BootstrapPath

        $env:PATH | Should -BeExactly $sharedPath
        $env:PATH | Should -BeExactly (@(
            'C:\Users\Ada\Portable\One'
            'C:\Users\Ada\Portable\Two'
            'C:\Users\Ada\User\First'
            'C:\Users\Ada\User\Second'
            'c:\users\ada\machine\OLDBIN'
            'C:\Users\Ada\Machine\SystemBin'
        ) -join ';')
    }

    It 'normalizes before bootstrap command probes and stays dependency-free for irm pipe Invoke-Expression' {
        $source = Get-Content -Raw -LiteralPath $BootstrapPath
        $invoke = $source.IndexOf('function Invoke-Bootstrap')
        $validation = $source.IndexOf('Assert-BootstrapParameters', $invoke)
        $initialRefresh = $source.IndexOf('Update-BootstrapPath', $validation)
        $preflight = $source.IndexOf('Assert-UnattendedFreshState', $validation)

        $invoke | Should -BeGreaterOrEqual 0
        $validation | Should -BeGreaterThan $invoke
        $initialRefresh | Should -BeGreaterThan $validation
        $preflight | Should -BeGreaterThan $initialRefresh
        $source | Should -Not -Match '\{\{\s*(?:include|template)'
        $source | Should -Not -Match '(?m)^\s*\.\s+.*windows-path-precedence'
        $source | Should -Match 'scripts/windows-path-precedence\.ps1'
    }
}
