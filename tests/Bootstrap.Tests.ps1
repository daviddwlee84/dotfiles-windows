#Requires -Version 7

BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $BootstrapPath = Join-Path $RepoRoot 'bootstrap.ps1'
    . $BootstrapPath

    function Assert-ArgumentList {
        param(
            [object[]]$Actual,
            [object[]]$Expected
        )

        @($Actual).Count | Should -Be @($Expected).Count
        for ($i = 0; $i -lt @($Expected).Count; $i++) {
            [string]$Actual[$i] | Should -BeExactly ([string]$Expected[$i])
        }
    }

    function New-PwshProbeResult {
        param(
            [string]$Edition = 'Core',
            [int]$Major = 7,
            [string]$Version = '7.5.2',
            [int]$ExitCode = 0
        )

        [pscustomobject]@{
            ExitCode = $ExitCode
            Output = @(
                'unrelated startup output'
                '__DOTFILES_BOOTSTRAP_PWSH__' + (@{
                        PSEdition = $Edition
                        Major = $Major
                        Version = $Version
                    } | ConvertTo-Json -Compress)
            )
        }
    }
}

Describe 'bootstrap script contract' {
    It 'keeps Windows PowerShell 5.1 compatibility and the canonical one-liner' {
        $source = Get-Content -Raw -LiteralPath $BootstrapPath
        (Get-Content -LiteralPath $BootstrapPath -TotalCount 1) | Should -BeExactly '#Requires -Version 5.1'
        $source | Should -Match ([regex]::Escape('irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex'))
    }

    It 'loads functions without running bootstrap when dot-sourced' {
        Get-Command Invoke-Bootstrap -CommandType Function | Should -Not -BeNullOrEmpty
    }
}

