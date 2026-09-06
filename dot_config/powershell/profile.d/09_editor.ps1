#Requires -Version 7.4
#Requires -PSEdition Core
# PATH is initialized in 00_env. local.ps1 still runs last and can override.
$env:EDITOR = 'dotfiles-editor'
$env:VISUAL = 'dotfiles-editor'
Import-Module (Join-Path $PSScriptRoot '../modules/EditorConfig/EditorConfig.psd1') -Global

function global:editorcfg {
    $global:LASTEXITCODE = Invoke-EditorConfig -CommandArguments $args
}

function global:dotfiles-editor {
    $global:LASTEXITCODE = Invoke-ConfiguredEditor -EditorArguments $args
}

Register-ArgumentCompleter -Native -CommandName editorcfg, editorcfg.cmd -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $null = $cursorPosition
    $choices = if ($commandAst.CommandElements.Count -ge 2 -and $commandAst.CommandElements[1].Extent.Text -eq 'use') {
        @('nvim', 'micro', 'vim', 'nano', 'code', 'cursor')
    } else { @('status', 'list', 'doctor', 'use', 'reset') }
    $choices | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
