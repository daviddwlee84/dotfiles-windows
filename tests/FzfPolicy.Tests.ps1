#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot

    function Get-PolicyAst([string]$Source) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $Source, [ref]$tokens, [ref]$parseErrors
        )
        if ($parseErrors.Count) { throw "Policy source did not parse: $($parseErrors[0].Message)" }
        $ast
    }

    function Get-PolicyBlock($Ast, [string]$Match) {
        $blocks = @($Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text -match $Match
        }, $true))
        if ($blocks.Count -ne 1) { throw "Expected one policy block matching $Match; got $($blocks.Count)" }
        [scriptblock]::Create($blocks[0].Extent.Text)
    }

    $tools = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'dot_config/powershell/profile.d/10_tools.ps1')
    $script:ProfilePolicy = Get-PolicyBlock (Get-PolicyAst $tools) '(?s)^if .*DOTFILES_DISABLE_FZF.*Import-Module PSFzf'

    $template = Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl'
    $rendered = & chezmoi execute-template --source $RepoRoot --override-data '{"installClink":true}' --file $template
    if ($LASTEXITCODE -ne 0) { throw 'Failed to render package installer' }
    $installer = Get-PolicyAst ($rendered -join "`n")
    $script:PackagePolicy = Get-PolicyBlock $installer '(?s)^if \(\$fzfEnabled\).*Scoop-Install @\(''fzf''\)'
    $script:ModulePolicy = Get-PolicyBlock $installer '(?s)^if \(\$fzfEnabled -and.*Install-Module PSFzf'
    $script:ClinkDownloadPolicy = Get-PolicyBlock $installer '(?s)^if \(\$fzfEnabled\).*clinkPlugins\[''fzf.lua''\]'
    $script:ClinkBindingPolicy = Get-PolicyBlock $installer '(?s)^if \(\$fzfEnabled\).*clink set fzf.default_bindings'
    $initializers = @($installer.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$fzfEnabled'
    })
    if ($initializers.Count -ne 1) { throw 'Expected one fzf policy initializer' }
    $script:PolicyInitializer = [scriptblock]::Create($initializers[0].Extent.Text)
    $script:CorePackages = @($installer.EndBlock.Statements | Where-Object {
        $_.Extent.Text -match '^Scoop-Install @\(\s*''glab'','
    })

    $readLineTemplate = Join-Path $RepoRoot 'dot_config/powershell/profile.d/90_psreadline.ps1.tmpl'
    $readLineRendered = & chezmoi execute-template --source $RepoRoot --file $readLineTemplate
    if ($LASTEXITCODE -ne 0) { throw 'Failed to render PSReadLine profile' }
    $script:KeyBindingPolicy = Get-PolicyBlock (Get-PolicyAst ($readLineRendered -join "`n")) '(?s)^if \(\(\$env:DOTFILES_DISABLE_FZF.*Set-PsFzfOption'

    function Info($Message) {}
    function Scoop-Install([string[]]$Apps) {}
    function Install-Module {
        [CmdletBinding()]
        param([string]$Name, [string]$Scope, [switch]$Force, [switch]$AcceptLicense)
    }
    function Set-PsFzfOption($PSReadlineChordProvider, $PSReadlineChordReverseHistory) {}
    function clink { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
}

