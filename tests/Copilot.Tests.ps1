# Pester tests for the Copilot module. Runtime behaviour (proxy start, live
# HTTP) can't be exercised without Windows + copilot-api, so these cover the
# pure logic: package-flavor detection, model resolution/normalisation, served-
# model parsing, and the effective-model precedence — with HTTP mocked.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'modules' 'Copilot' 'Copilot.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Copilot module' {

    Context 'profile module loading' {
        It 'forces a fresh module import so reload picks up deployed fixes' {
            $loader = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'profile.d' '40_copilot.ps1')
            $loader | Should -Match 'Import-Module\s+Copilot\s+-Force\b'
        }
    }

    Context 'package flavor detection' {
        It 'keeps the maintained fork default pinned exactly' {
            InModuleScope Copilot {
                $env:COPILOT_API_PKG = $null
                Get-CopilotPkg | Should -BeExactly '@jeffreycao/copilot-api@2.1.0'
            }
        }
        It 'treats the bare original package as "original"' {
            InModuleScope Copilot { $env:COPILOT_API_PKG = 'copilot-api@0.7.0'; Get-CopilotPkgFlavor | Should -Be 'original' }
        }
        It 'treats the scoped fork as "fork"' {
            InModuleScope Copilot { $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@2.1.0'; Get-CopilotPkgFlavor | Should -Be 'fork' }
        }
        AfterEach { $env:COPILOT_API_PKG = $null }
    }

    Context 'default model resolution' {
        It 'falls back to the built-in default' {
            InModuleScope Copilot {
                $env:COPILOT_CLAUDE_MODEL = $null
                Mock Get-CopilotModelState { Join-Path ([System.IO.Path]::GetTempPath()) 'does-not-exist-copilot-model' }
                Get-CopilotDefaultModel | Should -Be 'gpt-5.6-sol[1m]'
            }
        }
        It 'honors $COPILOT_CLAUDE_MODEL' {
            InModuleScope Copilot {
                $env:COPILOT_CLAUDE_MODEL = 'claude-sonnet-5'
                Get-CopilotDefaultModel | Should -Be 'claude-sonnet-5'
                $env:COPILOT_CLAUDE_MODEL = $null
            }
        }
    }

    Context 'package name parsing (the scoped-spec trap)' {
        # A naive "split on @" empties a scoped spec that carries no version,
        # which would degrade the stale-installer reap pattern to `bun add.*`
        # and match every bun install on the box.
        It 'keeps the @scope while stripping the version' {
            InModuleScope Copilot {
                $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@2.1.0'
                Get-CopilotPkgName | Should -Be '@jeffreycao/copilot-api'
            }
        }
        It 'returns a scoped spec with no version unchanged' {
            InModuleScope Copilot {
                $env:COPILOT_API_PKG = '@jeffreycao/copilot-api'
                Get-CopilotPkgName | Should -Be '@jeffreycao/copilot-api'
            }
        }
        It 'strips the version from an unscoped spec' {
            InModuleScope Copilot {
                $env:COPILOT_API_PKG = 'copilot-api@0.7.0'
                Get-CopilotPkgName | Should -Be 'copilot-api'
            }
        }
        It 'rejects npm aliases and local path selectors' {
            InModuleScope Copilot {
                $env:COPILOT_API_PKG = 'copilot-local@npm:@jeffreycao/copilot-api@2.1.0'
                Get-CopilotPkgSpecInfo | Should -BeNullOrEmpty
                Get-CopilotPkgName | Should -BeNullOrEmpty
                $env:COPILOT_API_PKG = '..\..\victim'
                Get-CopilotPkgSpecInfo | Should -BeNullOrEmpty
                Get-CopilotPkgName | Should -BeNullOrEmpty
            }
        }
        AfterEach { $env:COPILOT_API_PKG = $null }
    }

    Context 'installed package metadata and verified stamps' {
        BeforeEach {
            $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@2.1.0'
            $env:XDG_DATA_HOME = Join-Path $TestDrive "xdg-$([guid]::NewGuid())"
            $script:pkgPrefix = Join-Path $env:XDG_DATA_HOME 'copilot-api/pkg'
            $script:pkgDir = Join-Path $script:pkgPrefix 'node_modules/@jeffreycao/copilot-api'
            $script:binDir = Join-Path $script:pkgPrefix 'node_modules/.bin'
        }
        AfterEach {
            if ($env:XDG_DATA_HOME -and [System.IO.Directory]::Exists($env:XDG_DATA_HOME)) {
                [System.IO.Directory]::Delete($env:XDG_DATA_HOME, $true)
            }
            $env:COPILOT_API_PKG = $null
            $env:XDG_DATA_HOME = $null
        }

        function script:Set-TestCopilotPackage {
            param([string] $Name = '@jeffreycao/copilot-api', [string] $Version = '2.1.0', [switch] $NoLaunch)
            New-Item -ItemType Directory -Force $script:pkgDir | Out-Null
            @{ name = $Name; version = $Version } | ConvertTo-Json -Compress |
                Set-Content -LiteralPath (Join-Path $script:pkgDir 'package.json')
            if (-not $NoLaunch) {
                New-Item -ItemType Directory -Force $script:binDir | Out-Null
                '@exit /b 0' | Set-Content -LiteralPath (Join-Path $script:binDir 'copilot-api.cmd')
            }
        }

        It 'parses only exact requested versions' {
            InModuleScope Copilot {
                Get-CopilotPkgExactVersion | Should -Be '2.1.0'
                $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@latest'
                Get-CopilotPkgExactVersion | Should -BeNullOrEmpty
                $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@^2.1.0'
                Get-CopilotPkgExactVersion | Should -BeNullOrEmpty
            }
        }

        It 'accepts matching metadata only with a runnable launch path' {
            Set-TestCopilotPackage
            InModuleScope Copilot {
                $metadata = Get-CopilotPkgMetadata
                $metadata.Name | Should -BeExactly '@jeffreycao/copilot-api'
                $metadata.Version | Should -BeExactly '2.1.0'
                Test-CopilotPkgInstalled -Metadata $metadata | Should -BeTrue
            }
        }

        It 'rejects matching metadata when no package binlink landed' {
            Set-TestCopilotPackage -NoLaunch
            InModuleScope Copilot {
                Get-CopilotPkgMetadata | Should -Not -BeNullOrEmpty
                Get-CopilotPkgLaunch | Should -BeNullOrEmpty
                Test-CopilotPkgInstalled | Should -BeFalse
            }
        }

        It 'runs hash-pinned CDN files directly with Bun when no binlink exists' {
            Set-TestCopilotPackage -NoLaunch
            New-Item -ItemType Directory -Force (Join-Path $script:pkgDir 'dist') | Out-Null
            'console.log("test")' | Set-Content -LiteralPath (Join-Path $script:pkgDir 'dist/main.js')
            InModuleScope Copilot {
                $launch = Get-CopilotPkgLaunch
                $launch.Exe | Should -BeExactly 'bun'
                $launch.Pre[0] | Should -BeLike '*dist*main.js'
                Test-CopilotPkgInstalled | Should -BeTrue
            }
        }

        It 'exposes the CDN manifest only for the reviewed default pin' {
            InModuleScope Copilot {
                $manifest = Get-CopilotPkgCdnManifest
                $manifest.BaseUrl | Should -Match '@jeffreycao/copilot-api@2\.1\.0'
                $manifest.Files['dist/main.js'] | Should -BeExactly 'oQOghbsofHbuu5LH+YOP6SMGcHbH6KuDXNvdiWMDVhY='
                $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@latest'
                Get-CopilotPkgCdnManifest | Should -BeNullOrEmpty
            }
        }

        It 'installs a mocked CDN package only after every file hash verifies' {
            InModuleScope Copilot {
                $packageJson = '{"name":"@jeffreycao/copilot-api","version":"2.1.0","dependencies":{}}'
                $main = 'console.log("test")'
                function HashOf([string] $Text) {
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) } finally { $sha.Dispose() }
                }
                Mock Get-CopilotPkgCdnManifest {
                    [pscustomobject]@{
                        BaseUrl = 'https://example.invalid/'
                        Files = [ordered]@{ 'package.json' = HashOf $packageJson; 'dist/main.js' = HashOf $main }
                    }
                }
                Mock Invoke-WebRequest {
                    param($Uri, $OutFile)
                    $text = if ($Uri -like '*package.json') { $packageJson } else { $main }
                    [IO.File]::WriteAllText($OutFile, $text, [Text.UTF8Encoding]::new($false))
                }
                Mock Install-CopilotPkgDependencies { $true }
                Install-CopilotPkgFromCdn | Should -BeTrue
                (Get-CopilotPkgMetadata).Version | Should -BeExactly '2.1.0'
                Should -Invoke Invoke-WebRequest -Times 2
            }
        }

        It 'rejects stale metadata even when the binlink remains' {
            Set-TestCopilotPackage -Version '1.13.14'
            InModuleScope Copilot { Test-CopilotPkgInstalled | Should -BeFalse }
        }

        It 'rejects a stale binlink without readable package metadata' {
            New-Item -ItemType Directory -Force $script:binDir | Out-Null
            '@exit /b 0' | Set-Content -LiteralPath (Join-Path $script:binDir 'copilot-api.cmd')
            InModuleScope Copilot {
                Get-CopilotPkgMetadata | Should -BeNullOrEmpty
                Test-CopilotPkgInstalled | Should -BeFalse
            }
        }

        It 'reads corrupt package metadata safely' {
            New-Item -ItemType Directory -Force $script:pkgDir | Out-Null
            '{not-json' | Set-Content -LiteralPath (Join-Path $script:pkgDir 'package.json')
            InModuleScope Copilot {
                Get-CopilotPkgMetadata | Should -BeNullOrEmpty
                Test-CopilotPkgInstalled | Should -BeFalse
            }
        }

        It 'requires selector, verified stamp, metadata and launch to agree' {
            Set-TestCopilotPackage
            New-Item -ItemType Directory -Force $script:pkgPrefix | Out-Null
            @{ requestedSpec = '@jeffreycao/copilot-api@2.1.0'; name = '@jeffreycao/copilot-api'; version = '2.1.0' } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $script:pkgPrefix '.installed-spec')
            InModuleScope Copilot { Test-CopilotPkgReady | Should -BeTrue }

            @{ requestedSpec = '@jeffreycao/copilot-api@2.1.0'; name = '@jeffreycao/copilot-api'; version = '1.13.14' } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $script:pkgPrefix '.installed-spec')
            InModuleScope Copilot { Test-CopilotPkgReady | Should -BeFalse }
        }

        It 'reads corrupt verified stamps safely' {
            Set-TestCopilotPackage
            '{bad-stamp' | Set-Content -LiteralPath (Join-Path $script:pkgPrefix '.installed-spec')
            InModuleScope Copilot {
                Get-CopilotPkgStampMetadata | Should -BeNullOrEmpty
                Test-CopilotPkgReady | Should -BeFalse
            }
        }

        It 'migrates a matching exact legacy stamp without network access' {
            Set-TestCopilotPackage
            '@jeffreycao/copilot-api@2.1.0' | Set-Content -LiteralPath (Join-Path $script:pkgPrefix '.installed-spec')
            InModuleScope Copilot {
                Mock Invoke-CopilotPkgInstallTry { throw 'network should not be used' }
                Install-CopilotPkg | Should -BeTrue
                Should -Invoke Invoke-CopilotPkgInstallTry -Times 0
                $stamp = Get-CopilotPkgStampMetadata
                $stamp.RequestedSpec | Should -BeExactly '@jeffreycao/copilot-api@2.1.0'
                $stamp.Name | Should -BeExactly '@jeffreycao/copilot-api'
                $stamp.Version | Should -BeExactly '2.1.0'
            }
        }

        It 'does not migrate stale 1.13.14 metadata for desired 2.1.0' {
            Set-TestCopilotPackage -Version '1.13.14'
            '@jeffreycao/copilot-api@2.1.0' | Set-Content -LiteralPath (Join-Path $script:pkgPrefix '.installed-spec')
            InModuleScope Copilot {
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'bun' }
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    Install-CopilotPkg 2>$null | Should -BeFalse
                } finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                Get-CopilotPkgStampMetadata | Should -BeNullOrEmpty
                Get-CopilotPkgLegacyStamp | Should -BeExactly '@jeffreycao/copilot-api@2.1.0'
            }
        }

        It 'does not migrate legacy stamps for non-exact selectors' {
            $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@latest'
            Set-TestCopilotPackage
            '@jeffreycao/copilot-api@latest' | Set-Content -LiteralPath (Join-Path $script:pkgPrefix '.installed-spec')
            InModuleScope Copilot {
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'bun' }
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    Install-CopilotPkg 2>$null | Should -BeFalse
                } finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                Get-CopilotPkgStampMetadata | Should -BeNullOrEmpty
            }
        }

        It 'rejects an unsupported selector before any filesystem cleanup or installer launch' {
            $victim = Join-Path $env:XDG_DATA_HOME 'victim'
            New-Item -ItemType Directory -Force $victim | Out-Null
            'keep' | Set-Content -LiteralPath (Join-Path $victim 'marker.txt')
            $env:COPILOT_API_PKG = '..\..\victim'
            InModuleScope Copilot {
                Mock Start-Process { throw 'installer must not start' }
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    Install-CopilotPkg 2>$null | Should -BeFalse
                } finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                Should -Invoke Start-Process -Times 0
            }
            Test-Path -LiteralPath (Join-Path $victim 'marker.txt') | Should -BeTrue
        }

        It 'stops before installer launch when the previous target cannot be cleared' {
            InModuleScope Copilot {
                Mock Clear-CopilotPkgInstallTarget { $false }
                Mock Start-Process { throw 'installer must not start' }
                Invoke-CopilotPkgInstallTry -Dir (Get-CopilotPkgPrefix) -BudgetSeconds 1 | Should -BeFalse
                Should -Invoke Start-Process -Times 0
            }
        }

        It 'fails the install postcondition after ETARGET leaves only the old tree' {
            Set-TestCopilotPackage -Version '1.13.14'
            InModuleScope Copilot {
                $process = [pscustomobject]@{ Id = 4242 }
                $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) $null = $Milliseconds; $true }
                Mock Get-Command { [pscustomobject]@{ Source = 'npm.cmd' } } -ParameterFilter { $Name -eq 'npm.cmd' }
                Mock Start-Process { $process }
                Invoke-CopilotPkgInstallTry -Dir (Get-CopilotPkgPrefix) -BudgetSeconds 1 | Should -BeFalse
                Test-CopilotPkgInstalled | Should -BeFalse
                Test-Path -LiteralPath (Get-CopilotPkgStamp) | Should -BeFalse
            }
        }
    }

    Context 'shared OpenAI model ordering' {
        It 'keeps every named tier in one order for Claude and Codex' {
            InModuleScope Copilot {
                $known = @(
                    'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.5', 'gpt-5.4',
                    'gpt-5.3-codex', 'gpt-5.6-luna', 'gpt-5.4-mini', 'gpt-5-mini'
                )
                foreach ($i in 0..($known.Count - 2)) {
                    $pair = @($known[$i + 1], $known[$i])
                    Select-CopilotBestOpenAIModel -Model $pair | Should -BeExactly $known[$i]
                    Select-CopilotBestModel -Model $pair | Should -BeExactly $known[$i]
                    Select-CopilotBestCodexModel -Model $pair | Should -BeExactly $known[$i]
                }
            }
        }

        It 'uses the same future-model vectors for Claude and Codex' {
            InModuleScope Copilot {
                $vectors = @(
                    @{ Model = @('gpt-5.7', 'gpt-5.6-luna'); Expected = 'gpt-5.6-luna' },
                    @{ Model = @('gpt-5.7', 'gpt-5.4-mini'); Expected = 'gpt-5.4-mini' },
                    @{ Model = @('gpt-5.7-mini', 'gpt-5.7'); Expected = 'gpt-5.7' },
                    @{ Model = @('gpt-5-codex', 'gpt-5-mini'); Expected = 'gpt-5-mini' },
                    @{ Model = @('gpt-5.6-terra', 'gpt-5.6-sol[1m]'); Expected = 'gpt-5.6-sol' }
                )
                foreach ($vector in $vectors) {
                    Select-CopilotBestOpenAIModel -Model $vector.Model | Should -BeExactly $vector.Expected
                    Select-CopilotBestModel -Model $vector.Model | Should -BeExactly $vector.Expected
                    Select-CopilotBestCodexModel -Model $vector.Model | Should -BeExactly $vector.Expected
                }
            }
        }
    }

    Context 'best-model picker (--auto)' {
        It 'prefers Fable, then the strongest Claude family, and returns a raw id' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('claude-opus-5[1m]', 'gpt-5.6-sol', 'claude-fable-5') |
                    Should -Be 'claude-fable-5'
            }
        }
        It 'returns a raw id and leaves context hints to catalog metadata' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('claude-haiku-4-5') | Should -Be 'claude-haiku-4-5'
            }
        }
        It 'puts gpt-5.6-sol ahead of every other OpenAI tier' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol') |
                    Should -Be 'gpt-5.6-sol'
            }
        }
        It 'keeps named older flagship and coding models ahead of lightweight models' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gpt-5-mini', 'gpt-5.3-codex') | Should -Be 'gpt-5.3-codex'
            }
        }
        It 'prefers a non-flash Gemini as the last family' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gemini-2.5-flash', 'gemini-2.5-pro') | Should -Be 'gemini-2.5-pro'
            }
        }
        It 'returns nothing for an empty catalog' {
            InModuleScope Copilot { Select-CopilotBestModel -Model @() | Should -BeNullOrEmpty }
        }
    }

    Context 'Codex model picker' {
        It 'puts OpenAI Sol ahead of Claude and Gemini' {
            InModuleScope Copilot {
                Select-CopilotBestCodexModel -Model @('claude-fable-5', 'gemini-3.1-pro-preview', 'gpt-5.6-terra', 'gpt-5.6-sol') |
                    Should -Be 'gpt-5.6-sol'
            }
        }
        It 'uses Claude before Gemini when OpenAI is unavailable' {
            InModuleScope Copilot {
                Select-CopilotBestCodexModel -Model @('gemini-3.1-pro-preview', 'claude-sonnet-5', 'claude-opus-5') |
                    Should -Be 'claude-opus-5'
            }
        }
        It 'prefers non-flash Gemini as the final named family' {
            InModuleScope Copilot {
                Select-CopilotBestCodexModel -Model @('gemini-3.6-flash', 'gemini-3.1-pro-preview') |
                    Should -Be 'gemini-3.1-pro-preview'
            }
        }
        It 'detects every supported explicit model spelling without false positives' {
            InModuleScope Copilot {
                Test-CopilotExplicitCodexModel -Argv @('exec', '-m', 'claude-opus-5') | Should -BeTrue
                Test-CopilotExplicitCodexModel -Argv @('exec', '--model=gpt-5.6-sol') | Should -BeTrue
                Test-CopilotExplicitCodexModel -Argv @('exec', '-m=gpt-5.6-terra') | Should -BeTrue
                Test-CopilotExplicitCodexModel -Argv @('exec', '--model', 'gpt-5.5') | Should -BeTrue
                Test-CopilotExplicitCodexModel -Argv @('exec', '--config', 'model="gpt-5.4"') | Should -BeFalse
            }
        }
        It 'preserves the project SpecStory codex command' {
            $project = Join-Path $TestDrive 'project'
            New-Item -ItemType Directory -Force (Join-Path $project '.specstory/cli') | Out-Null
            'codex_cmd = "codex --ask-for-approval never"' |
                Set-Content -LiteralPath (Join-Path $project '.specstory/cli/config.toml')
            InModuleScope Copilot -Parameters @{ Project = $project } {
                param($Project)
                Push-Location $Project
                try { Get-SpecstoryCodexCmd | Should -Be 'codex --ask-for-approval never' }
                finally { Pop-Location }
            }
        }
    }

    Context 'Codex Copilot provider and SpecStory startup' {
        It 'distinguishes zero arguments from one explicit empty argument' {
            InModuleScope Copilot {
                Mock codex-copilot {
                    $script:delegatedCodexWasNull = $null -eq $Argv
                    $script:delegatedCodexArgs = @($Argv)
                }

                codex-copilot-once
                $script:delegatedCodexWasNull | Should -BeTrue

                codex-copilot-once ''
                $script:delegatedCodexWasNull | Should -BeFalse
                $script:delegatedCodexArgs | Should -HaveCount 1
                $script:delegatedCodexArgs[0] | Should -BeExactly ''
                Should -Invoke codex-copilot -Times 2 -Exactly
            }
        }

        It 'uses provider authentication without requiring Codex account credentials' {
            InModuleScope Copilot {
                $providerArgs = @(Get-CodexCopilotProviderArgs -Base 'http://127.0.0.1:4142')
                $providerArgs | Should -Contain 'model_providers.copilot_api.env_key="GITHUB_COPILOT_API_KEY"'
                $providerArgs | Should -Contain 'model_providers.copilot_api.requires_openai_auth=false'
                $providerArgs | Should -Not -Contain 'model_providers.copilot_api.requires_openai_auth=true'
            }
        }

        It 'passes the provider auth override to the direct Codex child' {
            InModuleScope Copilot {
                function script:codex { $script:capturedCodexLaunch = @($args) }
                try {
                    Mock Test-CopilotAlive { $true }
                    Mock Start-CopilotShim { $true }
                    Mock Get-CopilotModelCatalog { [pscustomobject]@{ data = @() } }
                    Mock Get-CopilotShimBase { 'http://127.0.0.1:4142' }

                    codex-copilot --no-specstory --model custom-model

                    $script:capturedCodexLaunch | Should -Contain 'model_providers.copilot_api.requires_openai_auth=false'
                    $script:capturedCodexLaunch | Should -Not -Contain 'model_providers.copilot_api.requires_openai_auth=true'
                } finally {
                    Remove-Item Function:\codex -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'creates a missing SpecStory sessions root under CODEX_HOME' {
            $codexHome = Join-Path $TestDrive 'missing-codex-home'
            InModuleScope Copilot -Parameters @{ CodexHome = $codexHome } {
                param($CodexHome)
                $savedCodexHome = $env:CODEX_HOME
                try {
                    $env:CODEX_HOME = $CodexHome
                    $sessionsRoot = Join-Path $CodexHome 'sessions'
                    Test-Path -LiteralPath $sessionsRoot | Should -BeFalse
                    Initialize-SpecstoryCodexSessionsRoot | Should -BeTrue
                    Get-CodexSessionsRoot | Should -BeExactly $sessionsRoot
                    Test-Path -LiteralPath $sessionsRoot -PathType Container | Should -BeTrue
                } finally {
                    if ($null -eq $savedCodexHome) { Remove-Item env:CODEX_HOME -ErrorAction SilentlyContinue }
                    else { $env:CODEX_HOME = $savedCodexHome }
                }
            }
        }

        It 'reports an invalid sessions root' {
            $blockedCodexHome = Join-Path $TestDrive 'blocked-codex-home'
            'not a directory' | Set-Content -LiteralPath $blockedCodexHome
            InModuleScope Copilot -Parameters @{ CodexHome = $blockedCodexHome } {
                param($CodexHome)
                $savedCodexHome = $env:CODEX_HOME
                try {
                    $env:CODEX_HOME = $CodexHome
                    $errors = @()
                    Initialize-SpecstoryCodexSessionsRoot -ErrorAction SilentlyContinue -ErrorVariable +errors |
                        Should -BeFalse
                    ($errors.Exception.Message -join "`n") |
                        Should -Match 'could not initialize SpecStory sessions root'
                } finally {
                    if ($null -eq $savedCodexHome) { Remove-Item env:CODEX_HOME -ErrorAction SilentlyContinue }
                    else { $env:CODEX_HOME = $savedCodexHome }
                }
            }
        }

        It 'stops before either child process when SpecStory initialization fails' {
            InModuleScope Copilot {
                $savedKey = $env:GITHUB_COPILOT_API_KEY
                function script:specstory { $script:specstoryCalled = $true }
                function script:codex { $script:codexCalled = $true }
                try {
                    $script:specstoryCalled = $false
                    $script:codexCalled = $false
                    Mock Test-CopilotAlive { $true }
                    Mock Start-CopilotShim { $true }
                    Mock Get-CopilotModelCatalog { [pscustomobject]@{ data = @() } }
                    Mock Get-CopilotShimBase { 'http://127.0.0.1:4142' }
                    Mock Get-Command { [pscustomobject]@{ Name = 'specstory' } } -ParameterFilter { $Name -eq 'specstory' }
                    Mock Initialize-SpecstoryCodexSessionsRoot { $false }

                    codex-copilot --model custom-model

                    Should -Invoke Initialize-SpecstoryCodexSessionsRoot -Times 1 -Exactly
                    $script:specstoryCalled | Should -BeFalse
                    $script:codexCalled | Should -BeFalse
                    $env:GITHUB_COPILOT_API_KEY | Should -Be $savedKey
                } finally {
                    Remove-Item Function:\specstory, Function:\codex -Force -ErrorAction SilentlyContinue
                    if ($null -eq $savedKey) { Remove-Item env:GITHUB_COPILOT_API_KEY -ErrorAction SilentlyContinue }
                    else { $env:GITHUB_COPILOT_API_KEY = $savedKey }
                }
            }
        }

        It 'restores the API key without masking a direct Codex failure' {
            InModuleScope Copilot {
                $savedKey = $env:GITHUB_COPILOT_API_KEY
                function script:codex { & cmd.exe /d /c 'exit 8' }
                try {
                    $env:GITHUB_COPILOT_API_KEY = 'original'
                    Mock Test-CopilotAlive { $true }
                    Mock Start-CopilotShim { $true }
                    Mock Get-CopilotModelCatalog { [pscustomobject]@{ data = @() } }
                    Mock Get-CopilotShimBase { 'http://127.0.0.1:4142' }
                    Mock Get-Command { $null } -ParameterFilter { $Name -eq 'specstory' }

                    $errors = @()
                    codex-copilot -ErrorAction SilentlyContinue -ErrorVariable +errors --model custom-model
                    $succeeded = $?
                    $exitCode = $LASTEXITCODE

                    $succeeded | Should -BeFalse
                    $exitCode | Should -Be 8
                    $env:GITHUB_COPILOT_API_KEY | Should -BeExactly 'original'
                    ($errors.Exception.Message -join "`n") | Should -Match 'exited with code 8'
                } finally {
                    Remove-Item Function:\codex -Force -ErrorAction SilentlyContinue
                    if ($null -eq $savedKey) { Remove-Item env:GITHUB_COPILOT_API_KEY -ErrorAction SilentlyContinue }
                    else { $env:GITHUB_COPILOT_API_KEY = $savedKey }
                }
            }
        }
    }

    Context 'catalog eligibility policy' {
        It 'excludes every veto while retaining entries with absent metadata' {
            InModuleScope Copilot {
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'claude-fable-5'; policy = [pscustomobject]@{ state = 'disabled' } },
                    [pscustomobject]@{ id = 'claude-opus-5'; model_picker_enabled = $false },
                    [pscustomobject]@{ id = 'gpt-5.6-sol'; capabilities = [pscustomobject]@{ type = 'embeddings' } },
                    [pscustomobject]@{ id = 'claude-sonnet-5' },
                    [pscustomobject]@{ id = 'gpt-5.5'; policy = [pscustomobject]@{ state = 'enabled' } },
                    [pscustomobject]@{ id = 'gpt-5.5' },
                    [pscustomobject]@{ id = $null },
                    $null
                ) }
                @(Get-CopilotSelectableModelIds $catalog) |
                    Should -BeExactly @('claude-sonnet-5', 'gpt-5.5')
            }
        }

        It 'returns no automatic candidate for an embedding-only catalog' {
            InModuleScope Copilot {
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'text-embedding-3-small'; capabilities = [pscustomobject]@{ type = 'embeddings' } }
                ) }
                @(Get-CopilotSelectableModelIds $catalog).Count | Should -Be 0
            }
        }
    }

    Context 'catalog metadata and Claude Code role profiles' {
        It 'adds [1m] only when the live model metadata advertises a 1M context window' {
            InModuleScope Copilot {
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{
                        id = 'gpt-5.6-sol'
                        capabilities = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 1000000 } }
                    },
                    [pscustomobject]@{
                        id = 'gpt-5.6-terra'
                        capabilities = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 400000 } }
                    }
                ) }
                ConvertTo-CopilotClaudeModel -Model 'gpt-5.6-sol' -Catalog $catalog | Should -Be 'gpt-5.6-sol[1m]'
                ConvertTo-CopilotClaudeModel -Model 'gpt-5.6-terra[1m]' -Catalog $catalog | Should -Be 'gpt-5.6-terra'
            }
        }

        It 'maps an OpenAI main model to Sol/Sol/Terra/Luna role tiers' {
            InModuleScope Copilot {
                $limits = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 1000000 } }
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'gpt-5.6-sol'; capabilities = $limits },
                    [pscustomobject]@{ id = 'gpt-5.6-terra'; capabilities = $limits },
                    [pscustomobject]@{ id = 'gpt-5.6-luna'; capabilities = $limits }
                ) }
                $modelProfile = Get-CopilotModelProfile -Model 'gpt-5.6-sol' -Catalog $catalog
                $modelProfile.main | Should -Be 'gpt-5.6-sol[1m]'
                $modelProfile.fable | Should -Be 'gpt-5.6-sol[1m]'
                $modelProfile.opus | Should -Be 'gpt-5.6-sol[1m]'
                $modelProfile.sonnet | Should -Be 'gpt-5.6-terra[1m]'
                $modelProfile.haiku | Should -Be 'gpt-5.6-luna[1m]'
            }
        }

        It 'does not derive role aliases from vetoed catalog entries' {
            InModuleScope Copilot {
                $oneMillion = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 1000000 } }
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'gpt-5.6-sol'; capabilities = $oneMillion },
                    [pscustomobject]@{ id = 'gpt-5.6-terra'; policy = [pscustomobject]@{ state = 'disabled' }; capabilities = $oneMillion },
                    [pscustomobject]@{ id = 'gpt-5.6-luna'; model_picker_enabled = $false; capabilities = $oneMillion },
                    [pscustomobject]@{ id = 'gpt-5.4-mini'; capabilities = [pscustomobject]@{ type = 'embeddings'; limits = $oneMillion.limits } }
                ) }
                $modelProfile = Get-CopilotModelProfile -Model 'gpt-5.6-sol' -Catalog $catalog
                @($modelProfile.Values | Select-Object -Unique) | Should -Be @('gpt-5.6-sol[1m]')
            }
        }

        It 'falls every missing OpenAI role back to the selected main model' {
            InModuleScope Copilot {
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{
                        id = 'gpt-5.5'
                        capabilities = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 400000 } }
                    }
                ) }
                $modelProfile = Get-CopilotModelProfile -Model 'gpt-5.5' -Catalog $catalog
                @($modelProfile.Values | Select-Object -Unique) | Should -Be @('gpt-5.5')
            }
        }

        It 'uses the strongest served native Claude model in each role family' {
            InModuleScope Copilot {
                $catalog = [pscustomobject]@{ data = @(
                    'claude-fable-5', 'claude-opus-5', 'claude-sonnet-5', 'claude-haiku-4-5' |
                        ForEach-Object {
                            [pscustomobject]@{
                                id = $_
                                capabilities = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 1000000 } }
                            }
                        }
                ) }
                $modelProfile = Get-CopilotModelProfile -Model 'claude-opus-5' -Catalog $catalog
                $modelProfile.fable | Should -Be 'claude-fable-5[1m]'
                $modelProfile.opus | Should -Be 'claude-opus-5[1m]'
                $modelProfile.sonnet | Should -Be 'claude-sonnet-5[1m]'
                $modelProfile.haiku | Should -Be 'claude-haiku-4-5[1m]'
            }
        }

        It 'injects the complete role profile including Fable and small-fast' {
            InModuleScope Copilot {
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'gpt-5.6-sol' },
                    [pscustomobject]@{ id = 'gpt-5.6-terra' },
                    [pscustomobject]@{ id = 'gpt-5.6-luna' }
                ) }
                $envBlock = Get-CopilotEnvBlock -Pinned -Model 'gpt-5.6-sol' -Catalog $catalog
                $envBlock.ANTHROPIC_DEFAULT_FABLE_MODEL | Should -Be 'gpt-5.6-sol'
                $envBlock.ANTHROPIC_DEFAULT_OPUS_MODEL | Should -Be 'gpt-5.6-sol'
                $envBlock.ANTHROPIC_DEFAULT_SONNET_MODEL | Should -Be 'gpt-5.6-terra'
                $envBlock.ANTHROPIC_DEFAULT_HAIKU_MODEL | Should -Be 'gpt-5.6-luna'
                $envBlock.ANTHROPIC_SMALL_FAST_MODEL | Should -Be 'gpt-5.6-luna'
            }
        }
    }

    Context 'copilot-model writes' {
        BeforeEach {
            $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-model-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null
            Push-Location $script:tmp
        }
        AfterEach { Pop-Location; Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

        It 'refuses --auto when no live catalog is available' {
            InModuleScope Copilot {
                $script:state = Join-Path (Get-Location) 'state/model'
                Mock Get-CopilotModelState { $script:state }
                Mock Get-CopilotModelCatalog { $null }
                $errors = @()
                copilot-model --auto -ErrorAction SilentlyContinue -ErrorVariable +errors
                $errors.Exception.Message | Should -Match 'needs a reachable proxy'
                Test-Path $script:state | Should -BeFalse
            }
        }

        It 'skips vetoed catalog entries during --auto selection' {
            InModuleScope Copilot {
                $script:state = Join-Path (Get-Location) 'state/model'
                Mock Get-CopilotModelState { $script:state }
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'claude-fable-5'; policy = [pscustomobject]@{ state = 'disabled' } },
                    [pscustomobject]@{ id = 'gpt-5.6-sol'; model_picker_enabled = $false },
                    [pscustomobject]@{ id = 'gpt-5.6-terra'; capabilities = [pscustomobject]@{ type = 'embeddings' } },
                    [pscustomobject]@{ id = 'gpt-5.5' }
                ) }
                Mock Get-CopilotModelCatalog { $catalog }

                copilot-model --auto

                (Get-Content -Raw $script:state).Trim() | Should -BeExactly 'gpt-5.5'
            }
        }

        It 'refreshes all local role pins while preserving unrelated settings' {
            InModuleScope Copilot {
                New-Item -ItemType Directory -Force -Path '.claude' | Out-Null
                @{
                    permissions = @{ allow = @('Read') }
                    env = @{
                        ANTHROPIC_BASE_URL = 'http://localhost:4142'
                        ANTHROPIC_MODEL = 'gpt-5.6-sol[1m]'
                        UNRELATED = 'keep-me'
                    }
                } | ConvertTo-Json -Depth 8 | Set-Content '.claude/settings.local.json'
                $limits = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 1000000 } }
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = 'gpt-5.6-sol'; capabilities = $limits },
                    [pscustomobject]@{ id = 'gpt-5.6-terra'; capabilities = $limits },
                    [pscustomobject]@{ id = 'gpt-5.6-luna'; capabilities = $limits }
                ) }
                Mock Get-CopilotModelCatalog { $catalog }

                copilot-model --auto

                $saved = Get-Content -Raw '.claude/settings.local.json' | ConvertFrom-Json
                $saved.env.ANTHROPIC_MODEL | Should -Be 'gpt-5.6-sol[1m]'
                $saved.env.ANTHROPIC_DEFAULT_FABLE_MODEL | Should -Be 'gpt-5.6-sol[1m]'
                $saved.env.ANTHROPIC_DEFAULT_OPUS_MODEL | Should -Be 'gpt-5.6-sol[1m]'
                $saved.env.ANTHROPIC_DEFAULT_SONNET_MODEL | Should -Be 'gpt-5.6-terra[1m]'
                $saved.env.ANTHROPIC_DEFAULT_HAIKU_MODEL | Should -Be 'gpt-5.6-luna[1m]'
                $saved.env.ANTHROPIC_SMALL_FAST_MODEL | Should -Be 'gpt-5.6-luna[1m]'
                $saved.env.UNRELATED | Should -Be 'keep-me'
                $saved.permissions.allow | Should -Contain 'Read'
            }
        }
    }

    Context 'package command authentication' {
        It 'uses the maintained fork login argv exactly' {
            InModuleScope Copilot {
                $script:authArgs = @()
                Mock Get-Command { [pscustomobject]@{ Name = 'bun'; Source = 'bun' } } -ParameterFilter { $Name -eq 'bun' }
                Mock Get-CopilotPkgFlavor { 'fork' }
                Mock Invoke-CopilotPkgCommand { $script:authArgs = @($Argument) }
                copilot-proxy auth
                $script:authArgs | Should -BeExactly @('auth', 'login', '--provider', 'copilot')
                $script:authArgs | Should -Not -Contain '--show-token'
            }
        }

        It 'keeps the original package on bare auth' {
            InModuleScope Copilot {
                $script:authArgs = @()
                Mock Get-Command { [pscustomobject]@{ Name = 'bun'; Source = 'bun' } } -ParameterFilter { $Name -eq 'bun' }
                Mock Get-CopilotPkgFlavor { 'original' }
                Mock Invoke-CopilotPkgCommand { $script:authArgs = @($Argument) }
                copilot-proxy auth
                $script:authArgs | Should -BeExactly @('auth')
                $script:authArgs | Should -Not -Contain '--show-token'
            }
        }

        It 'surfaces a foreground command nonzero without exiting the caller' {
            InModuleScope Copilot {
                Mock Install-CopilotPkg { $true }
                Mock Get-CopilotPkgLaunch {
                    @{ Exe = (Get-Command pwsh).Source; Pre = @('-NoProfile', '-Command'); Cwd = $null }
                }
                { Invoke-CopilotPkgCommand 'exit 23' } | Should -Throw '*exit code 23*'
                $global:LASTEXITCODE | Should -Be 23
                'caller-still-running' | Should -BeExactly 'caller-still-running'
            }
        }

        It 'throws and sets a failure status when package setup fails before launch' {
            InModuleScope Copilot {
                Mock Install-CopilotPkg { $false }
                $global:LASTEXITCODE = 0
                { Invoke-CopilotPkgCommand auth } | Should -Throw '*installation or verification failed*'
                $global:LASTEXITCODE | Should -Be 1
            }
        }

        It 'throws and sets a failure status when the launch path disappears' {
            InModuleScope Copilot {
                Mock Install-CopilotPkg { $true }
                Mock Get-CopilotPkgLaunch { $null }
                $global:LASTEXITCODE = 0
                { Invoke-CopilotPkgCommand auth } | Should -Throw '*no runnable copilot-api*'
                $global:LASTEXITCODE | Should -Be 1
            }
        }

        It 'preserves foreground stdout without appending a success boolean' {
            InModuleScope Copilot {
                Mock Install-CopilotPkg { $true }
                Mock Get-CopilotPkgLaunch {
                    @{ Exe = (Get-Command pwsh).Source; Pre = @('-NoProfile', '-Command'); Cwd = $null }
                }
                $result = @(Invoke-CopilotPkgCommand 'Write-Output device-login-visible')
                $result | Should -BeExactly @('device-login-visible')
                $global:LASTEXITCODE | Should -Be 0
            }
        }
    }

    Context 'copilot-here drift (env block is the single source of truth)' {
        BeforeEach {
            $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-drift-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.claude') | Out-Null
            Push-Location $tmp
        }
        AfterEach { Pop-Location; Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

        It 'reports no drift for a pin that matches the current block' {
            InModuleScope Copilot {
                $want = Get-CopilotEnvBlock -Pinned
                @{ env = $want } | ConvertTo-Json -Depth 5 | Set-Content '.claude/settings.local.json'
                Get-CopilotHereDrift | Should -BeNullOrEmpty
            }
        }
        It 'reports the model key when the pin is stale' {
            InModuleScope Copilot {
                $want = Get-CopilotEnvBlock -Pinned
                $want.ANTHROPIC_MODEL = 'claude-opus-4-8[1m]'
                @{ env = $want } | ConvertTo-Json -Depth 5 | Set-Content '.claude/settings.local.json'
                $drift = Get-CopilotHereDrift
                $drift | Should -Not -BeNullOrEmpty
                ($drift -join "`n") | Should -Match 'ANTHROPIC_MODEL : claude-opus-4-8\[1m\] ->'
            }
        }
        It 'catches keys missing from an older pin (the 4-of-8 bug)' {
            InModuleScope Copilot {
                $want = Get-CopilotEnvBlock -Pinned
                $partial = [ordered]@{}
                foreach ($k in 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL') {
                    $partial[$k] = $want[$k]
                }
                @{ env = $partial } | ConvertTo-Json -Depth 5 | Set-Content '.claude/settings.local.json'
                ($drift = Get-CopilotHereDrift) | Should -Not -BeNullOrEmpty
                ($drift -join "`n") | Should -Match 'ANTHROPIC_SMALL_FAST_MODEL : \(unset\) ->'
            }
        }
        It 'reports nothing when the pin is off (no ANTHROPIC_BASE_URL)' {
            InModuleScope Copilot {
                '{"env":{"FOO":"bar"}}' | Set-Content '.claude/settings.local.json'
                Get-CopilotHereDrift | Should -BeNullOrEmpty
            }
        }
    }

    Context 'specstory claude_cmd resolution' {
        BeforeEach {
            $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-ss-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.specstory/cli') | Out-Null
            Push-Location $tmp
        }
        AfterEach { Pop-Location; Remove-Item -Recurse -Force $script:tmp -ErrorAction SilentlyContinue }

        It 'reads an uncommented double-quoted claude_cmd' {
            InModuleScope Copilot {
                'claude_cmd = "claude --dangerously-skip-permissions"' | Set-Content '.specstory/cli/config.toml'
                Get-SpecstoryClaudeCmd | Should -Be 'claude --dangerously-skip-permissions'
            }
        }
        It 'ignores the commented example that ships in the default config' {
            InModuleScope Copilot {
                # Matching the shipped `# claude_cmd = "claude"` would re-introduce
                # the very bug the resolver exists to fix, so it must be skipped and
                # the real assignment below it used instead.
                @('# claude_cmd = "claude"', 'claude_cmd = "claude --resume"') |
                    Set-Content '.specstory/cli/config.toml'
                Get-SpecstoryClaudeCmd | Should -Be 'claude --resume'
            }
        }
        It 'reads a single-quoted claude_cmd' {
            InModuleScope Copilot {
                "claude_cmd = 'claude --verbose'" | Set-Content '.specstory/cli/config.toml'
                Get-SpecstoryClaudeCmd | Should -Be 'claude --verbose'
            }
        }
        It 'decodes escaped quotes in a TOML basic string without truncating the command' {
            InModuleScope Copilot {
                'claude_cmd = "C:/Tools/claude.cmd --append-system-prompt \"review only\""' |
                    Set-Content '.specstory/cli/config.toml'
                Get-SpecstoryClaudeCmd | Should -Be 'C:/Tools/claude.cmd --append-system-prompt "review only"'
                New-SpecstoryClaudeCommand | Should -BeExactly 'C:/Tools/claude.cmd --append-system-prompt "review only" --dangerously-skip-permissions'
            }
        }
        It 'ships an active bypass command in the create-seeded user config' {
            $seed = Get-Content -Raw (Join-Path $PSScriptRoot '..' 'private_dot_specstory' 'private_cli' 'create_config.toml')
            $seed | Should -Match '(?m)^claude_cmd\s*=\s*"claude --dangerously-skip-permissions"\s*$'
        }
    }

    Context 'specstory -c argument quoting' {
        It 'wraps an argument in single quotes' {
            InModuleScope Copilot { ConvertTo-CopilotShQuote 'two words' | Should -Be "'two words'" }
        }
        It 'escapes an embedded single quote POSIX-style' {
            InModuleScope Copilot { ConvertTo-CopilotShQuote "it's" | Should -Be "'it'\''s'" }
        }
    }

    Context 'specstory Claude command policy' {
        It 'adds bypass to a plain configured command' {
            InModuleScope Copilot {
                Mock Get-SpecstoryClaudeCmd { 'claude' }
                New-SpecstoryClaudeCommand | Should -BeExactly 'claude --dangerously-skip-permissions'
            }
        }
        It 'preserves configured flags and adds bypass once' {
            InModuleScope Copilot {
                Mock Get-SpecstoryClaudeCmd { 'claude --verbose' }
                $command = New-SpecstoryClaudeCommand -Argv @('--resume', 'session-id')
                $command | Should -BeExactly "claude --verbose --dangerously-skip-permissions '--resume' 'session-id'"
                ([regex]::Matches($command, '--dangerously-skip-permissions')).Count | Should -Be 1
            }
        }
        It 'does not duplicate bypass from the configured command or wrapper arguments' {
            InModuleScope Copilot {
                Mock Get-SpecstoryClaudeCmd { 'claude --dangerously-skip-permissions' }
                $command = New-SpecstoryClaudeCommand -Argv @('--dangerously-skip-permissions', '--verbose')
                ([regex]::Matches($command, '--dangerously-skip-permissions')).Count | Should -Be 1
                $command | Should -BeExactly "claude --dangerously-skip-permissions '--verbose'"
            }
        }
        It 'preserves argument order, duplicates, spaces, and embedded quotes' {
            InModuleScope Copilot {
                Mock Get-SpecstoryClaudeCmd { 'claude' }
                New-SpecstoryClaudeCommand -Argv @('--tag', 'two words', '--tag', "it's") |
                    Should -BeExactly "claude --dangerously-skip-permissions '--tag' 'two words' '--tag' 'it'\''s'"
            }
        }
    }

    Context 'copilot-run argument forwarding' {
        It 'keeps one child argument intact and preserves multiple arguments' {
            InModuleScope Copilot {
                function script:Invoke-CopilotArgProbe { $script:capturedChildArgs = @($args) }
                try {
                    Mock Test-CopilotAlive { $true }
                    Mock Get-CopilotShimEnabled { $false }
                    Mock Get-CopilotEnvBlock { @{} }

                    copilot-run Invoke-CopilotArgProbe --version
                    $script:capturedChildArgs | Should -Be @('--version')

                    copilot-run Invoke-CopilotArgProbe --model 'two words' --verbose
                    $script:capturedChildArgs | Should -Be @('--model', 'two words', '--verbose')
                } finally {
                    Remove-Item Function:\Invoke-CopilotArgProbe -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'restores the environment without masking a native child failure' {
            InModuleScope Copilot {
                $savedProbe = $env:COPILOT_RUN_TEST
                try {
                    Mock Test-CopilotAlive { $true }
                    Mock Get-CopilotShimEnabled { $false }
                    Mock Get-CopilotEnvBlock { @{ COPILOT_RUN_TEST = 'injected' } }
                    $env:COPILOT_RUN_TEST = 'original'

                    $errors = @()
                    copilot-run -ErrorAction SilentlyContinue -ErrorVariable +errors cmd.exe /d /c 'exit 7'
                    $succeeded = $?
                    $exitCode = $LASTEXITCODE

                    $succeeded | Should -BeFalse
                    $exitCode | Should -Be 7
                    $env:COPILOT_RUN_TEST | Should -BeExactly 'original'
                    ($errors.Exception.Message -join "`n") | Should -Match 'exited with code 7'
                } finally {
                    if ($null -eq $savedProbe) { Remove-Item env:COPILOT_RUN_TEST -ErrorAction SilentlyContinue }
                    else { $env:COPILOT_RUN_TEST = $savedProbe }
                }
            }
        }
    }

    Context 'claude-copilot launch routing' {
        It 'always passes an explicit bypass-enabled command to SpecStory with zero arguments' {
            InModuleScope Copilot {
                Mock Get-Command { [pscustomobject]@{ Name = 'specstory' } } -ParameterFilter { $Name -eq 'specstory' }
                Mock Get-SpecstoryClaudeCmd { 'claude' }
                Mock copilot-run { $script:capturedLaunch = @($Argv) }

                claude-copilot

                $script:capturedLaunch | Should -HaveCount 5
                $script:capturedLaunch | Should -Be @('specstory', 'run', 'claude', '-c', 'claude --dangerously-skip-permissions')
            }
        }
        It 'consumes a lone --specstory control without leaking it to Claude' {
            InModuleScope Copilot {
                Mock Get-Command { [pscustomobject]@{ Name = 'specstory' } } -ParameterFilter { $Name -eq 'specstory' }
                Mock Get-SpecstoryClaudeCmd { 'claude --verbose' }
                Mock copilot-run { $script:capturedLaunch = @($Argv) }

                claude-copilot --specstory

                ($script:capturedLaunch -join ' ') | Should -Not -Match -- '--specstory'
                $script:capturedLaunch[-1] | Should -BeExactly 'claude --verbose --dangerously-skip-permissions'
            }
        }
        It 'consumes a lone --no-specstory control and uses the direct bypass path' {
            InModuleScope Copilot {
                Mock copilot-run { $script:capturedLaunch = @($Argv) }

                claude-copilot --no-specstory

                $script:capturedLaunch | Should -Be @('claude', '--dangerously-skip-permissions')
                ($script:capturedLaunch -join ' ') | Should -Not -Match -- '--no-specstory'
            }
        }
        It 'uses the direct bypass path when SpecStory is unavailable' {
            InModuleScope Copilot {
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'specstory' }
                Mock copilot-run { $script:capturedLaunch = @($Argv) }

                claude-copilot --model custom-model

                $script:capturedLaunch | Should -Be @('claude', '--dangerously-skip-permissions', '--model', 'custom-model')
            }
        }
        It 'keeps claude-copilot-once as a single delegating policy layer' {
            InModuleScope Copilot {
                Mock Test-CopilotAlive { $true }
                Mock Test-Path { $false } -ParameterFilter { $Path -eq '.claude/settings.local.json' }
                Mock copilot-here {}
                Mock claude-copilot { $script:delegated = @($Argv) }
                Mock Get-CopilotBase { 'http://127.0.0.1:4141' }

                claude-copilot-once --specstory --resume session-id

                $script:delegated | Should -Be @('--specstory', '--resume', 'session-id')
                Should -Invoke claude-copilot -Times 1 -Exactly
            }
        }

        It 'distinguishes zero arguments from one explicit empty argument' {
            InModuleScope Copilot {
                Mock Test-CopilotAlive { $true }
                Mock Test-Path { $false } -ParameterFilter { $Path -eq '.claude/settings.local.json' }
                Mock copilot-here {}
                Mock claude-copilot {
                    $script:delegatedWasNull = $null -eq $Argv
                    $script:delegated = @($Argv)
                }
                Mock Get-CopilotBase { 'http://127.0.0.1:4141' }

                claude-copilot-once
                $script:delegatedWasNull | Should -BeTrue

                claude-copilot-once ''
                $script:delegatedWasNull | Should -BeFalse
                $script:delegated | Should -HaveCount 1
                $script:delegated[0] | Should -BeExactly ''
                Should -Invoke claude-copilot -Times 2 -Exactly
            }
        }

        It 'does not mask a delegated session failure during cleanup' {
            InModuleScope Copilot {
                Mock Test-CopilotAlive { $true }
                Mock Test-Path { $false } -ParameterFilter { $Path -eq '.claude/settings.local.json' }
                Mock copilot-here {}
                Mock claude-copilot {
                    $global:LASTEXITCODE = 9
                    Write-Error 'delegated failure'
                }
                Mock Get-CopilotBase { 'http://127.0.0.1:4141' }

                $errors = @()
                claude-copilot-once -ErrorAction SilentlyContinue -ErrorVariable +errors
                $succeeded = $?
                $exitCode = $LASTEXITCODE

                $succeeded | Should -BeFalse
                $exitCode | Should -Be 9
                ($errors.Exception.Message -join "`n") | Should -Match 'session exited with code 9'
                Should -Invoke copilot-here -Times 2 -Exactly
            }
        }
    }

    Context 'http proxy resolution' {
        It 'returns nothing when disabled' {
            InModuleScope Copilot {
                $env:COPILOT_HTTP_PROXY = 'never'
                Resolve-CopilotHttpProxy | Should -BeNullOrEmpty
            }
        }
        It 'passes an explicit URL straight through' {
            InModuleScope Copilot {
                $env:COPILOT_HTTP_PROXY = 'http://127.0.0.1:7897'
                Resolve-CopilotHttpProxy | Should -Be 'http://127.0.0.1:7897'
            }
        }
        AfterEach { $env:COPILOT_HTTP_PROXY = $null }
    }

    Context 'optional ChatGPT Apps probe classification' {
        It 'keeps timeout, TLS, and generic network failures distinct' {
            InModuleScope Copilot {
                Get-CopilotProbeFailureKind 'The operation timed out' | Should -Be 'timeout'
                Get-CopilotProbeFailureKind 'UNKNOWN_CERTIFICATE_VERIFICATION_ERROR' | Should -Be 'tls'
                Get-CopilotProbeFailureKind 'No route to host' | Should -Be 'network'
            }
        }

        It 'counts an HTTP authentication rejection as reachable' {
            InModuleScope Copilot {
                Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 401 } }
                $result = Invoke-CopilotOptionalHttpProbe -Uri 'https://chatgpt.com/backend-api/wham/apps'
                $result.Reached | Should -BeTrue
                $result.Code | Should -Be 401
            }
        }
    }

    Context 'served-model parsing (includes claude_model_id alias)' {
        It 'returns both .id and .claude_model_id, sorted-unique' {
            InModuleScope Copilot {
                Mock Invoke-RestMethod {
                    [pscustomobject]@{ data = @(
                        [pscustomobject]@{ id = 'claude-opus-4-8'; claude_model_id = 'claude-opus-4-8[1m]' },
                        [pscustomobject]@{ id = 'text-embedding-3-small' }
                    ) }
                }
                $m = Get-CopilotServedModels
                $m | Should -Contain 'claude-opus-4-8'
                $m | Should -Contain 'claude-opus-4-8[1m]'
                $m | Should -Contain 'text-embedding-3-small'
            }
        }
    }

    Context 'effective-model precedence' {
        It 'reports the built-in default when nothing is pinned' {
            InModuleScope Copilot {
                Push-Location ([System.IO.Path]::GetTempPath())
                $env:COPILOT_CLAUDE_MODEL = $null
                Mock Get-CopilotModelState { Join-Path ([System.IO.Path]::GetTempPath()) 'nope-copilot-model' }
                (Get-CopilotEffectiveModel) | Should -Match 'built-in default$'
                Pop-Location
            }
        }

        It 'does not fall through when an active project proxy pin omits its main model' {
            $project = Join-Path $TestDrive 'missing-main-project'
            New-Item -ItemType Directory -Force (Join-Path $project '.claude') | Out-Null
            @{ env = @{ ANTHROPIC_BASE_URL = 'http://localhost:4142' } } |
                ConvertTo-Json -Depth 4 | Set-Content (Join-Path $project '.claude/settings.local.json')
            InModuleScope Copilot -Parameters @{ Settings = (Join-Path $project '.claude/settings.local.json') } {
                param($Settings)
                $env:COPILOT_CLAUDE_MODEL = 'gpt-5.6-sol[1m]'
                try {
                    $effective = (Get-CopilotEffectiveModel -Settings $Settings) -split '\|', 2
                    $effective[0] | Should -BeNullOrEmpty
                    $effective[1] | Should -Match 'project pin missing ANTHROPIC_MODEL'
                } finally {
                    $env:COPILOT_CLAUDE_MODEL = $null
                }
            }
        }
    }

    Context 'doctor live-target selection' {
        It 'uses the configured main raw id when the catalog serves its [1m] pin' {
            InModuleScope Copilot {
                $target = Resolve-CopilotDoctorTarget -ConfiguredMain 'claude-opus-5[1m]' `
                    -RawModel @('claude-opus-5', 'gpt-5.6-sol')
                $target.Model | Should -BeExactly 'claude-opus-5'
                $target.Label | Should -BeExactly 'ConfiguredMain'
                $target.Reason | Should -Match 'configured main is advertised'
            }
        }

        It 'labels and explains a capability-ranked catalog fallback' {
            InModuleScope Copilot {
                $target = Resolve-CopilotDoctorTarget -ConfiguredMain 'claude-opus-5[1m]' `
                    -RawModel @('gpt-5.6-terra', 'gpt-5.6-sol')
                $target.Model | Should -BeExactly 'gpt-5.6-sol'
                $target.Label | Should -BeExactly 'CatalogFallback'
                $target.Reason | Should -Match "claude-opus-5.*not advertised"
            }
        }

        It 'uses only selectable ids for an automatic catalog fallback' {
            InModuleScope Copilot {
                $target = Resolve-CopilotDoctorTarget -ConfiguredMain 'claude-opus-5[1m]' `
                    -RawModel @('claude-fable-5', 'gpt-5.5') -SelectableModel @('gpt-5.5')
                $target.Model | Should -BeExactly 'gpt-5.5'
                $target.Label | Should -BeExactly 'CatalogFallback'
            }
        }

        It 'refuses to probe an unrelated fallback when the active project main is missing' {
            InModuleScope Copilot {
                $target = Resolve-CopilotDoctorTarget -ConfiguredMain '' -RawModel @('gpt-5.6-sol')
                $target.Model | Should -BeNullOrEmpty
                $target.Label | Should -BeExactly 'MissingConfiguredMain'
                $target.Reason | Should -Match 'no ANTHROPIC_MODEL'
            }
        }
    }

    Context 'doctor inference error parsing and classification' {
        It 'classifies a direct billing error as account-wide and nonretryable' {
            InModuleScope Copilot {
                $result = Classify-CopilotInferenceError -StatusCode 402 `
                    -Body '{"code":"billing_not_configured","message":"Enable billing"}'
                $result.Kind | Should -BeExactly 'BillingNotConfigured'
                $result.AccountWide | Should -BeTrue
                $result.Retryable | Should -BeFalse
                $result.Action | Should -BeExactly 'https://github.com/settings/copilot/features'
                $result.Guidance | Should -Match 'model.*--auto.*shim cannot fix'
            }
        }

        It 'classifies an error.code billing envelope' {
            InModuleScope Copilot {
                $result = Classify-CopilotInferenceError -StatusCode 402 `
                    -Body '{"error":{"code":"billing_not_configured","message":"No billing"}}'
                $result.Kind | Should -BeExactly 'BillingNotConfigured'
                $result.Message | Should -BeExactly 'No billing'
            }
        }

        It 'classifies billing JSON encoded inside error.message' {
            InModuleScope Copilot {
                $inner = @{ error = @{ code = 'billing_not_configured'; message = 'Nested billing' } } |
                    ConvertTo-Json -Compress
                $outer = @{ error = @{ message = $inner } } | ConvertTo-Json -Compress
                $result = Classify-CopilotInferenceError -StatusCode 402 -Body $outer
                $result.Kind | Should -BeExactly 'BillingNotConfigured'
                $result.Code | Should -BeExactly 'billing_not_configured'
                $result.Message | Should -BeExactly 'Nested billing'
            }
        }

        It 'merges an outer billing code with a nested JSON message' {
            InModuleScope Copilot {
                $inner = @{ message = 'Choose a billing entity' } | ConvertTo-Json -Compress
                $outer = @{ error = @{ code = 'billing_not_configured'; message = $inner } } | ConvertTo-Json -Compress
                $result = Classify-CopilotInferenceError -StatusCode 402 -Body $outer
                $result.Kind | Should -BeExactly 'BillingNotConfigured'
                $result.Code | Should -BeExactly 'billing_not_configured'
                $result.Message | Should -BeExactly 'Choose a billing entity'
            }
        }

        It 'gives unsupported models only model-selection guidance' {
            InModuleScope Copilot {
                $result = Classify-CopilotInferenceError -StatusCode 400 `
                    -Body '{"error":{"code":"model_not_supported","message":"No such model"}}'
                $result.Kind | Should -BeExactly 'ModelUnsupported'
                $result.Action | Should -Match 'copilot-model --auto'
                $result.Guidance | Should -BeNullOrEmpty
                $result.AccountWide | Should -BeFalse
            }
        }

        It 'keeps an unknown generic 4xx body compact and nonretryable' {
            InModuleScope Copilot {
                $result = Classify-CopilotInferenceError -StatusCode 403 `
                    -Body "  upstream denied`n  without json  "
                $result.Kind | Should -BeExactly 'HttpError'
                $result.Retryable | Should -BeFalse
                $result.Summary | Should -BeExactly 'upstream denied without json'
            }
        }
    }

    Context 'doctor catalog snapshot and single inference attempt' {
        It 'fetches one catalog and never retries a failed live request' {
            InModuleScope Copilot -Parameters @{ Drive = $TestDrive } {
                param($Drive)
                $token = Join-Path $Drive 'github_token'
                'ghu_test' | Set-Content -LiteralPath $token
                $limits = [pscustomobject]@{ limits = [pscustomobject]@{ max_context_window_tokens = 1000000 } }
                $catalog = [pscustomobject]@{ data = @(
                    [pscustomobject]@{
                        id = 'gpt-5.6-sol'; claude_model_id = 'gpt-5.6-sol[1m]'
                        capabilities = $limits
                    }
                ) }

                Mock Get-Command { [pscustomobject]@{ Source = [string]$Name } }
                Mock Test-CopilotPkgReady { $true }
                Mock Get-CopilotPkgMetadata { [pscustomobject]@{ Name = '@jeffreycao/copilot-api'; Version = '2.1.0' } }
                Mock Get-CopilotPkgStampMetadata {
                    [pscustomobject]@{ RequestedSpec = '@jeffreycao/copilot-api@2.1.0'; Name = '@jeffreycao/copilot-api'; Version = '2.1.0' }
                }
                Mock Get-CopilotPkgLaunch { @{ Exe = 'copilot-api.cmd'; Pre = @(); Cwd = $null } }
                Mock Get-CopilotToken { $token }
                Mock Test-CopilotAlive { $true }
                Mock Get-CopilotStaleInstaller { @() }
                Mock Get-CopilotShimEnabled { $true }
                Mock Test-CopilotShimAlive { $true }
                Mock Get-CopilotShimBase { 'http://localhost:4999' }
                Mock Resolve-CopilotHttpProxy { $null }
                Mock Get-CopilotUpstreamModel { @('gpt-5.6-sol') }
                Mock Get-CopilotModelCatalog { $catalog }
                Mock Get-CopilotEffectiveModel { 'gpt-5.6-sol[1m]|test pin' }
                Mock Invoke-WebRequest {
                    if ($Uri -like '*/v1/messages?beta=true') {
                        return [pscustomobject]@{
                            StatusCode = 402
                            Content = '{"error":{"code":"billing_not_configured","message":"No billing"}}'
                        }
                    }
                    [pscustomobject]@{ StatusCode = 401; Content = '' }
                }

                Invoke-CopilotDoctor -Live

                $directMessagesUri = "$(Get-CopilotBase)/v1/messages?beta=true"
                Should -Invoke Get-CopilotModelCatalog -Times 1 -Exactly
                Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $directMessagesUri }
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like 'http://localhost:4999/*' }
            }
        }
    }

    # The shim has no /_shim/health on this build, so Test-CopilotShimAlive only
    # proves that SOMETHING answers HTTP on the port (-SkipHttpErrorCheck accepts
    # a 404 too). Everything below is about not letting that weak signal decide
    # port state or client routing.
    # pitfalls/copilot-proxy-shim-port-held-by-another-process.md
    Context 'shim port ownership' {
        It 'refuses to spawn when the port is held by a foreign process' {
            InModuleScope Copilot {
                Mock Get-CopilotPortOwner {
                    [pscustomobject]@{ Owner = 'foreign'; Pids = @(4242); Labels = @('4242(python.exe)') }
                }
                # Alive on purpose: a foreign HTTP listener passes this probe, and
                # that is exactly the case the ownership check has to catch.
                Mock Test-CopilotShimAlive { $true }
                Mock Stop-Process {}
                Mock Start-Process { throw 'must not spawn' }
                Mock Write-Error {}

                Start-CopilotShim | Should -BeFalse

                Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                    $Message -match 'held by another process.*4242\(python\.exe\)'
                }
                Should -Invoke Stop-Process -Times 0 -Exactly
                Should -Invoke Start-Process -Times 0 -Exactly
            }
        }
        It 'reclaims the port from one of our own stale shims' {
            InModuleScope Copilot {
                $script:ownerCalls = 0
                Mock Get-CopilotPortOwner {
                    $script:ownerCalls++
                    if ($script:ownerCalls -eq 1) {
                        [pscustomobject]@{ Owner = 'ours'; Pids = @(4242); Labels = @() }
                    } else {
                        [pscustomobject]@{ Owner = 'free'; Pids = @(); Labels = @() }
                    }
                }
                # Not alive: an OLDER shim build answers nothing we recognise, which
                # is what used to be misread as "port free" -> EADDRINUSE forever.
                Mock Test-CopilotShimAlive { $script:ownerCalls -gt 1 }
                Mock Get-Command { [pscustomobject]@{ Source = 'bun' } } -ParameterFilter { $Name -eq 'bun' }
                Mock Test-Path { $true }
                Mock Stop-Process {}
                Mock Start-Process { [pscustomobject]@{ Id = 9001 } }
                Mock Set-Content {}
                Start-CopilotShim | Should -BeTrue
                Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }
                Should -Invoke Start-Process -Times 1 -Exactly
            }
        }
        It 'scopes COPILOT_SHIM_* to the child instead of leaking into the session' {
            InModuleScope Copilot {
                Mock Get-CopilotPortOwner { [pscustomobject]@{ Owner = 'free'; Pids = @(); Labels = @() } }
                Mock Test-CopilotShimAlive { $script:spawned -eq $true }
                Mock Get-Command { [pscustomobject]@{ Source = 'bun' } } -ParameterFilter { $Name -eq 'bun' }
                Mock Test-Path { $true }
                Mock Set-Content {}
                $script:spawned = $false
                $script:seenPort = $null
                Mock Start-Process {
                    # The child would inherit these; assert they are set AT spawn time.
                    $script:seenPort = $env:COPILOT_SHIM_PORT
                    $script:seenUpstream = $env:COPILOT_SHIM_UPSTREAM
                    $script:spawned = $true
                    [pscustomobject]@{ Id = 9002 }
                }
                $before = $env:COPILOT_SHIM_UPSTREAM
                Start-CopilotShim | Should -BeTrue
                $script:seenPort | Should -Be (Get-CopilotShimPort)
                $script:seenUpstream | Should -Be (Get-CopilotBase)
                # ...and are gone again afterwards.
                $env:COPILOT_SHIM_UPSTREAM | Should -Be $before
            }
        }
        It 'treats an uninspectable port as unknown, not as free-and-foreign' {
            InModuleScope Copilot {
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-NetTCPConnection' }
                $holder = Get-CopilotPortOwner -Port 4142
                $holder.Owner | Should -Be 'unknown'
            }
        }
    }

    Context 'managed clients fail closed on an enabled shim' {
        It 'Assert-CopilotShim is a no-op when the shim is switched off' {
            InModuleScope Copilot {
                Mock Get-CopilotShimEnabled { $false }
                Mock Start-CopilotShim { throw 'must not start a disabled shim' }
                Assert-CopilotShim | Should -BeTrue
            }
        }
        It 'Assert-CopilotShim refuses rather than silently using the bare proxy' {
            InModuleScope Copilot {
                Mock Get-CopilotShimEnabled { $true }
                Mock Start-CopilotShim { $false }
                Mock Write-Error {}

                Assert-CopilotShim | Should -BeFalse

                Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
                    $Message -match 'refused to bypass the enabled metrics shim'
                }
            }
        }
        It 'client base stays on the shim when it is enabled but down' {
            InModuleScope Copilot {
                Mock Get-CopilotShimEnabled { $true }
                Mock Test-CopilotShimAlive { $false }
                # Pre-fix this fell back to Get-CopilotBase, silently dropping the
                # keepalive AND the Responses tool-description normalisation.
                Get-CopilotClientBase | Should -Be (Get-CopilotShimBase)
                Get-CopilotClientBase | Should -Be (Get-CopilotPinnedBase)
            }
        }
        It 'copilot-run aborts instead of running against a bypassed shim' {
            InModuleScope Copilot {
                Mock Test-CopilotAlive { $true }
                Mock Assert-CopilotShim { $false }
                Mock Get-CopilotEnvBlock { throw 'must not build an env block' }
                { copilot-run 'cmd-that-must-not-run' } | Should -Not -Throw
                Should -Invoke Assert-CopilotShim -Times 1 -Exactly
            }
        }
    }

    Context 'public surface' {
        It 'exports the ten commands' {
            $exported = (Get-Command -Module Copilot).Name
            foreach ($c in 'copilot-proxy', 'copilot-run', 'claude-copilot', 'claude-copilot-once', 'codex-copilot', 'codex-copilot-once', 'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch') {
                $exported | Should -Contain $c
            }
        }
    }

    Context 'Responses compatibility shim' {
        It 'matches the reviewed Unix shim artifact without a sibling checkout' {
            $shimContract = [ordered]@{
                UnixSourceCommit = 'b205a2adbe09413d641c19a57f67fd27621dcff2'
                Sha256 = '9B60237B2C1ABF1616ECA5EC6E91C4B8FAC209CC41472E23BF23498BB1940D67'
            }
            $windowsShim = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js'
            $shimContract.UnixSourceCommit | Should -Match '^[0-9a-f]{40}$'
            (Get-FileHash -Algorithm SHA256 $windowsShim).Hash |
                Should -BeExactly $shimContract.Sha256
        }

        It 'fills blank MCP descriptions without adding one to a native tool' {
            if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bun is unavailable'; return }
            $env:COPILOT_SHIM_TEST_PATH = (Resolve-Path (Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js')).Path
            try {
                $json = & bun -e @'
import { pathToFileURL } from "node:url";
const { normalizeResponsesToolDescriptions: n } = await import(pathToFileURL(process.env.COPILOT_SHIM_TEST_PATH));
const p = { tools: [{ type: "web_search" }], input: [{ type: "plugin_tools", tools: [{ name: "alpha", description: "" }] }] };
const r = n(p);
console.log(JSON.stringify({ r, p }));
'@
                $result = $json | ConvertFrom-Json
                $result.r.changed | Should -Be 1
                $result.p.input[0].tools[0].description | Should -Be 'Tool alpha.'
                $result.p.tools[0].PSObject.Properties.Name | Should -Not -Contain 'description'
            } finally { Remove-Item env:COPILOT_SHIM_TEST_PATH -ErrorAction SilentlyContinue }
        }

        It 'decodes zstd Responses bodies before normalization' {
            if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bun is unavailable'; return }
            $env:COPILOT_SHIM_TEST_PATH = (Resolve-Path (Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js')).Path
            try {
                $json = & bun -e @'
import { pathToFileURL } from "node:url";
const { normalizeRequestBody: n } = await import(pathToFileURL(process.env.COPILOT_SHIM_TEST_PATH));
const source = JSON.stringify({ input: [{ tools: [{ name: "compressed", description: "" }] }] });
const compressed = Bun.zstdCompressSync(new TextEncoder().encode(source));
const r = n("/responses", compressed, "zstd");
console.log(JSON.stringify({ changed: r.changed, decoded: r.decoded, p: JSON.parse(r.body) }));
'@
                $LASTEXITCODE | Should -Be 0
                $result = $json | ConvertFrom-Json
                $result.changed | Should -Be 1
                $result.decoded | Should -BeTrue
                $result.p.input[0].tools[0].description | Should -BeExactly 'Tool compressed.'
            } finally { Remove-Item env:COPILOT_SHIM_TEST_PATH -ErrorAction SilentlyContinue }
        }

        It 'classifies only an explicit stream true body as streaming' {
            if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bun is unavailable'; return }
            $env:COPILOT_SHIM_TEST_PATH = (Resolve-Path (Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js')).Path
            try {
                $json = & bun -e @'
import { pathToFileURL } from "node:url";
const { wantsStream: w } = await import(pathToFileURL(process.env.COPILOT_SHIM_TEST_PATH));
const enc = (o) => new TextEncoder().encode(JSON.stringify(o)).buffer;
console.log(JSON.stringify({
  yes: w(enc({ model: "m", stream: true })),
  str: w(JSON.stringify({ model: "m", stream: true })),
  no: w(enc({ model: "m", stream: false })),
  missing: w(enc({ model: "m" })),
  truthy: w(enc({ model: "m", stream: "true" })),
  garbage: w(new TextEncoder().encode("not json").buffer),
}));
'@
                $LASTEXITCODE | Should -Be 0
                $result = $json | ConvertFrom-Json
                $result.yes | Should -BeTrue
                $result.str | Should -BeTrue
                $result.no | Should -BeFalse
                $result.missing | Should -BeFalse
                $result.truthy | Should -BeFalse
                $result.garbage | Should -BeFalse
            } finally { Remove-Item env:COPILOT_SHIM_TEST_PATH -ErrorAction SilentlyContinue }
        }

        It 'keeps fast and non-streaming responses transparent while protecting slow streams' {
            if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bun is unavailable'; return }
            $shim = (Resolve-Path (Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js')).Path
            $testScript = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-shim-keepalive-$([guid]::NewGuid()).mjs"
            try {
                [System.IO.File]::WriteAllText($testScript, @'
import { pathToFileURL } from "node:url";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const upstream = Bun.serve({
  port: 0,
  idleTimeout: 60,
  async fetch(req) {
    const url = new URL(req.url);
    await sleep(Number(url.searchParams.get("delay") ?? 0));
    if (url.searchParams.get("mode") === "status") {
      return new Response('{"error":"nope"}', {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    }
    return new Response("event: message_start\ndata: {}\n\nevent: message_stop\ndata: {}\n\n", {
      headers: { "content-type": "text/event-stream" },
    });
  },
});
process.env.COPILOT_SHIM_PORT = "0";
process.env.COPILOT_SHIM_UPSTREAM = `http://localhost:${upstream.port}`;
process.env.COPILOT_SHIM_PING_MS = "150";
process.env.COPILOT_SHIM_PING_AFTER_MS = "100";
process.env.COPILOT_SHIM_STALL_MS = "5000";
const { startServer } = await import(pathToFileURL(process.argv[2]).href);
const shim = startServer();
const call = async (query, stream = true) => {
  const response = await fetch(`http://localhost:${shim.port}/v1/messages${query}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "m", stream }),
  });
  const body = await response.text();
  return {
    status: response.status,
    contentType: response.headers.get("content-type"),
    body,
    pings: (body.match(/^: /gm) ?? []).length,
    events: (body.match(/^event: (\S+)/gm) ?? []).map((item) => item.slice(7)),
  };
};
const result = {
  slow: await call("?delay=800"),
  fast: await call("?delay=0"),
  plain: await call("?delay=800&mode=status", false),
  lateError: await call("?delay=800&mode=status"),
};
console.log(JSON.stringify(result));
shim.stop(true);
upstream.stop(true);
'@, [System.Text.UTF8Encoding]::new($false))

                $output = & bun $testScript $shim
                $LASTEXITCODE | Should -Be 0
                $jsonLine = @($output | Where-Object { "$_" -like '{"slow"*' })[-1]
                $jsonLine | Should -Not -BeNullOrEmpty
                $result = $jsonLine | ConvertFrom-Json

                $result.slow.pings | Should -BeGreaterThan 0
                ($result.slow.events -join ',') | Should -BeExactly 'message_start,message_stop'
                $result.fast.pings | Should -Be 0
                ($result.fast.events -join ',') | Should -BeExactly 'message_start,message_stop'
                $result.plain.status | Should -Be 400
                $result.plain.contentType | Should -BeExactly 'application/json'
                $result.plain.body | Should -BeExactly '{"error":"nope"}'
                $result.plain.pings | Should -Be 0
                $result.lateError.status | Should -Be 200
                ($result.lateError.events -join ',') | Should -BeExactly 'error'
            } finally {
                if ([System.IO.File]::Exists($testScript)) { [System.IO.File]::Delete($testScript) }
            }
        }

        It 'passes the canonical slow-stream hardening fixture' {
            if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'bun is unavailable'; return }
            $shim = (Resolve-Path (Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js')).Path
            $fixture = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures' 'copilot-shim-hardening.mjs')).Path
            $metricsDb = Join-Path ([System.IO.Path]::GetTempPath()) "copilot-shim-hardening-$([guid]::NewGuid()).sqlite"
            try {
                $output = & bun $fixture $shim $metricsDb
                $LASTEXITCODE | Should -Be 0
                $jsonLine = @($output | Where-Object { "$_" -like '{"cancelBarrier"*' })[-1]
                $jsonLine | Should -Not -BeNullOrEmpty
                $result = $jsonLine | ConvertFrom-Json

                $result.cancelBarrier.waited | Should -BeTrue
                $result.retryReplay.sameBody | Should -BeTrue
                $result.retryReplay.sameTrace | Should -BeTrue
                $result.responseCodes.status402 | Should -BeExactly 'insufficient_quota'
                $result.responseCodes.status500 | Should -BeExactly 'server_error'
                $result.fastNonSse.status | Should -Be 502
                $result.cancellation.deadResult | Should -BeExactly 'AbortError'
            } finally {
                Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($metricsDb)) -Filter "$([System.IO.Path]::GetFileName($metricsDb))*" -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