Describe 'bootstrap command resolution boundary' {
    It 'ignores a function shadow and resolves the real application' {
        function global:pwsh { throw 'function shadow must not be selected' }
        try {
            $resolved = Resolve-BootstrapCommand pwsh
            $resolved | Should -Not -BeNullOrEmpty
            (Get-Item -LiteralPath $resolved).PSIsContainer | Should -BeFalse
        } finally {
            Remove-Item Function:\pwsh -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an alias when no application has that name' {
        Set-Alias -Name BootstrapCommandAlias -Value Get-Item -Scope Global
        try {
            Resolve-BootstrapCommand BootstrapCommandAlias | Should -BeNullOrEmpty
        } finally {
            Remove-Item Alias:\BootstrapCommandAlias -ErrorAction SilentlyContinue
        }
    }

    It 'allows an external script only when explicitly requested for Scoop' {
        $externalScript = Join-Path $TestDrive 'bootstrap-scoop.ps1'
        Set-Content -LiteralPath $externalScript -Value 'exit 0'

        Resolve-BootstrapCommand $externalScript | Should -BeNullOrEmpty
        Resolve-BootstrapCommand $externalScript -AllowExternalScript | Should -BeExactly $externalScript
    }
}

Describe 'unattended bootstrap parameter validation' {
    BeforeEach {
        Mock Info {}
        Mock Ok {}
        Mock Assert-UnattendedFreshState {}
        Mock Get-ExecutionPolicy { 'Bypass' }
        Mock Set-ExecutionPolicy {}
        Mock Initialize-Scoop {}
        Mock Initialize-GitForScoop {}
        Mock Install-BaselineTools {}
        Mock Update-BootstrapPath {}
        Mock Get-RequiredPwshRuntime {
            [pscustomobject]@{ Path = 'C:\fake\pwsh.exe'; PSEdition = 'Core'; Major = 7; Version = '7.5.2' }
        }
        Mock Resolve-BootstrapCommand { 'C:\fake\chezmoi.exe' }
        Mock Invoke-ChezmoiSetup {}
    }

    It 'rejects invalid unattended combinations before any effect: case <Case>' -TestCases @(
        @{ Case = 'missing role';       Arguments = @{ NonInteractive = $true; Name = 'Ada'; Email = 'ada@example.com' } }
        @{ Case = 'workstation role';   Arguments = @{ NonInteractive = $true; Role = 'workstation'; Name = 'Ada'; Email = 'ada@example.com' } }
        @{ Case = 'missing name';       Arguments = @{ NonInteractive = $true; Role = 'minimal'; Email = 'ada@example.com' } }
        @{ Case = 'blank name';         Arguments = @{ NonInteractive = $true; Role = 'minimal'; Name = '   '; Email = 'ada@example.com' } }
        @{ Case = 'missing email';      Arguments = @{ NonInteractive = $true; Role = 'minimal'; Name = 'Ada' } }
        @{ Case = 'blank email';        Arguments = @{ NonInteractive = $true; Role = 'minimal'; Name = 'Ada'; Email = '   ' } }
        @{ Case = 'malformed email';    Arguments = @{ NonInteractive = $true; Role = 'minimal'; Name = 'Ada'; Email = 'not-an-email' } }
        @{ Case = 'email with spaces';  Arguments = @{ NonInteractive = $true; Role = 'minimal'; Name = 'Ada'; Email = ' ada@example.com ' } }
        @{ Case = 'values without switch'; Arguments = @{ Role = 'minimal'; Name = 'Ada'; Email = 'ada@example.com' } }
        @{ Case = 'role outside set';   Arguments = @{ NonInteractive = $true; Role = 'server'; Name = 'Ada'; Email = 'ada@example.com' } }
    ) {
        param($Case, $Arguments)
        $null = $Case, $Arguments

        { Invoke-Bootstrap @Arguments } | Should -Throw

        Should -Invoke Info -Times 0 -Exactly
        Should -Invoke Assert-UnattendedFreshState -Times 0 -Exactly
        Should -Invoke Get-ExecutionPolicy -Times 0 -Exactly
        Should -Invoke Set-ExecutionPolicy -Times 0 -Exactly
        Should -Invoke Initialize-Scoop -Times 0 -Exactly
        Should -Invoke Initialize-GitForScoop -Times 0 -Exactly
        Should -Invoke Install-BaselineTools -Times 0 -Exactly
        Should -Invoke Update-BootstrapPath -Times 0 -Exactly
        Should -Invoke Get-RequiredPwshRuntime -Times 0 -Exactly
        Should -Invoke Invoke-ChezmoiSetup -Times 0 -Exactly
    }
}

Describe 'unattended fresh-state preflight' {
    BeforeEach {
        $script:OriginalProcessPath = $env:PATH
        $script:OriginalUserProfile = $env:USERPROFILE
        $script:OriginalXdgConfigHome = $env:XDG_CONFIG_HOME
        $script:OriginalExplicitConfig = $env:CHEZMOI_CONFIG_FILE
        $env:USERPROFILE = Join-Path $TestDrive 'home'
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
        $env:CHEZMOI_CONFIG_FILE = Join-Path $TestDrive 'explicit.toml'
    }

    AfterEach {
        $env:PATH = $script:OriginalProcessPath
        $env:USERPROFILE = $script:OriginalUserProfile
        $env:XDG_CONFIG_HOME = $script:OriginalXdgConfigHome
        $env:CHEZMOI_CONFIG_FILE = $script:OriginalExplicitConfig
    }

    It 'checks explicit, XDG, and documented default config candidates' {
        $candidates = @(Get-UnattendedChezmoiConfigCandidates)

        $candidates | Should -Contain $env:CHEZMOI_CONFIG_FILE
        $candidates | Should -Contain (Join-Path (Join-Path $env:XDG_CONFIG_HOME 'chezmoi') 'chezmoi.toml')
        $defaultRoot = Join-Path $env:USERPROFILE '.config\chezmoi'
        $candidates | Should -Contain (Join-Path $defaultRoot 'chezmoi.toml')
        $candidates | Should -Contain (Join-Path $defaultRoot 'chezmoi.jsonc')
    }

    It 'rejects an existing config before resolving chezmoi or causing effects' {
        Set-Content -LiteralPath $env:CHEZMOI_CONFIG_FILE -Value '[data]'
        Mock Info {}
        Mock Get-ExecutionPolicy { 'Bypass' }
        Mock Initialize-Scoop {}
        Mock Initialize-GitForScoop {}
        Mock Install-BaselineTools {}
        Mock Resolve-BootstrapCommand { throw 'must not resolve after config match' }

        {
            Invoke-Bootstrap -NonInteractive -Role minimal -Name Ada -Email ada@example.com
        } | Should -Throw '*fresh chezmoi state*interactive chezmoi init*'

        Should -Invoke Info -Times 0 -Exactly
        Should -Invoke Get-ExecutionPolicy -Times 0 -Exactly
        Should -Invoke Initialize-Scoop -Times 0 -Exactly
        Should -Invoke Initialize-GitForScoop -Times 0 -Exactly
        Should -Invoke Install-BaselineTools -Times 0 -Exactly
        Should -Invoke Resolve-BootstrapCommand -Times 0 -Exactly
    }

    It 'rejects an existing resolved source before bootstrap effects' {
        Remove-Item Env:CHEZMOI_CONFIG_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        $sourcePath = Join-Path $TestDrive 'existing-source'
        New-Item -ItemType Directory -Path $sourcePath | Out-Null
        Mock Resolve-BootstrapCommand { 'C:\tools\chezmoi.exe' }
        Mock Get-ChezmoiSourcePath { $sourcePath }
        Mock Info {}
        Mock Get-ExecutionPolicy { 'Bypass' }
        Mock Initialize-Scoop {}
        Mock Initialize-GitForScoop {}
        Mock Install-BaselineTools {}

        {
            Invoke-Bootstrap -NonInteractive -Role minimal -Name Ada -Email ada@example.com
        } | Should -Throw '*existing source*interactive chezmoi init*'

        Should -Invoke Resolve-BootstrapCommand -Times 1 -Exactly -ParameterFilter {
            $CommandName -eq 'chezmoi' -and -not $AllowExternalScript
        }
        Should -Invoke Info -Times 0 -Exactly
        Should -Invoke Get-ExecutionPolicy -Times 0 -Exactly
        Should -Invoke Initialize-Scoop -Times 0 -Exactly
        Should -Invoke Initialize-GitForScoop -Times 0 -Exactly
        Should -Invoke Install-BaselineTools -Times 0 -Exactly
    }
}

Describe 'baseline PowerShell installation policy' {
    BeforeEach {
        $script:ScoopCalls = [System.Collections.Generic.List[object]]::new()
        Mock Info {}
        Mock Invoke-Scoop { $script:ScoopCalls.Add(@($ScoopArgs)) }
    }

    It 'refreshes metadata before installing the current stable pwsh package when missing' {
        Mock Resolve-BootstrapCommand {
            if ($CommandName -eq 'pwsh') { return $null }
            return "C:\fake\$CommandName.exe"
        }

        Install-BaselineTools

        Should -Invoke Invoke-Scoop -Times 3 -Exactly
        $script:ScoopCalls | Should -HaveCount 3
        Assert-ArgumentList -Actual $script:ScoopCalls[0] -Expected @('update')
        Assert-ArgumentList -Actual $script:ScoopCalls[1] -Expected @('install', '7zip')
        Assert-ArgumentList -Actual $script:ScoopCalls[2] -Expected @('install', 'pwsh')
    }

    It 'does not update metadata or upgrade an existing pwsh installation' {
        Mock Resolve-BootstrapCommand { "C:\fake\$CommandName.exe" }

        Install-BaselineTools

        Should -Invoke Invoke-Scoop -Times 1 -Exactly
        $script:ScoopCalls | Should -HaveCount 1
        Assert-ArgumentList -Actual $script:ScoopCalls[0] -Expected @('install', '7zip')
    }
}

Describe 'chezmoi bootstrap argument routing' {
    BeforeEach {
        $script:ChezmoiCalls = [System.Collections.Generic.List[object]]::new()
        Mock Info {}
        Mock Invoke-ChezmoiCommand {
            $script:ChezmoiCalls.Add([pscustomobject]@{
                    Path = $Path
                    Arguments = @($ArgumentList)
                })
        }
        Mock Test-ChezmoiSourceRepo { $false }
    }

    It 'passes a local source and exact unattended prompt arguments without shell parsing' {
        $source = 'C:\work trees\dots & more'
        $name = 'Ada O''Brien & Co = $(not-code)'
        $email = 'ada+ci=dogfood@example.com'

        Invoke-ChezmoiSetup -ChezmoiPath 'C:\tools\chezmoi.exe' -Source $source `
            -Role minimal -NonInteractive -Name $name -Email $email

        $script:ChezmoiCalls | Should -HaveCount 1
        $script:ChezmoiCalls[0].Path | Should -BeExactly 'C:\tools\chezmoi.exe'
        Assert-ArgumentList -Actual $script:ChezmoiCalls[0].Arguments -Expected @(
            'init', '--apply', '--source', $source,
            '--no-tty', '--promptDefaults',
            '--promptChoice', 'Role: workstation (full desktop) or minimal (shell only)=minimal',
            '--promptString', "Your full name (git)=$name",
            '--promptString', "Your git email=$email"
        )
    }

    It 'interpolates the validated role for reusable unattended arguments' {
        $arguments = @(Get-UnattendedChezmoiArguments -Role workstation `
            -Name 'Grace Hopper' -Email 'grace@example.com')

        $arguments | Should -Contain 'Role: workstation (full desktop) or minimal (shell only)=workstation'
    }

    It 'preserves repo and branch as distinct arguments on a fresh unattended init' {
        $repo = 'https://example.test/dots.git?x=1&y=two'
        $branch = 'feature/minimal & dogfood'

        Invoke-ChezmoiSetup -ChezmoiPath 'chezmoi.exe' -Repo $repo -Branch $branch `
            -Role minimal -NonInteractive -Name 'Linus Torvalds' -Email 'linus+test@example.com'

        $script:ChezmoiCalls | Should -HaveCount 1
        Assert-ArgumentList -Actual $script:ChezmoiCalls[0].Arguments -Expected @(
            'init', '--apply', '--branch', $branch, $repo,
            '--no-tty', '--promptDefaults',
            '--promptChoice', 'Role: workstation (full desktop) or minimal (shell only)=minimal',
            '--promptString', 'Your full name (git)=Linus Torvalds',
            '--promptString', 'Your git email=linus+test@example.com'
        )
    }

    It 'keeps the interactive local-source path unchanged' {
        Invoke-ChezmoiSetup -ChezmoiPath 'chezmoi.exe' -Source 'C:\dots'

        $script:ChezmoiCalls | Should -HaveCount 1
        Assert-ArgumentList -Actual $script:ChezmoiCalls[0].Arguments -Expected @('init', '--apply', '--source', 'C:\dots')
    }

    It 'keeps the interactive existing-source update path unchanged' {
        Mock Test-ChezmoiSourceRepo { $true }

        Invoke-ChezmoiSetup -ChezmoiPath 'chezmoi.exe'

        $script:ChezmoiCalls | Should -HaveCount 1
        Assert-ArgumentList -Actual $script:ChezmoiCalls[0].Arguments -Expected @('update', '--init')
    }

    It 'keeps the interactive fresh repo and branch path unchanged' {
        Invoke-ChezmoiSetup -ChezmoiPath 'chezmoi.exe' -Repo 'owner/repo' -Branch 'next'

        $script:ChezmoiCalls | Should -HaveCount 1
        Assert-ArgumentList -Actual $script:ChezmoiCalls[0].Arguments -Expected @('init', '--apply', '--branch', 'next', 'owner/repo')
    }
}

Describe 'PowerShell runtime validation' {
    It 'reports a successfully launched PowerShell Core 7 runtime' {
        Mock Invoke-PwshProbeProcess { New-PwshProbeResult -Edition Core -Major 7 -Version '7.5.2' }

        $runtime = Get-PwshRuntime -Path 'C:\scoop\shims\pwsh.exe'

        $runtime.Path | Should -BeExactly 'C:\scoop\shims\pwsh.exe'
        $runtime.PSEdition | Should -BeExactly 'Core'
        $runtime.Major | Should -Be 7
        $runtime.Version | Should -BeExactly '7.5.2'
        Should -Invoke Invoke-PwshProbeProcess -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\scoop\shims\pwsh.exe'
        }
    }

    It 'launches the resolved executable with NoProfile and NonInteractive' {
        $capturePath = Join-Path $TestDrive 'pwsh-probe-arguments.txt'
        $originalCapture = $env:BOOTSTRAP_PROBE_CAPTURE
        $env:BOOTSTRAP_PROBE_CAPTURE = $capturePath
        if ($IsWindows) {
            $fakePwsh = Join-Path $TestDrive 'bootstrap-probe-pwsh.cmd'
            @'
@echo off
>"%BOOTSTRAP_PROBE_CAPTURE%" echo %~1
>>"%BOOTSTRAP_PROBE_CAPTURE%" echo %~2
>>"%BOOTSTRAP_PROBE_CAPTURE%" echo %~3
 echo __DOTFILES_BOOTSTRAP_PWSH__{"PSEdition":"Core","Major":7,"Version":"7.99.0"}
exit /b 0
'@ | Set-Content -LiteralPath $fakePwsh -Encoding ascii
        } else {
            $fakePwsh = Join-Path $TestDrive 'bootstrap-probe-pwsh'
            @'
#!/bin/sh
printf '%s\n' "$1" "$2" "$3" > "$BOOTSTRAP_PROBE_CAPTURE"
printf '%s\n' '__DOTFILES_BOOTSTRAP_PWSH__{"PSEdition":"Core","Major":7,"Version":"7.99.0"}'
exit 0
'@ | Set-Content -LiteralPath $fakePwsh -Encoding utf8NoBOM
            & chmod +x $fakePwsh
        }

        try {
            $result = Invoke-PwshProbeProcess -Path $fakePwsh

            $result.ExitCode | Should -Be 0
            Assert-ArgumentList -Actual @(Get-Content -LiteralPath $capturePath) `
                -Expected @('-NoProfile', '-NonInteractive', '-Command')
        } finally {
            $env:BOOTSTRAP_PROBE_CAPTURE = $originalCapture
        }
    }

    It 'rejects an unlaunchable PowerShell executable' {
        Mock Invoke-PwshProbeProcess { throw 'process launch failed' }
        { Get-PwshRuntime -Path 'C:\broken\pwsh.exe' } | Should -Throw '*process launch failed*'
    }

    It 'rejects a PowerShell probe process that exits unsuccessfully' {
        Mock Invoke-PwshProbeProcess { New-PwshProbeResult -ExitCode 23 }
        { Get-PwshRuntime -Path 'C:\broken\pwsh.exe' } | Should -Throw '*exited with code 23*'
    }

    It 'rejects PowerShell Core older than version 7' {
        Mock Invoke-PwshProbeProcess { New-PwshProbeResult -Edition Core -Major 6 -Version '6.2.7' }
        { Get-PwshRuntime -Path 'C:\old\pwsh.exe' } | Should -Throw '*version 7 or newer*'
    }

    It 'rejects Windows PowerShell Desktop edition' {
        Mock Invoke-PwshProbeProcess { New-PwshProbeResult -Edition Desktop -Major 7 -Version '7.0.0' }
        { Get-PwshRuntime -Path 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } |
            Should -Throw '*Core is required*'
    }

    It 'fails when pwsh is still missing after PATH refresh' {
        Mock Resolve-BootstrapCommand { $null }
        Mock Get-PwshRuntime {}

        { Get-RequiredPwshRuntime } | Should -Throw '*pwsh not found*'
        Should -Invoke Get-PwshRuntime -Times 0 -Exactly
    }

    It 'stops before resolving or invoking chezmoi when runtime validation fails' {
        Mock Info {}
        Mock Ok {}
        Mock Assert-UnattendedFreshState {}
        Mock Get-ExecutionPolicy { 'Bypass' }
        Mock Initialize-Scoop {}
        Mock Initialize-GitForScoop {}
        Mock Install-BaselineTools {}
        Mock Update-BootstrapPath {}
        Mock Get-RequiredPwshRuntime { throw 'pwsh validation failed' }
        Mock Resolve-BootstrapCommand { 'chezmoi.exe' }
        Mock Invoke-ChezmoiSetup {}

        {
            Invoke-Bootstrap -NonInteractive -Role minimal -Name 'Ada' -Email 'ada@example.com'
        } | Should -Throw '*pwsh validation failed*'

        Should -Invoke Resolve-BootstrapCommand -Times 0 -Exactly -ParameterFilter { $CommandName -eq 'chezmoi' }
        Should -Invoke Invoke-ChezmoiSetup -Times 0 -Exactly
    }
}

