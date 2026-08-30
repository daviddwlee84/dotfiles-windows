#Requires -Version 7

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $PackageTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $ExternalTemplate = Join-Path $RepoRoot '.chezmoiexternal.toml.tmpl'
    $EnvironmentProfile = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '00_env.ps1.tmpl'
    $ToolsProfile = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '10_tools.ps1'
    $EnvironmentScript = Join-Path $RepoRoot '.chezmoiscripts' 'run_after_11_pi_agents_environment.ps1.tmpl'
    $ManagedPiLauncher = Join-Path $RepoRoot 'dot_config' 'powershell' 'bin' 'pia-pi.ps1'
    $ManagedPiCmdLauncher = Join-Path $RepoRoot 'dot_config' 'powershell' 'bin' 'pi.cmd'
    $OmpCorePath = Join-Path $RepoRoot 'scripts' 'omp-install-core.ps1'
    $Justfile = Join-Path $RepoRoot 'justfile'

    . (Join-Path $RepoRoot 'scripts' 'package-source-runner.ps1')
    . (Join-Path $RepoRoot 'scripts' 'pi-package-core.ps1')
    . (Join-Path $RepoRoot 'scripts' 'omp-install-core.ps1')

    function New-TestNpmContext {
        param([Parameter(Mandatory)] [string] $Root)
        [pscustomobject]@{
            NodeExecutable = 'node.exe'
            NpmCli = 'npm-cli.js'
            Root = $Root
            Prefix = (Split-Path -Parent $Root)
            Cache = (Join-Path $Root '.cache')
            ConfigValues = @{}
        }
    }

    function Add-TestPackageManifest {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [Parameter(Mandatory)] [string] $Package
        )
        $manifest = Get-NpmGlobalPackageManifestPath -Root $Root -Package $Package
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
        '{}' | Set-Content -LiteralPath $manifest
        $manifest
    }

    function Add-TestPiInstall {
        param([Parameter(Mandatory)] $NpmContext)
        $manifest = Add-TestPackageManifest -Root $NpmContext.Root `
            -Package '@earendil-works/pi-coding-agent'
        '{"bin":{"pi":"dist/cli.js"}}' | Set-Content -LiteralPath $manifest -NoNewline
        $entrypoint = Join-Path (Split-Path -Parent $manifest) 'dist/cli.js'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entrypoint) | Out-Null
        'entrypoint' | Set-Content -LiteralPath $entrypoint -NoNewline
        $manifest
    }

    function Add-TestDeprecatedPiInstall {
        param([Parameter(Mandatory)] $NpmContext)
        $manifest = Add-TestPackageManifest -Root $NpmContext.Root `
            -Package '@mariozechner/pi-coding-agent'
        foreach ($shim in (Get-PiMigrationShimPaths -Prefix $NpmContext.Prefix)) {
            'deprecated-shim' | Set-Content -LiteralPath $shim -NoNewline
        }
        $manifest
    }

    function Render-External {
        param([bool] $Enabled)
        $data = @{ installCodingAgents = $Enabled } | ConvertTo-Json -Compress
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $ExternalTemplate
        if ($LASTEXITCODE -ne 0) { throw 'failed to render external template' }
        $rendered -join "`n"
    }

    function Render-EnvironmentProfile {
        param([bool] $Enabled)
        $data = @{ installCodingAgents = $Enabled } | ConvertTo-Json -Compress
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $EnvironmentProfile
        if ($LASTEXITCODE -ne 0) { throw 'failed to render environment profile' }
        $rendered -join "`n"
    }

    function Render-EnvironmentScript {
        param([bool] $Enabled)
        $data = @{ installCodingAgents = $Enabled } | ConvertTo-Json -Compress
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $EnvironmentScript
        if ($LASTEXITCODE -ne 0) { throw 'failed to render persistent environment script' }
        $rendered -join "`n"
    }
}

