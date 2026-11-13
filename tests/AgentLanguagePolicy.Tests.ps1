#Requires -Version 7.4
#Requires -PSEdition Core
# Gate + content contract for dot_claude/rules/language-policy.md.tmpl
# (~/.claude/rules/language-policy.md). The rule renders ONLY when
# installCodingAgents and agentLanguagePolicy = zh-TW; every other combination,
# including a config written before the prompt existed, renders empty so
# chezmoi removes the target instead of failing on a missing key.

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Template = Join-Path $script:Repo 'dot_claude/rules/language-policy.md.tmpl'
    $script:Body = Join-Path $script:Repo '.chezmoitemplates/agent-language-policy.md'

    function Invoke-PolicyRender([string]$Data) {
        $config = Join-Path $TestDrive 'chezmoi.toml'
        [IO.File]::WriteAllText($config, "[data]`n$Data`n")
        $out = Get-Content -Raw $script:Template |
            chezmoi execute-template --source $script:Repo --config $config
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($out -join "`n") }
    }
}

Describe 'Agent language policy rule' {
    It 'renders the shared body when coding agents and zh-TW are selected' {
        $r = Invoke-PolicyRender "installCodingAgents = true`nagentLanguagePolicy = `"zh-TW`""
        $r.ExitCode | Should -Be 0
        $r.Text.Trim() | Should -BeExactly (Get-Content -Raw $script:Body).Trim()
    }

    It 'renders empty for <Name>' -ForEach @(
        @{ Name = 'policy none'; Data = "installCodingAgents = true`nagentLanguagePolicy = `"none`"" }
        @{ Name = 'coding agents off'; Data = "installCodingAgents = false`nagentLanguagePolicy = `"zh-TW`"" }
        @{ Name = 'a config predating the prompt'; Data = 'installCodingAgents = true' }
    ) {
        $r = Invoke-PolicyRender $Data
        $r.ExitCode | Should -Be 0
        $r.Text.Trim() | Should -BeNullOrEmpty
    }

    It 'covers chat, plan files, long-lived docs and thinking' {
        $body = Get-Content -Raw $script:Body
        foreach ($needle in '繁體中文', 'Plan-mode plan files', 'Long-lived artifacts', 'Internal reasoning / thinking') {
            $body | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'stays byte-identical to the Unix repo copy when checked out as a superproject sibling' {
        $unix = Join-Path $script:Repo '../dotfiles-unix/.chezmoitemplates/agent-language-policy.md'
        if (-not (Test-Path -LiteralPath $unix)) {
            Set-ItResult -Skipped -Because 'dotfiles-unix sibling not checked out'
            return
        }
        (Get-FileHash $script:Body).Hash | Should -Be (Get-FileHash $unix).Hash
    }
}
