BeforeAll {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $ScriptPath = Join-Path $RepoRoot 'scripts\codex-hooks-merge.ps1'
    $TemplatePath = Join-Path $RepoRoot '.chezmoiscripts\run_after_27_codex_hooks.ps1.tmpl'
    . $ScriptPath

    function New-CodexHookFixture {
        $root = Join-Path $TestDrive ('codex hooks ' + [guid]::NewGuid().ToString('N'))
        $codex = Join-Path $root '.codex'
        $peon = Join-Path $root '.openpeon\hooks\peon-ping'
        New-Item -ItemType Directory -Force (Join-Path $peon 'adapters'), $codex | Out-Null
        $herdr = Join-Path $codex 'herdr-agent-state.ps1'
        $adapter = Join-Path $peon 'adapters\codex.ps1'
        'param([string]$Action); [Console]::In.ReadToEnd() | Out-Null; exit 0' | Set-Content -LiteralPath $herdr
        '[Console]::In.ReadToEnd() | Out-Null; exit 0' | Set-Content -LiteralPath $adapter
        [pscustomobject]@{
            Root = $root
            Config = Join-Path $codex 'config.toml'
            Hooks = Join-Path $codex 'hooks.json'
            Herdr = $herdr
            PeonDir = $peon
            Adapter = $adapter
        }
    }
}

Describe 'Codex inline hook convergence' {
    It 'encodes script paths so cmd.exe sees no nested path quotes' {
        $fixture = New-CodexHookFixture
        $block = New-CodexManagedHookBlock -HerdrScript $fixture.Herdr -PeonAdapter $fixture.Adapter `
            -PeonDir $fixture.PeonDir -EnablePeon $true

        $block | Should -Match 'EncodedCommand [A-Za-z0-9+/=]+'
        $block | Should -Not -Match '-File\s+"'
        $block | Should -Match 'CLAUDE_PEON_DIR'
    }

    It 'migrates owned legacy hooks, retires hooks.json, and is byte-idempotent' {
        $fixture = New-CodexHookFixture
        @'
[features]
hooks = true

# peon-ping Codex hooks begin
[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "old"
# peon-ping Codex hooks end

[tui]
status_line = ["model"]
'@ | Set-Content -LiteralPath $fixture.Config
        @{ hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = "powershell -File `"$($fixture.Herdr)`" session" }) }) } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture.Hooks
        Mock Test-CodexHooksToml { $true }

        Sync-CodexHooks -ConfigPath $fixture.Config -HooksPath $fixture.Hooks -HerdrScript $fixture.Herdr `
            -PeonDir $fixture.PeonDir -EnablePeon $true | Should -BeTrue

        Test-Path -LiteralPath $fixture.Hooks | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Split-Path $fixture.Hooks) -Filter 'hooks.json.pre-inline-*.bak').Count | Should -Be 1
        $first = [IO.File]::ReadAllBytes($fixture.Config)
        $text = [Text.Encoding]::UTF8.GetString($first)
        $text | Should -Match '# managed Codex hooks begin'
        $text | Should -Not -Match '# peon-ping Codex hooks begin'
        $text | Should -Match '\[\[hooks\.SessionStart\]\]'
        $text | Should -Match '\[\[hooks\.Stop\]\]'
        $text | Should -Match 'EncodedCommand'

        Sync-CodexHooks -ConfigPath $fixture.Config -HooksPath $fixture.Hooks -HerdrScript $fixture.Herdr `
            -PeonDir $fixture.PeonDir -EnablePeon $true | Should -BeTrue
        [IO.File]::ReadAllBytes($fixture.Config) | Should -Be $first
        @(Get-ChildItem -LiteralPath (Split-Path $fixture.Hooks) -Filter 'hooks.json.pre-inline-*.bak').Count | Should -Be 1
    }

    It 'fails closed when hooks.json contains foreign behavior' {
        $fixture = New-CodexHookFixture
        "[features]`nhooks = true`n[tui]`n" | Set-Content -LiteralPath $fixture.Config
        @{ hooks = @{ PreToolUse = @(@{ hooks = @(@{ type = 'command'; command = 'foreign.exe' }) }) } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture.Hooks
        $before = [IO.File]::ReadAllBytes($fixture.Config)

        Sync-CodexHooks -ConfigPath $fixture.Config -HooksPath $fixture.Hooks -HerdrScript $fixture.Herdr `
            -PeonDir $fixture.PeonDir -EnablePeon $true | Should -BeFalse

        [IO.File]::ReadAllBytes($fixture.Config) | Should -Be $before
        Test-Path -LiteralPath $fixture.Hooks | Should -BeTrue
    }

    It 'restores both files when generated TOML validation fails' {
        $fixture = New-CodexHookFixture
        "[features]`nhooks = true`n[tui]`n" | Set-Content -LiteralPath $fixture.Config
        @{ hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = "powershell -File $($fixture.Herdr) session" }) }) } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture.Hooks
        $configBefore = [IO.File]::ReadAllBytes($fixture.Config)
        $hooksBefore = [IO.File]::ReadAllBytes($fixture.Hooks)
        Mock Test-CodexHooksToml { $false }

        Sync-CodexHooks -ConfigPath $fixture.Config -HooksPath $fixture.Hooks -HerdrScript $fixture.Herdr `
            -PeonDir $fixture.PeonDir -EnablePeon $true | Should -BeFalse

        [IO.File]::ReadAllBytes($fixture.Config) | Should -Be $configBefore
        [IO.File]::ReadAllBytes($fixture.Hooks) | Should -Be $hooksBefore
    }

    It 'renders only for coding-agent installs and follows the peon sound tier' {
        $enabled = & chezmoi execute-template --source $RepoRoot --override-data '{"installCodingAgents":true,"agentSounds":"peon"}' --file $TemplatePath | Out-String
        $disabled = & chezmoi execute-template --source $RepoRoot --override-data '{"installCodingAgents":false,"agentSounds":"none"}' --file $TemplatePath | Out-String
        $LASTEXITCODE | Should -Be 0

        $enabled | Should -Match 'Sync-CodexHooks'
        $enabled | Should -Match '\$enablePeon = \$true'
        $disabled | Should -Not -Match 'Sync-CodexHooks'

        $rendered = Get-Content -Raw -LiteralPath $TemplatePath |
            & chezmoi execute-template --source $RepoRoot --override-data '{"installCodingAgents":true,"agentSounds":"peon"}'
        $LASTEXITCODE | Should -Be 0
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseInput(($rendered -join "`n"), [ref]$null, [ref]$parseErrors) | Out-Null
        $parseErrors | Should -BeNullOrEmpty
    }
}