Describe 'Scoop retry behavior' {
    BeforeEach {
        $script:ScoopAttempt = 0
        $script:ScoopArguments = [System.Collections.Generic.List[object]]::new()
        Mock Info {}
        Mock Reset-ScoopRepos {}
    }

    It 'accepts an explicit immediate-success result without retrying' {
        Mock Invoke-ScoopAttempt {
            $script:ScoopArguments.Add(@($ScoopArgs))
            [pscustomobject]@{ ExitCode = 0 }
        }

        { Invoke-Scoop install pwsh } | Should -Not -Throw

        Should -Invoke Invoke-ScoopAttempt -Times 1 -Exactly
        Should -Invoke Reset-ScoopRepos -Times 0 -Exactly
        Assert-ArgumentList -Actual $script:ScoopArguments[0] -Expected @('install', 'pwsh')
    }

    It 'rejects an omitted attempt result instead of defaulting to success' {
        Mock Invoke-ScoopAttempt { $null }

        { Invoke-Scoop install pwsh } | Should -Throw '*no exit-code result*'

        Should -Invoke Invoke-ScoopAttempt -Times 1 -Exactly
        Should -Invoke Reset-ScoopRepos -Times 0 -Exactly
    }

    It 'retries once after resetting repositories' {
        Mock Invoke-ScoopAttempt {
            $script:ScoopArguments.Add(@($ScoopArgs))
            $exitCode = if ($script:ScoopAttempt -eq 0) { 1 } else { 0 }
            $script:ScoopAttempt++
            [pscustomobject]@{ ExitCode = $exitCode }
        }

        { Invoke-Scoop install pwsh } | Should -Not -Throw

        Should -Invoke Invoke-ScoopAttempt -Times 2 -Exactly
        Should -Invoke Reset-ScoopRepos -Times 1 -Exactly
        $script:ScoopArguments | Should -HaveCount 2
        Assert-ArgumentList -Actual $script:ScoopArguments[0] -Expected @('install', 'pwsh')
        Assert-ArgumentList -Actual $script:ScoopArguments[1] -Expected @('install', 'pwsh')
    }

    It 'terminates when the retry also fails' {
        Mock Invoke-ScoopAttempt {
            $script:ScoopAttempt++
            [pscustomobject]@{ ExitCode = 42 }
        }

        { Invoke-Scoop install pwsh } | Should -Throw '*failed after retry*exit 42*'

        Should -Invoke Invoke-ScoopAttempt -Times 2 -Exactly
        Should -Invoke Reset-ScoopRepos -Times 1 -Exactly
        $script:ScoopAttempt | Should -Be 2
    }
}

