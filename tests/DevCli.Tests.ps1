#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $PackageTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $HerdrConfig = Join-Path $RepoRoot '.chezmoitemplates' 'herdr' 'config.toml'
    $ToolsProfile = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '10_tools.ps1'
    $AliasesProfile = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '20_aliases.ps1'
    $Justfile = Join-Path $RepoRoot 'justfile'
    $QuickActions = Join-Path $RepoRoot 'dot_config' 'herdr' 'plugins' 'config' 'cloudmanic.herdr-plus' 'quick-actions'
}

Describe 'dev-cli Windows install and Herdr alignment' {
    BeforeAll {
        $script:package = Get-Content -Raw -LiteralPath $PackageTemplate
        $script:config = Get-Content -Raw -LiteralPath $HerdrConfig
        $script:tools = Get-Content -Raw -LiteralPath $ToolsProfile
        $script:aliases = Get-Content -Raw -LiteralPath $AliasesProfile
        $script:just = Get-Content -Raw -LiteralPath $Justfile
    }

    It 'installs official Windows releases and retains Go for Herdr Plus' {
        $package | Should -Match 'Install-WindowsCliRelease -Name dev-cli'
        $package | Should -Not -Match 'go install.*dev-cli'
        $package | Should -Match '(?s)\{\{ if \.installHerdr -\}\}.*Scoop-Install @\(''go''\)\s*Install-DevCli\s*Install-Herdr\s*Install-HerdrPlus'
    }

    It 'exposes the explicit binary-release upgrade recipe' {
        $just | Should -Match 'upgrade-dev:\s*\r?\n\s*pwsh -NoProfile -File ./scripts/upgrade-windows-cli.ps1 -Name dev-cli'
    }

    It 'exposes the owned binary as dev-cli and completes that name' {
        $aliases | Should -Match 'Set-Alias -Name dev-cli -Value \$devCliExe -Scope Global'
        $tools | Should -Match 'Import-CachedInit -Name ''dev-cli'' -Exe \$devCliExe'
        $tools | Should -Match '-CommandName ''dev-cli'''
    }

    It 'binds prefix+d to dev-cli and removes the redundant direct copy keys' {
        $config | Should -Match '(?s)key = "prefix\+d"\s*type = "pane"\s*command = "dev-cli"'
        $config | Should -Not -Match 'key = "prefix\+(?-i:P|D|V|S|ctrl\+d)"'
        $config | Should -Match 'key = "prefix\+p"'
        $config | Should -Match 'cloudmanic\.herdr-plus\.quick-actions-windows'
    }

    It 'ships all six non-interactive copy Quick Actions' {
        $copyFiles = @(Get-ChildItem -LiteralPath $QuickActions -Filter 'copy-*.toml*')
        $copyFiles.Count | Should -Be 6
        $copyFiles.Name | Should -Contain 'copy-pane-cwd.toml.tmpl'
        $copyFiles.Name | Should -Contain 'copy-space-dir.toml.tmpl'
    }
}

Describe 'shared Herdr workspace-root derivation' {
    BeforeAll {
        . (Join-Path $RepoRoot 'dot_config' 'herdr' '_common.ps1')
        function Invoke-HerdrJson {
            param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)
            if ($Argument[0] -eq 'tab') {
                return '{"result":{"tabs":[{"tab_id":"w1:t9","number":9},{"tab_id":"w1:t2","number":2}]}}' | ConvertFrom-Json
            }
            if ($Argument[0] -eq 'pane') {
                return '{"result":{"panes":[{"tab_id":"w1:t9","foreground_cwd":"C:\\late"},{"tab_id":"w1:t2","foreground_cwd":"C:\\root","cwd":"C:\\start"}]}}' | ConvertFrom-Json
            }
            $null
        }
    }

    It 'uses the oldest surviving tab and prefers its live cwd' {
        Resolve-HerdrSpaceRoot -WorkspaceId 'w1' | Should -BeExactly 'C:\root'
    }

    It 'is consumed by both the new-tab and clipboard helpers' {
        (Get-Content -Raw (Join-Path $RepoRoot 'dot_config' 'herdr' 'new-tab-at-space-root.ps1')) |
            Should -Match 'Resolve-HerdrSpaceRoot'
        (Get-Content -Raw (Join-Path $RepoRoot 'dot_config' 'herdr' 'pane-copy.ps1')) |
            Should -Match 'Resolve-HerdrSpaceRoot'
    }
}
