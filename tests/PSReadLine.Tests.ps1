#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot 'dot_config/powershell/profile.d/90_psreadline.ps1.tmpl'
}

Describe 'PSReadLine word-deletion bindings' {
    It 'renders and retains the intended bindings across scoped reloads with Vi enabled: <Enabled>' -TestCases @(
        @{ Enabled = $true; Mode = 'Vi' }
        @{ Enabled = $false; Mode = 'Windows' }
    ) {
        param($Enabled, $Mode)

        $data = @{ enableVimMode = $Enabled } | ConvertTo-Json -Compress
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $TemplatePath | Out-String
        $LASTEXITCODE | Should -Be 0
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty

        # Exercise the real interactive body even in redirected CI. The outer
        # redirection guard has its own test in PowerShellInitCache.Tests.ps1.
        $body = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] -and
                $_.Extent.Text.StartsWith('if (Get-Module -Name PSReadLine)')
        })
        $body | Should -HaveCount 1
        # Predictions require a VT console even with SilentlyContinue. Omit only
        # those two UI options; run every other statement in its rendered order.
        $statements = $body[0].Clauses[0].Item2.Statements | Where-Object {
            $_.Extent.Text -notmatch '^Set-PSReadLineOption -Prediction(Source|ViewStyle)\b'
        }
        $interactiveBody = ($statements | ForEach-Object { $_.Extent.Text }) -join "`n"
        $encodedBody = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($interactiveBody))

        # A disposable process avoids resetting the test runner's key tables.
        $probe = @'
$ErrorActionPreference = 'Stop'
Import-Module PSReadLine
Set-PSReadLineOption -EditMode __MODE__
$defaults = @(Get-PSReadLineKeyHandler -Chord 'Ctrl+w','Ctrl+Backspace' | Select-Object Key,Function)
$profileBody = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__BODY__'))
function Invoke-FixtureProfileReload {
    . ([scriptblock]::Create($profileBody))
}
$reloads = @(foreach ($iteration in 1..2) {
    Invoke-FixtureProfileReload
    [pscustomobject]@{
        Mode = (Get-PSReadLineOption).EditMode.ToString()
        Bindings = @(Get-PSReadLineKeyHandler -Chord 'Ctrl+w','Ctrl+Backspace' | Select-Object Key,Function)
    }
})
[pscustomobject]@{ Defaults = $defaults; Reloads = $reloads } | ConvertTo-Json -Depth 5 -Compress
'@.Replace('__MODE__', $Mode).Replace('__BODY__', $encodedBody)

        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $output = & $pwsh -NoProfile -NonInteractive -Command $probe
        $LASTEXITCODE | Should -Be 0
        $result = ($output -join "`n") | ConvertFrom-Json
        $result.Reloads | Should -HaveCount 2
        foreach ($reload in $result.Reloads) {
            $reload.Mode | Should -Be $Mode
            if ($Enabled) {
                $insertBinding = @($reload.Bindings | Where-Object Key -CEQ 'Ctrl+w')
                $insertBinding | Should -HaveCount 1
                $insertBinding[0].Function | Should -Be 'UnixWordRubout'
                $commandBinding = @($reload.Bindings | Where-Object Key -CEQ '<Ctrl+w>')
                $commandBinding | Should -HaveCount 1
                $commandBinding[0].Function | Should -Be 'BackwardDeleteWord'
            }
            foreach ($binding in $result.Defaults) {
                # Only the Vi Insert-mode Ctrl+w is intentionally overridden.
                if ($Enabled -and $binding.Key -ceq 'Ctrl+w') { continue }
                $actual = @($reload.Bindings | Where-Object Key -CEQ $binding.Key)
                $actual | Should -HaveCount 1
                $actual[0].Function | Should -Be $binding.Function
            }
        }
    }
}