Describe 'Pi npm package lifecycle' {
    BeforeEach {
        $script:NpmRoot = Join-Path $TestDrive 'node_modules'
        Remove-Item -LiteralPath $script:NpmRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $script:NpmRoot | Out-Null
        $script:NpmContext = New-TestNpmContext -Root $script:NpmRoot
        $script:PackageArguments = @()
        Mock Invoke-PackageSourceCommand {
            $script:PackageArguments = @($Arguments)
            if ($Arguments -contains '@earendil-works/pi-coding-agent') {
                $null = Add-TestPiInstall -NpmContext $script:NpmContext
            }
            [pscustomobject]@{ Succeeded = $true; ExitCode = 0 }
        }
        Mock Invoke-InteractivePackageProcess {
            [pscustomobject]@{ ExitCode = 0 }
        }
        Mock Get-PiNodeVersion { [version] '22.19.0' }
        Mock Test-PiCanonicalEntrypoint { $true }
    }

    It 'installs the canonical package through source policy with lifecycle scripts disabled' {
        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $true -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        ($script:PackageArguments -join ' ') | Should -BeExactly `
            'npm-cli.js install -g --ignore-scripts --no-bin-links @earendil-works/pi-coding-agent'
        Should -Invoke Invoke-PackageSourceCommand -Times 1 -Exactly -ParameterFilter {
            $Manager -eq 'npm' -and
            $PackageSpec -eq '@earendil-works/pi-coding-agent' -and
            $ManagedMachine -and -not $AllowPublicFallback
        }
    }

    It 'normalizes Pi to the owned Scoop npm prefix regardless of ambient npm config' {
        $savedScoop = $env:SCOOP
        try {
            $env:SCOOP = Join-Path $TestDrive 'CustomScoop'
            $ambient = New-TestNpmContext -Root (Join-Path $TestDrive 'ForeignPrefix/node_modules')

            $owned = Get-PiOwnedNpmContext -NpmContext $ambient

            $owned.Prefix | Should -BeExactly (Join-Path $env:SCOOP 'persist\nodejs-lts\bin')
            $owned.Root | Should -BeExactly (Join-Path $owned.Prefix 'node_modules')
            (Get-PiOwnedNpmCommandPath) | Should -BeExactly `
                (Join-Path $env:SCOOP 'apps\nodejs-lts\current\npm.cmd')
        } finally {
            if ($null -eq $savedScoop) { Remove-Item Env:SCOOP -ErrorAction SilentlyContinue }
            else { $env:SCOOP = $savedScoop }
        }
    }

    It 'rejects a bin target that escapes the canonical package root' {
        $manifest = Add-TestPiInstall -NpmContext $script:NpmContext
        $outside = Join-Path $TestDrive 'outside.js'
        'outside' | Set-Content -LiteralPath $outside -NoNewline
        '{"bin":{"pi":"../../outside.js"}}' | Set-Content -LiteralPath $manifest -NoNewline

        Test-PiCanonicalInstall -NpmContext $script:NpmContext | Should -BeFalse
        Should -Invoke Test-PiCanonicalEntrypoint -Times 0 -Exactly
    }

    It 'rejects a canonical entrypoint whose version probe fails' {
        $null = Add-TestPiInstall -NpmContext $script:NpmContext
        Mock Test-PiCanonicalEntrypoint { $false }

        Test-PiCanonicalInstall -NpmContext $script:NpmContext | Should -BeFalse
        Should -Invoke Test-PiCanonicalEntrypoint -Times 1 -Exactly
    }

    It 'removes only the exact deprecated package before installing the replacement' {
        $deprecated = Add-TestPackageManifest -Root $script:NpmRoot `
            -Package '@mariozechner/pi-coding-agent'
        $unrelated = Add-TestPackageManifest -Root $script:NpmRoot `
            -Package '@example/pi-coding-agent'
        Mock Invoke-InteractivePackageProcess {
            Remove-Item -LiteralPath $deprecated -Force
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        $deprecated | Should -Not -Exist
        $unrelated | Should -Exist
        Should -Invoke Invoke-InteractivePackageProcess -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join ' ') -match 'uninstall -g --ignore-scripts @mariozechner/pi-coding-agent' -and
            ($Arguments -join ' ') -notmatch '@example/pi-coding-agent'
        }
    }

    It 'does not touch a foreign pi command when the deprecated manifest is absent' {
        foreach ($shim in (Get-PiMigrationShimPaths -Prefix $script:NpmContext.Prefix)) {
            'foreign-pi-shim' | Set-Content -LiteralPath $shim -NoNewline
        }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        Should -Invoke Invoke-InteractivePackageProcess -Times 0 -Exactly
        Should -Invoke Invoke-PackageSourceCommand -Times 1 -Exactly
        foreach ($shim in (Get-PiMigrationShimPaths -Prefix $script:NpmContext.Prefix)) {
            (Get-Content -Raw -LiteralPath $shim) | Should -BeExactly 'foreign-pi-shim'
        }
    }

    It 'cleans a partial fresh install so the next apply retries instead of skipping' {
        $script:FreshInstallAttempt = 0
        Mock Invoke-PackageSourceCommand {
            $script:FreshInstallAttempt++
            $null = Add-TestPiInstall -NpmContext $script:NpmContext
            [pscustomobject]@{
                Succeeded = $script:FreshInstallAttempt -gt 1
                ExitCode = $(if ($script:FreshInstallAttempt -gt 1) { 0 } else { 23 })
            }
        }

        $first = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false
        $manifest = Get-NpmGlobalPackageManifestPath -Root $script:NpmRoot `
            -Package '@earendil-works/pi-coding-agent'

        $first.Succeeded | Should -BeFalse
        $manifest | Should -Not -Exist

        $second = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false
        $second.Succeeded | Should -BeTrue
        $second.Skipped | Should -Not -BeTrue
        $script:FreshInstallAttempt | Should -Be 2
        $manifest | Should -Exist
    }

    It 'uses update with ignore-scripts when the canonical package is installed' {
        $null = Add-TestPiInstall -NpmContext $script:NpmContext

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Update -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        ($script:PackageArguments -join ' ') | Should -BeExactly `
            "npm-cli.js update -g --ignore-scripts --no-bin-links @earendil-works/pi-coding-agent --prefix=$($script:NpmContext.Prefix)"
    }

    It 'skips an explicit update before the Node gate when Pi was never installed' {
        Mock Get-PiNodeVersion { [version] '22.18.0' }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Update -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        $result.Skipped | Should -BeTrue
        Should -Invoke Get-PiNodeVersion -Times 0 -Exactly
        Should -Invoke Invoke-InteractivePackageProcess -Times 0 -Exactly
        Should -Invoke Invoke-PackageSourceCommand -Times 0 -Exactly
    }

    It 'reinstalls canonical Pi after coexistence migration removes legacy shims' {
        $null = Add-TestPiInstall -NpmContext $script:NpmContext
        $deprecated = Add-TestPackageManifest -Root $script:NpmRoot `
            -Package '@mariozechner/pi-coding-agent'
        Mock Invoke-InteractivePackageProcess {
            Remove-Item -LiteralPath $deprecated -Force
            foreach ($shim in (Get-PiShimPaths -Prefix $script:NpmContext.Prefix)) {
                Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue
            }
            [pscustomobject]@{ ExitCode = 0 }
        }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        ($script:PackageArguments -join ' ') | Should -Match 'install -g --ignore-scripts --no-bin-links'
        Test-PiCanonicalInstall -NpmContext $script:NpmContext | Should -BeTrue
    }

    It 'preserves foreign npm shims because the canonical package uses no bin links' {
        $null = Add-TestPiInstall -NpmContext $script:NpmContext
        foreach ($shim in (Get-PiShimPaths -Prefix $script:NpmContext.Prefix)) {
            'node_modules/@example/foreign-pi/dist/cli.js' | Set-Content -LiteralPath $shim -NoNewline
        }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeTrue
        Test-PiCanonicalInstall -NpmContext $script:NpmContext | Should -BeTrue
        Should -Invoke Invoke-PackageSourceCommand -Times 0 -Exactly
        foreach ($shim in (Get-PiShimPaths -Prefix $script:NpmContext.Prefix)) {
            (Get-Content -Raw -LiteralPath $shim) | Should -Match '@example/foreign-pi'
        }
    }

    It 'restores the working deprecated package and shims when migration fails' {
        $deprecated = Add-TestDeprecatedPiInstall -NpmContext $script:NpmContext
        $unrelated = Add-TestPackageManifest -Root $script:NpmRoot -Package '@example/pi-coding-agent'
        Mock Invoke-InteractivePackageProcess {
            Remove-Item -LiteralPath (Split-Path -Parent $deprecated) -Recurse -Force
            foreach ($shim in (Get-PiMigrationShimPaths -Prefix $script:NpmContext.Prefix)) {
                Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue
            }
            [pscustomobject]@{ ExitCode = 0 }
        }
        Mock Invoke-PackageSourceCommand {
            [pscustomobject]@{ Succeeded = $false; ExitCode = 17 }
        }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeFalse
        $result.ExitCode | Should -Be 17
        $result.Failure | Should -Match 'rollback restored=True'
        $deprecated | Should -Exist
        $unrelated | Should -Exist
        foreach ($shim in (Get-PiMigrationShimPaths -Prefix $script:NpmContext.Prefix)) {
            $shim | Should -Exist
            (Get-Content -Raw -LiteralPath $shim) | Should -BeExactly 'deprecated-shim'
        }
        (Get-NpmGlobalPackageManifestPath -Root $script:NpmRoot `
            -Package '@earendil-works/pi-coding-agent') | Should -Not -Exist
    }

    It 'restores the migration snapshot when the package source helper throws' {
        $deprecated = Add-TestDeprecatedPiInstall -NpmContext $script:NpmContext
        Mock Invoke-InteractivePackageProcess {
            Remove-Item -LiteralPath (Split-Path -Parent $deprecated) -Recurse -Force
            foreach ($shim in (Get-PiMigrationShimPaths -Prefix $script:NpmContext.Prefix)) {
                Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue
            }
            [pscustomobject]@{ ExitCode = 0 }
        }
        Mock Invoke-PackageSourceCommand { throw 'registry transport exploded' }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeFalse
        $result.Failure | Should -Match 'package operation threw.*rollback restored=True'
        $deprecated | Should -Exist
    }

    It 'retains the recovery snapshot when rollback itself fails' {
        $deprecated = Add-TestDeprecatedPiInstall -NpmContext $script:NpmContext
        Mock Invoke-InteractivePackageProcess {
            Remove-Item -LiteralPath (Split-Path -Parent $deprecated) -Recurse -Force
            [pscustomobject]@{ ExitCode = 0 }
        }
        Mock Invoke-PackageSourceCommand { [pscustomobject]@{ Succeeded = $false; ExitCode = 19 } }
        Mock Restore-PiMigrationSnapshot { $false }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $match = [regex]::Match($result.Failure, 'rollback restored=False; recovery snapshot=(.+)$')
        $match.Success | Should -BeTrue
        $snapshot = $match.Groups[1].Value
        $snapshot | Should -Exist
        Remove-Item -LiteralPath $snapshot -Recurse -Force
    }

    It 'fails clearly before any npm action when Scoop Node is too old' {
        $null = Add-TestPackageManifest -Root $script:NpmRoot `
            -Package '@mariozechner/pi-coding-agent'
        Mock Get-PiNodeVersion { [version] '22.18.0' }

        $result = Invoke-PiCodingAgentPackageCommand -NpmContext $script:NpmContext `
            -Action Install -ManagedMachine $false -AllowPublicFallback $false

        $result.Succeeded | Should -BeFalse
        $result.Failure | Should -BeExactly 'requires Node >= 22.19.0; found 22.18.0'
        Should -Invoke Invoke-InteractivePackageProcess -Times 0 -Exactly
        Should -Invoke Invoke-PackageSourceCommand -Times 0 -Exactly
    }
}