Describe 'local script-body entry regression' {
    It 'does nothing when dot-sourced and runs with no arguments through IEX using external fakes' {
        $fakeBin = Join-Path $TestDrive 'bootstrap-fake-bin'
        $fakeHome = Join-Path $TestDrive 'bootstrap-fake-home'
        $capturePath = Join-Path $TestDrive 'bootstrap-calls.txt'
        $missingSource = Join-Path $TestDrive 'source-does-not-exist'
        New-Item -ItemType Directory -Path $fakeBin, $fakeHome | Out-Null

        if ($IsWindows) {
            $fakeCommands = @{
                'scoop.cmd' = @'
@echo off
>>"%BOOTSTRAP_CAPTURE%" echo scoop^|%*
exit /b 0
'@
                'git.cmd' = @'
@echo off
if /I "%~1"=="config" echo input
exit /b 0
'@
                'pwsh.cmd' = @'
@echo off
>>"%BOOTSTRAP_CAPTURE%" echo pwsh^|probe
 echo __DOTFILES_BOOTSTRAP_PWSH__{"PSEdition":"Core","Major":7,"Version":"7.99.0-test"}
exit /b 0
'@
                'chezmoi.cmd' = @'
@echo off
if /I "%~1"=="source-path" (
  >>"%BOOTSTRAP_CAPTURE%" echo chezmoi^|source-path
  echo %BOOTSTRAP_MISSING_SOURCE%
  exit /b 0
)
>>"%BOOTSTRAP_CAPTURE%" echo chezmoi^|%*
exit /b 0
'@
            }
            foreach ($entry in $fakeCommands.GetEnumerator()) {
                Set-Content -LiteralPath (Join-Path $fakeBin $entry.Key) -Value $entry.Value -Encoding ascii
            }
        } else {
            $fakeCommands = @{
                'scoop' = @'
#!/bin/sh
printf 'scoop|%s\n' "$*" >> "$BOOTSTRAP_CAPTURE"
exit 0
'@
                'git' = @'
#!/bin/sh
if [ "$1" = "config" ]; then printf 'input\n'; fi
exit 0
'@
                'pwsh' = @'
#!/bin/sh
printf 'pwsh|probe\n' >> "$BOOTSTRAP_CAPTURE"
printf '%s\n' '__DOTFILES_BOOTSTRAP_PWSH__{"PSEdition":"Core","Major":7,"Version":"7.99.0-test"}'
exit 0
'@
                'chezmoi' = @'
#!/bin/sh
if [ "$1" = "source-path" ]; then
  printf 'chezmoi|source-path\n' >> "$BOOTSTRAP_CAPTURE"
  printf '%s\n' "$BOOTSTRAP_MISSING_SOURCE"
  exit 0
fi
printf 'chezmoi|%s\n' "$*" >> "$BOOTSTRAP_CAPTURE"
exit 0
'@
            }
            foreach ($entry in $fakeCommands.GetEnumerator()) {
                $path = Join-Path $fakeBin $entry.Key
                Set-Content -LiteralPath $path -Value $entry.Value -Encoding utf8NoBOM
                & chmod +x $path
            }
        }

        $escape = { param($Value) ([string]$Value).Replace("'", "''") }
        $harnessPath = Join-Path $TestDrive 'bootstrap-iex-harness.ps1'
        $harness = @'
$bootstrap = '__BOOTSTRAP_PATH__'
$env:PATH = '__FAKE_BIN__' + [IO.Path]::PathSeparator + $env:PATH
$env:USERPROFILE = '__FAKE_HOME__'
$env:SCOOP = Join-Path $env:USERPROFILE 'scoop-does-not-exist'
$env:BOOTSTRAP_CAPTURE = '__CAPTURE_PATH__'
$env:BOOTSTRAP_MISSING_SOURCE = '__MISSING_SOURCE__'
Remove-Item Env:XDG_CONFIG_HOME, Env:CHEZMOI_CONFIG_FILE -ErrorAction SilentlyContinue

function global:Get-ExecutionPolicy { 'Bypass' }
function global:Set-ExecutionPolicy { throw 'Set-ExecutionPolicy must not run in this harness' }

$afterDotSource = & {
    . $bootstrap
    if (Test-Path -LiteralPath $env:BOOTSTRAP_CAPTURE) {
        @(Get-Content -LiteralPath $env:BOOTSTRAP_CAPTURE).Count
    } else {
        0
    }
}
Get-Content -Raw -LiteralPath $bootstrap | Invoke-Expression

$result = [ordered]@{
    AfterDotSource = $afterDotSource
    Calls = @(Get-Content -LiteralPath $env:BOOTSTRAP_CAPTURE -ErrorAction SilentlyContinue)
}
'__BOOTSTRAP_TEST_RESULT__' + ($result | ConvertTo-Json -Compress)
'@
        $harness = $harness.Replace('__BOOTSTRAP_PATH__', (& $escape $BootstrapPath))
        $harness = $harness.Replace('__FAKE_BIN__', (& $escape $fakeBin))
        $harness = $harness.Replace('__FAKE_HOME__', (& $escape $fakeHome))
        $harness = $harness.Replace('__CAPTURE_PATH__', (& $escape $capturePath))
        $harness = $harness.Replace('__MISSING_SOURCE__', (& $escape $missingSource))
        Set-Content -LiteralPath $harnessPath -Value $harness -Encoding utf8NoBOM

        $currentPwsh = (Get-Process -Id $PID).Path
        $output = @(& $currentPwsh -NoProfile -NonInteractive -File $harnessPath 2>&1)
        $exitCode = $LASTEXITCODE
        $resultLine = @($output | ForEach-Object { [string]$_ } |
            Where-Object { $_.StartsWith('__BOOTSTRAP_TEST_RESULT__') } | Select-Object -Last 1)

        $exitCode | Should -Be 0 -Because ($output -join "`n")
        $resultLine | Should -HaveCount 1 -Because ($output -join "`n")
        $result = $resultLine[0].Substring('__BOOTSTRAP_TEST_RESULT__'.Length) | ConvertFrom-Json
        $result.AfterDotSource | Should -Be 0
        @($result.Calls | Where-Object { $_ -like 'scoop|*' }) | Should -Not -BeNullOrEmpty
        @($result.Calls | Where-Object { $_ -like 'pwsh|*' }) | Should -HaveCount 1
        @($result.Calls | Where-Object { $_ -eq 'chezmoi|source-path' }) | Should -HaveCount 1
        @($result.Calls | Where-Object { $_ -like 'chezmoi|init *' }) | Should -HaveCount 1
    }
}
