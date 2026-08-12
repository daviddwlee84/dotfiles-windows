BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot 'dot_codex/modify_config.toml.ps1.tmpl'
    $RenderedPath = Join-Path $TestDrive 'modify_config.toml.ps1'
    $rendered = & chezmoi execute-template --source $RepoRoot --file $TemplatePath
    if ($LASTEXITCODE -ne 0) { throw 'failed to render Codex modifier' }
    [System.IO.File]::WriteAllText($RenderedPath, ($rendered -join "`n"), [System.Text.UTF8Encoding]::new($false))

    function Invoke-CodexModifier([string] $Live) {
        $stdout = $Live | & pwsh -NoProfile -NonInteractive -File $RenderedPath 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Codex modifier failed with exit $LASTEXITCODE" }
        $stdout -join "`n"
    }
}

Describe 'Codex config overlay' {
    It 'creates the native provider-neutral status line from empty input' {
        $result = Invoke-CodexModifier ''
        $result | Should -Match '(?s)status_line\s*=.*model-with-reasoning.*fast-mode.*git-branch.*context-remaining.*task-progress.*current-dir'
        $result | Should -Not -Match 'five-hour-limit|weekly-limit'
    }

    It 'preserves providers and nested TUI keymaps while enforcing status_line' {
        $live = @'
model = "custom-model"

[model_providers.copilot]
base_url = "http://localhost:4142"

[tui]
status_line = ["current-dir"]

[tui.keymap.editor]
insert_newline = ["ctrl-j"]
'@
        $result = Invoke-CodexModifier $live
        $result | Should -Match 'model = "custom-model"'
        $result | Should -Match 'base_url = "http://localhost:4142"'
        $result | Should -Match '(?s)status_line\s*=.*model-with-reasoning.*current-dir'
        $result | Should -Match '(?s)\[tui\.keymap\.editor\].*insert_newline'
    }

    It 'fails closed by preserving malformed live TOML' {
        $live = "model = [`n"
        Invoke-CodexModifier $live | Should -Be $live
    }
}