Describe 'OMP official binary lifecycle' {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $script:SavedPiInstallDirectory = $env:PI_INSTALL_DIR
        $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
        Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:OMP_TEST_BINARY_SWITCH -ErrorAction SilentlyContinue
        Remove-Item Env:OMP_TEST_INSTALL_DIR -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:SavedLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue }
        else { $env:LOCALAPPDATA = $script:SavedLocalAppData }
        if ($null -eq $script:SavedPiInstallDirectory) { Remove-Item Env:PI_INSTALL_DIR -ErrorAction SilentlyContinue }
        else { $env:PI_INSTALL_DIR = $script:SavedPiInstallDirectory }
        Remove-Item Env:OMP_TEST_BINARY_SWITCH -ErrorAction SilentlyContinue
        Remove-Item Env:OMP_TEST_INSTALL_DIR -ErrorAction SilentlyContinue
    }

    It 'invokes the official installer as a scriptblock with Binary' {
        $env:PI_INSTALL_DIR = Join-Path $TestDrive 'hostile-install-root'
        Mock Invoke-RestMethod {
            'param([switch] $Binary); $env:OMP_TEST_BINARY_SWITCH = [string][bool]$Binary; $env:OMP_TEST_INSTALL_DIR = $env:PI_INSTALL_DIR'
        }

        Invoke-OmpOfficialBinaryInstaller

        $env:OMP_TEST_BINARY_SWITCH | Should -BeExactly 'True'
        $env:OMP_TEST_INSTALL_DIR | Should -BeExactly (Split-Path -Parent (Get-OmpBinaryPath))
        $env:PI_INSTALL_DIR | Should -BeExactly (Join-Path $TestDrive 'hostile-install-root')
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://omp.sh/install.ps1'
        }
    }

    It 'snapshots and restores raw expandable User PATH around the upstream installer' {
        $source = Get-Content -Raw -LiteralPath $OmpCorePath
        $source | Should -Match 'DoNotExpandEnvironmentNames'
        $source | Should -Match "GetValueKind\('Path'\)"
        $source | Should -Match ([regex]::Escape("`$key.SetValue('Path', `$Snapshot.Value, `$Snapshot.Kind)"))
        $source | Should -Match '(?s)Get-OmpUserPathSnapshot.*& \$installer -Binary.*Restore-OmpUserPathSnapshot'
        $source | Should -Match 'Send-OmpEnvironmentChangeNotification'
    }

    It 'accepts only the exact owned binary after a non-empty version probe' {
        $expected = Get-OmpBinaryPath
        Mock Add-ScoopGitBashToProcessPath {}
        Mock Invoke-OmpOfficialBinaryInstaller {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $expected) | Out-Null
            'fake' | Set-Content -LiteralPath $expected
        }
        Mock Get-OmpBinaryVersion { 'omp 18.0.11' } -ParameterFilter { $Path -eq $expected }

        Install-OmpBinary -Force | Should -BeTrue
        Should -Invoke Invoke-OmpOfficialBinaryInstaller -Times 1 -Exactly
        Should -Invoke Get-OmpBinaryVersion -Times 1 -Exactly -ParameterFilter { $Path -eq $expected }
    }

    It 'fails verification when the installer creates no owned binary' {
        Mock Add-ScoopGitBashToProcessPath {}
        Mock Invoke-OmpOfficialBinaryInstaller {}
        Mock Get-OmpBinaryVersion { 'foreign omp' }

        Install-OmpBinary -Force -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke Get-OmpBinaryVersion -Times 0 -Exactly
    }

    It 'fails verification when the exact binary version probe fails' {
        $expected = Get-OmpBinaryPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $expected) | Out-Null
        'fake' | Set-Content -LiteralPath $expected
        Mock Add-ScoopGitBashToProcessPath {}
        Mock Invoke-OmpOfficialBinaryInstaller {}
        Mock Get-OmpBinaryVersion { throw 'empty version' } -ParameterFilter { $Path -eq $expected }

        Install-OmpBinary -Force -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'restores the previous owned binary when an upgrade overwrites then fails' {
        $expected = Get-OmpBinaryPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $expected) | Out-Null
        'known-good' | Set-Content -LiteralPath $expected -NoNewline
        Mock Add-ScoopGitBashToProcessPath {}
        Mock Invoke-OmpOfficialBinaryInstaller {
            'broken' | Set-Content -LiteralPath $expected -NoNewline
            throw 'download failed after overwrite'
        }

        Install-OmpBinary -Force -WarningAction SilentlyContinue | Should -BeFalse
        (Get-Content -Raw -LiteralPath $expected) | Should -BeExactly 'known-good'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $expected) -Filter '*.pia-backup-*').Count |
            Should -Be 0
    }

    It 'retains the last-good OMP copy when rollback cannot replace the binary' {
        $expected = Get-OmpBinaryPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $expected) | Out-Null
        'known-good' | Set-Content -LiteralPath $expected -NoNewline
        Mock Add-ScoopGitBashToProcessPath {}
        Mock Invoke-OmpOfficialBinaryInstaller {
            'broken' | Set-Content -LiteralPath $expected -NoNewline
            throw 'installer failed'
        }
        Mock Move-Item { Write-Error 'binary is locked' -ErrorAction Stop } -ParameterFilter {
            $LiteralPath -like '*.pia-backup-*'
        }

        Install-OmpBinary -Force -WarningAction SilentlyContinue | Should -BeFalse
        $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $expected) -Filter '*.pia-backup-*')
        $backups.Count | Should -Be 1
        (Get-Content -Raw -LiteralPath $backups[0].FullName) | Should -BeExactly 'known-good'
        Remove-Item -LiteralPath $backups[0].FullName -Force
    }
}