Describe 'fzf opt-out policy' {
    BeforeEach {
        $script:PreviousFlag = $env:DOTFILES_DISABLE_FZF
        $script:PreviousOptions = $env:FZF_DEFAULT_OPTS
        $script:PreviousCommand = $env:FZF_DEFAULT_COMMAND
        Mock Info {}
        Mock Scoop-Install {}
        Mock Import-Module {} -ParameterFilter { $Name -eq 'PSFzf' }
        Mock Install-Module {}
        Mock Get-Command { [pscustomobject]@{ Source = 'fixture' } } -ParameterFilter { $Name -in @('fzf', 'fd') }
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'PSFzf' }
        Mock Set-PsFzfOption {}
        Mock clink {}
    }

    AfterEach {
        $env:DOTFILES_DISABLE_FZF = $script:PreviousFlag
        $env:FZF_DEFAULT_OPTS = $script:PreviousOptions
        $env:FZF_DEFAULT_COMMAND = $script:PreviousCommand
    }

    It 'does not probe or import fzf integration when disabled' {
        $env:DOTFILES_DISABLE_FZF = '1'

        & $script:ProfilePolicy

        Should -Invoke Get-Command -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly
    }

    It 'preserves PSFzf initialization when enabled' {
        $env:DOTFILES_DISABLE_FZF = '0'

        & $script:ProfilePolicy

        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'PSFzf' }
        $env:FZF_DEFAULT_OPTS | Should -Be '--height 40% --layout=reverse --border'
    }

    It 'skips both package installers when disabled' {
        $env:DOTFILES_DISABLE_FZF = '1'
        . $script:PolicyInitializer

        & $script:PackagePolicy
        & $script:ModulePolicy

        Should -Invoke Scoop-Install -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Get-Module -Times 0 -Exactly
    }

    It 'installs fzf and PSFzf when enabled' {
        $env:DOTFILES_DISABLE_FZF = '0'
        . $script:PolicyInitializer

        & $script:PackagePolicy
        & $script:ModulePolicy

        Should -Invoke Scoop-Install -Times 1 -Exactly -ParameterFilter { $Apps.Count -eq 1 -and $Apps[0] -eq 'fzf' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'PSFzf' }
    }

    It 'keeps fzf out of the unconditional package array' {
        $script:CorePackages | Should -HaveCount 1
        $script:CorePackages[0].Extent.Text | Should -Not -Match "'fzf'"
    }

    It 'does not bind an already-loaded PSFzf module when disabled' {
        $env:DOTFILES_DISABLE_FZF = '1'
        Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }

        & $script:KeyBindingPolicy

        Should -Invoke Set-PsFzfOption -Times 0 -Exactly
    }

    It 'preserves PSFzf key bindings when enabled' {
        $env:DOTFILES_DISABLE_FZF = '0'
        Mock Get-Module { [pscustomobject]@{ Name = 'PSFzf' } } -ParameterFilter { $Name -eq 'PSFzf' }

        & $script:KeyBindingPolicy

        Should -Invoke Set-PsFzfOption -Times 1 -Exactly -ParameterFilter {
            $PSReadlineChordProvider -eq 'Ctrl+t' -and $PSReadlineChordReverseHistory -eq 'Ctrl+r'
        }
    }

    It 'skips the Clink fzf download and bindings when disabled' {
        $fzfEnabled = $false
        $clinkPlugins = @{ 'zoxide.lua' = 'fixture' }

        & $script:ClinkDownloadPolicy
        & $script:ClinkBindingPolicy

        $clinkPlugins.ContainsKey('fzf.lua') | Should -BeFalse
        Should -Invoke clink -Times 0 -Exactly
    }

    It 'preserves the Clink fzf bridge and bindings by default' {
        $fzfEnabled = $true
        $clinkPlugins = @{ 'zoxide.lua' = 'fixture' }

        & $script:ClinkDownloadPolicy
        & $script:ClinkBindingPolicy

        $clinkPlugins.ContainsKey('fzf.lua') | Should -BeTrue
        Should -Invoke clink -Times 1 -Exactly
    }

    It 'reads the persisted user preference when the process has no override' {
        Remove-Item Env:DOTFILES_DISABLE_FZF -ErrorAction SilentlyContinue
        $expectedEnabled = [Environment]::GetEnvironmentVariable('DOTFILES_DISABLE_FZF', 'User') -ne '1'
        . $script:PolicyInitializer

        $fzfEnabled | Should -Be $expectedEnabled
        & $script:ProfilePolicy
        & $script:KeyBindingPolicy

        Should -Invoke Import-Module -Times ([int]$expectedEnabled) -Exactly -ParameterFilter { $Name -eq 'PSFzf' }
        Should -Invoke Set-PsFzfOption -Times 0 -Exactly
    }
}
