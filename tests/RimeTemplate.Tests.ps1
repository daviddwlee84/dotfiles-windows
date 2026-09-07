#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Template = Join-Path $script:Repo '.chezmoiscripts/run_onchange_after_50_rime_deploy.ps1.tmpl'
}

Describe 'Rime deploy template runtime guards' {
    It 'renders one edition guard and parses when installInputMethod=<Enabled>' -ForEach @(
        @{ Enabled = 'true' }, @{ Enabled = 'false' }
    ) {
        $config = Join-Path $TestDrive 'chezmoi.toml'
        [IO.File]::WriteAllText($config, "[data]`ninstallInputMethod = $Enabled`n")
        $rendered = (Get-Content -Raw $script:Template | chezmoi execute-template --source $script:Repo --config $config) -join "`n"
        $LASTEXITCODE | Should -Be 0
        ([regex]::Matches($rendered, '(?m)^#Requires -PSEdition Core\r?$')).Count | Should -Be 1
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$parseErrors) | Out-Null
        @($parseErrors).Count | Should -Be 0
    }
}