Describe 'chezmoi and shell integration for Pi, pia, and OMP' {
    BeforeAll {
        $script:PackageSource = Get-Content -Raw -LiteralPath $PackageTemplate
        $script:JustSource = Get-Content -Raw -LiteralPath $Justfile
        $script:ToolsSource = Get-Content -Raw -LiteralPath $ToolsProfile
    }

    It 'gates the immutable pi-agents external on installCodingAgents' {
        $enabled = Render-External -Enabled $true
        $disabled = Render-External -Enabled $false

        $enabled | Should -Match '\["\.local/share/pi-agents"\]'
        $enabled | Should -Match 'https://github\.com/daviddwlee84/pi-agents\.git'
        $enabled | Should -Not -Match '(?m)^\s*refreshPeriod\s*='
        $enabled | Should -Match 'args = \["--ff-only"\]'
        $disabled.Trim() | Should -BeNullOrEmpty
    }

    It 'keeps all new installs inside the coding-agent gate' {
        $script:PackageSource | Should -Match '(?s)\{\{ if \.installCodingAgents -\}\}.*Install-PiCodingAgent.*Install-OmpBinary.*gitleaks.*\{\{ end -\}\}'
        $script:PackageSource | Should -Match 'include "scripts/pi-package-core\.ps1"'
        $script:PackageSource | Should -Match 'include "scripts/omp-install-core\.ps1"'
    }

    It 'mirrors the exact prompt and Pi stack in bilingual docs and the shared skill' {
        $prompt = 'Install coding agents (Claude Code, OpenCode, Codex, Copilot CLI, Pi, pia, OMP, SpecStory)'
        foreach ($relative in 'docs/setup.md', 'docs/setup.zh-TW.md') {
            (Get-Content -Raw (Join-Path $RepoRoot $relative)) | Should -Match ([regex]::Escape($prompt))
        }
        foreach ($relative in 'docs/tools.md', 'docs/tools.zh-TW.md') {
            $doc = Get-Content -Raw (Join-Path $RepoRoot $relative)
            $doc | Should -Match '@earendil-works/pi-coding-agent'
            $doc | Should -Match 'omp\.sh/install\.ps1'
            $doc | Should -Match '~/.local/share/pi-agents'
            $doc | Should -Match 'pia completion powershell'
            $doc | Should -Match ([regex]::Escape('pia use <Tab>'))
        }
        $skill = Get-Content -Raw (Join-Path $RepoRoot '.chezmoitemplates/dotfiles-windows-skill.md')
        $skill | Should -Match 'Pi/pia/OMP included'
        $skill | Should -Match 'upgrade-npm-agents.*upgrade-omp.*upgrade-pia'
    }

    It 'loads pia PowerShell completion from a checkout-revision-keyed cache' {
        $script:ToolsSource | Should -Match '\[string\]\$RevisionStamp\s*=\s*'''''
        $script:ToolsSource | Should -Match '\$stamp\s*=\s*if \(\$RevisionStamp\)'
        $script:ToolsSource | Should -Match '(?s)\.git''.*Join-Path \$gitDir ''HEAD'''
        $registration = "Import-CachedInit -Name 'pia' -Exe `$piaExe -RevisionStamp `$piaRevisionStamp"
        $script:ToolsSource | Should -Match ([regex]::Escape($registration))
        $script:ToolsSource | Should -Match '& \$piaExe completion powershell'
    }

    It 'presence-gates PATH entries for pia, OMP, and Scoop Git Bash' {
        $enabled = Render-EnvironmentProfile -Enabled $true
        $disabled = Render-EnvironmentProfile -Enabled $false

        $enabled | Should -Match 'bin\\pia\.cmd'
        $enabled | Should -Match "Join-Path \`$env:LOCALAPPDATA 'omp'"
        $enabled | Should -Match "Join-Path \`$OmpRoot 'omp\.exe'"
        $enabled | Should -Match "Join-Path \`$ScoopRoot 'apps\\git\\current\\bin'"
        $enabled | Should -Match "Join-Path \`$ScoopGitBin 'bash\.exe'"
        $enabled | Should -Match '(?s)-not \$env:PIA_PI_BIN.*PIA_PI_BIN = \$PiOwnedLauncher'
        $enabled | Should -Match '(?s)-not \$env:PIA_OMP_BIN.*PIA_OMP_BIN = \$OmpOwnedBinary'
        $enabled | Should -Match 'function global:pi'
        $enabled | Should -Match 'Get-Command pi -CommandType Alias, Function'
        $disabled | Should -Not -Match '(?m)^\$(?:PiaRoot|OmpRoot|ScoopGitBin)\s*='
        $disabled | Should -Not -Match 'PIA_(?:PI|OMP)_BIN'
        $disabled | Should -Not -Match 'function global:pi'
        $disabled | Should -Not -Match 'Join-Path \$(?:PiaRoot|OmpRoot|ScoopGitBin)'
        $disabled | Should -Match "Join-Path \`$HOME '\.local/bin'"
        $disabled | Should -Match "Programs\\Herdr\\bin"
    }

    It 'persists owned pia and harness resolution for native cmd sessions' {
        $enabled = Render-EnvironmentScript -Enabled $true
        $disabled = Render-EnvironmentScript -Enabled $false

        $enabled | Should -Match "\.config\\powershell\\bin"
        $enabled | Should -Match 'piCmdLauncher.*pi\.cmd'
        $enabled | Should -Match 'Sync-DefaultUserEnvironmentVariable -Name PIA_PI_BIN.*PIA_DOTFILES_PI_BIN_MANAGED'
        $enabled | Should -Match 'Sync-DefaultUserEnvironmentVariable -Name PIA_OMP_BIN.*PIA_DOTFILES_OMP_BIN_MANAGED'
        $enabled | Should -Match 'preserving existing \$Name override'
        $enabled | Should -Match "\.local\\share\\pi-agents\\bin"
        $enabled | Should -Match 'piaLauncher.*pia\.cmd'
        $enabled | Should -Match 'scoopGitBash.*bash\.exe'
        $enabled | Should -Match '(?s)foreach \(\$entry in \$ownedPathEntries\).*foreach \(\$entry in @\(\$raw -split.*Test-SameEnvironmentPath'
        $enabled | Should -Match 'DoNotExpandEnvironmentNames'
        $enabled | Should -Match "GetValueKind\('Path'\)"
        $enabled | Should -Match ([regex]::Escape("`$key.SetValue('Path', `$updatedUserPath, `$userPathKind)"))
        $enabled | Should -Match 'WM_SETTINGCHANGE'
        $enabled | Should -Match '(?s)SetValue\(''Path''.*Send-EnvironmentChangeNotification'
        $enabled | Should -Not -Match "SetEnvironmentVariable\('Path', .*'User'\)"
        $disabled | Should -Match '(?s)Sync-DefaultUserEnvironmentVariable -Name PIA_PI_BIN.*?-Enabled \$false'
        $disabled | Should -Match '(?s)Sync-DefaultUserEnvironmentVariable -Name PIA_OMP_BIN.*?-Enabled \$false'
        $disabled | Should -Not -Match '(?m)^Add-OwnedPathEntries$'
        $disabled | Should -Match 'does not delete PATH'

        $launcher = Get-Content -Raw -LiteralPath $ManagedPiLauncher
        $launcher | Should -Match '@earendil-works\\pi-coding-agent'
        $launcher | Should -Match 'package\.json has no bin\.pi entry'
        $launcher | Should -Match 'bin\.pi escapes the managed package directory'
        $launcher | Should -Not -Match 'CmdletBinding|ValueFromRemainingArguments'
        $launcher | Should -Not -Match 'pi\.ps1'
        $cmdLauncher = Get-Content -Raw -LiteralPath $ManagedPiCmdLauncher
        $cmdLauncher | Should -Match 'pia-pi\.ps1.*%\*'
        $cmdLauncher | Should -Match 'Trusted interactive cmd\.exe shim'
    }

    It 'forwards Pi short flags, option values, and leading-dash arguments exactly' {
        $savedScoop = $env:SCOOP
        $savedCapture = $env:PI_WRAPPER_CAPTURE
        try {
            $env:SCOOP = Join-Path $TestDrive 'WrapperScoop'
            $env:PI_WRAPPER_CAPTURE = Join-Path $TestDrive 'pi-wrapper-argv.json'
            $node = Join-Path $env:SCOOP 'apps\nodejs-lts\current\node.exe'
            $packageRoot = Join-Path $env:SCOOP `
                'persist\nodejs-lts\bin\node_modules\@earendil-works\pi-coding-agent'
            $entrypoint = Join-Path $packageRoot 'dist/cli.js'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $node) | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entrypoint) | Out-Null
            $ambientNode = (Get-Command node -CommandType Application | Select-Object -First 1).Source
            if ($IsWindows) {
                Copy-Item -LiteralPath $ambientNode -Destination $node
            } else {
                $escapedNode = $ambientNode.Replace('"', '\"')
                "#!/bin/sh`nexec `"$escapedNode`" `"`$@`"" | Set-Content -LiteralPath $node -NoNewline
                & chmod +x $node
            }
            '{"bin":{"pi":"dist/cli.js"}}' | Set-Content -LiteralPath (Join-Path $packageRoot 'package.json') -NoNewline
            'require("fs").writeFileSync(process.env.PI_WRAPPER_CAPTURE, JSON.stringify(process.argv.slice(2)))' |
                Set-Content -LiteralPath $entrypoint -NoNewline

            $cases = @(
                ,@('-v')
                ,@('--session-dir', 'C:\sessions\owned')
                ,@('--', '--leading-dash')
                ,@('Update')
                ,@('update', '--models')
                ,@('update', '--extensions')
                ,@('update', '--extension', 'github:owner/extension')
            )
            foreach ($expected in $cases) {
                & pwsh -NoProfile -File $ManagedPiLauncher @expected
                $LASTEXITCODE | Should -Be 0
                $actual = @(Get-Content -Raw -LiteralPath $env:PI_WRAPPER_CAPTURE | ConvertFrom-Json)
                ($actual -join "`n") | Should -BeExactly ($expected -join "`n")
                if ($IsWindows) {
                    Remove-Item -LiteralPath $env:PI_WRAPPER_CAPTURE -Force
                    & $ManagedPiCmdLauncher @expected
                    $LASTEXITCODE | Should -Be 0
                    $actual = @(Get-Content -Raw -LiteralPath $env:PI_WRAPPER_CAPTURE | ConvertFrom-Json)
                    ($actual -join "`n") | Should -BeExactly ($expected -join "`n")
                }
            }

            foreach ($blocked in @(
                ,@('update')
                ,@('update', '')
                ,@('update', 'self')
                ,@('update', 'pi')
                ,@('update', '--self')
                ,@('update', '--all')
                ,@('update', '--self', '--extensions')
            )) {
                Remove-Item -LiteralPath $env:PI_WRAPPER_CAPTURE -Force -ErrorAction SilentlyContinue
                & pwsh -NoProfile -File $ManagedPiLauncher @blocked 2>$null
                $LASTEXITCODE | Should -Be 2
                $env:PI_WRAPPER_CAPTURE | Should -Not -Exist
            }
        } finally {
            if ($null -eq $savedScoop) { Remove-Item Env:SCOOP -ErrorAction SilentlyContinue }
            else { $env:SCOOP = $savedScoop }
            if ($null -eq $savedCapture) { Remove-Item Env:PI_WRAPPER_CAPTURE -ErrorAction SilentlyContinue }
            else { $env:PI_WRAPPER_CAPTURE = $savedCapture }
        }
    }

    It 'exposes separate and aggregate explicit upgrades outside default upgrade' {
        $script:JustSource | Should -Match 'upgrade-npm-agents:'
        $script:JustSource | Should -Match 'upgrade-omp:\s*\r?\n\s*pwsh -NoProfile -File ./scripts/upgrade-omp\.ps1'
        $script:JustSource | Should -Match 'upgrade-pia:\s*\r?\n\s*chezmoi apply --refresh-externals'
        $script:JustSource | Should -Match 'upgrade-agents: upgrade-npm-agents upgrade-omp upgrade-pia'
        $script:JustSource | Should -Match 'upgrade: upgrade-scoop upgrade-winget'
        $script:JustSource | Should -Not -Match 'upgrade:.*upgrade-agents'
        (Get-Content -Raw (Join-Path $RepoRoot 'scripts' 'upgrade-omp.ps1')) |
            Should -Match 'OMP is not installed at its managed path; skipping upgrade'
    }
}
