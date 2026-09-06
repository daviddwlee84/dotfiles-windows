#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $PsReadLineTemplate = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '90_psreadline.ps1.tmpl'
}

Describe 'PowerShell profile host compatibility' {
    It 'enables predictions only when console output is interactive' {
        $profileText = Get-Content -Raw -LiteralPath $PsReadLineTemplate
        $profileText | Should -Match '(?s)if \(-not \[Console\]::IsOutputRedirected\) \{.*Set-PSReadLineOption -PredictionSource HistoryAndPlugin.*Set-PSReadLineOption -PredictionViewStyle ListView.*\}'
    }

    It 'does not deploy the root Pester result artifact into HOME' {
        $ignore = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot '.chezmoiignore')
        $ignore | Should -Match '(?m)^/testResults\.xml$'
    }
}
