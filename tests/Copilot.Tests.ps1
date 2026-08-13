# Pester tests for the Copilot module. Runtime behaviour (proxy start, live
# HTTP) can't be exercised without Windows + copilot-api, so these cover the
# pure logic: package-flavor detection, model resolution/normalisation, served-
# model parsing, and the effective-model precedence — with HTTP mocked.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'modules' 'Copilot' 'Copilot.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Copilot module' {

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
                Install-CopilotPkg 2>$null | Should -BeFalse
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
                Install-CopilotPkg 2>$null | Should -BeFalse
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
                Install-CopilotPkg 2>$null | Should -BeFalse
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
        It 'keeps older flagship and coding models ahead of lightweight models' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gpt-5-mini', 'gpt-5-codex') | Should -Be 'gpt-5-codex'
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
    }

    Context 'specstory -c argument quoting' {
        It 'wraps an argument in single quotes' {
            InModuleScope Copilot { ConvertTo-CopilotShQuote 'two words' | Should -Be "'two words'" }
        }
        It 'escapes an embedded single quote POSIX-style' {
            InModuleScope Copilot { ConvertTo-CopilotShQuote "it's" | Should -Be "'it'\''s'" }
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

    Context 'public surface' {
        It 'exports the ten commands' {
            $exported = (Get-Command -Module Copilot).Name
            foreach ($c in 'copilot-proxy', 'copilot-run', 'claude-copilot', 'claude-copilot-once', 'codex-copilot', 'codex-copilot-once', 'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch') {
                $exported | Should -Contain $c
            }
        }
    }

    Context 'Responses compatibility shim' {
        It 'keeps the Unix and Windows shim implementations byte-identical' {
            $unixShim = '/Users/david/.local/share/chezmoi/dot_config/shell/copilot-throttle-shim.js'
            if (-not (Test-Path -LiteralPath $unixShim)) { Set-ItResult -Skipped -Because 'Unix sibling checkout is unavailable'; return }
            $windowsShim = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'copilot-throttle-shim.js'
            (Get-FileHash -Algorithm SHA256 $windowsShim).Hash |
                Should -Be (Get-FileHash -Algorithm SHA256 $unixShim).Hash
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
    }
}
