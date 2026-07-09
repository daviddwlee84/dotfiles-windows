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
                Get-CopilotDefaultModel | Should -Be 'claude-opus-4-8[1m]'
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
