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
            InModuleScope Copilot { $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@1.13.14'; Get-CopilotPkgFlavor | Should -Be 'fork' }
        }
        AfterEach { $env:COPILOT_API_PKG = $null }
    }

    Context 'default model resolution' {
        It 'falls back to the built-in default' {
            InModuleScope Copilot {
                $env:COPILOT_CLAUDE_MODEL = $null
                Mock Get-CopilotModelState { Join-Path ([System.IO.Path]::GetTempPath()) 'does-not-exist-copilot-model' }
                Get-CopilotDefaultModel | Should -Be 'claude-opus-5[1m]'
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
                $env:COPILOT_API_PKG = '@jeffreycao/copilot-api@1.13.14'
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
        It 'prefers Claude and appends [1m] for the 1M-window ids' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gpt-5', 'claude-opus-5', 'gemini-2.5-pro') |
                    Should -Be 'claude-opus-5[1m]'
            }
        }
        It 'does not append [1m] to a non-1M Claude id' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('claude-haiku-4-5') | Should -Be 'claude-haiku-4-5'
            }
        }
        It 'falls back to Codex when no Claude is served' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gpt-5-mini', 'gpt-5-codex', 'gemini-2.5-flash') |
                    Should -Be 'gpt-5-codex'
            }
        }
        It 'skips gpt-5 mini/nano in favour of the full model' {
            InModuleScope Copilot {
                Select-CopilotBestModel -Model @('gpt-5-mini', 'gpt-5-nano', 'gpt-5') | Should -Be 'gpt-5'
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
        It 'exports the eight commands' {
            $exported = (Get-Command -Module Copilot).Name
            foreach ($c in 'copilot-proxy', 'copilot-run', 'claude-copilot', 'claude-copilot-once', 'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch') {
                $exported | Should -Contain $c
            }
        }
    }
}
