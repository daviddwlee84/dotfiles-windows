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
        AfterEach { $env:COPILOT_API_PKG = $null }
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

    Context 'fork authentication' {
        It 'selects the Copilot provider explicitly for the maintained fork' {
            InModuleScope Copilot {
                $script:authArgs = @()
                Mock Get-Command { [pscustomobject]@{ Name = 'bun'; Source = 'bun' } } -ParameterFilter { $Name -eq 'bun' }
                Mock Get-CopilotPkgFlavor { 'fork' }
                Mock Invoke-CopilotPkgCommand { $script:authArgs = @($Argument) }
                copilot-proxy auth
                $script:authArgs | Should -Be @('auth', '--provider', 'copilot')
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
    }

    Context 'public surface' {
        It 'exports the ten commands' {
            $exported = (Get-Command -Module Copilot).Name
            foreach ($c in 'copilot-proxy', 'copilot-run', 'claude-copilot', 'claude-copilot-once', 'codex-copilot', 'codex-copilot-once', 'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch') {
                $exported | Should -Contain $c
            }
        }
    }
}
