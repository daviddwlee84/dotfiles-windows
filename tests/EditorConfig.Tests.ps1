#Requires -Version 7.4
#Requires -PSEdition Core

Describe 'Editor configuration' {
    BeforeAll {
        $script:Repo = Split-Path $PSScriptRoot -Parent
        $script:SavedXdg = $env:XDG_CONFIG_HOME
        $script:SavedEditor = $env:EDITOR
        $script:SavedVisual = $env:VISUAL
        $script:SavedPath = $env:PATH
        $script:Pwsh = (Get-Process -Id $PID).Path
        Import-Module (Join-Path $Repo 'dot_config/powershell/modules/EditorConfig/EditorConfig.psd1') -Force
    }

    BeforeEach {
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ' 中文 space')
        $null = New-Item -ItemType Directory (Join-Path $env:XDG_CONFIG_HOME 'dotfiles') -Force
        $env:EDITOR = 'dotfiles-editor'
        $env:VISUAL = 'dotfiles-editor'
        $env:EDITOR_TEST_LOG = Join-Path $TestDrive 'args.json'
        $env:EDITOR_TEST_CLOSED = Join-Path $TestDrive 'closed'
    }

    AfterAll {
        $env:XDG_CONFIG_HOME = $SavedXdg
        $env:EDITOR = $SavedEditor
        $env:VISUAL = $SavedVisual
        $env:PATH = $SavedPath
        Remove-Item Env:EDITOR_TEST_LOG, Env:EDITOR_TEST_CLOSED -ErrorAction SilentlyContinue
        Remove-Module EditorConfig -ErrorAction SilentlyContinue
    }

    Describe 'Editor preference and resolution' {
        It 'retains legacy nvim and excludes aliases from executable discovery' {
            InModuleScope EditorConfig {
                (Get-EditorPreference).Preset | Should -BeExactly 'nvim'
                function global:micro { throw 'must not execute' }
                try {
                    Mock Get-Command { $null } -ParameterFilter { $CommandType -eq 'Application' }
                    Find-EditorExecutable micro | Should -BeNullOrEmpty
                }
                finally { Remove-Item Function:micro }
            }
        }

        It 'persists a local choice, refuses missing programs and resets to init' {
            InModuleScope EditorConfig {
                Mock Find-EditorExecutable { if ($Name -in @('nvim', 'micro')) { '/fake/editor' } }
                Mock Show-EditorOverrides { }
                $paths = Get-EditorConfigPaths
                [IO.File]::WriteAllText($paths.Default, "nvim`n")
                Invoke-EditorConfig -CommandArguments @('use', 'micro') | Should -Be 0
                Invoke-EditorConfig -CommandArguments @('use', 'code') | Should -Be 127
                (Get-EditorPreference).Preset | Should -BeExactly 'micro'
                Invoke-EditorConfig -CommandArguments @('reset') | Should -Be 0
                (Get-EditorPreference).Preset | Should -BeExactly 'nvim'
            }
        }

        It 'rejects malformed preference instead of interpreting it' {
            [IO.File]::WriteAllText((Join-Path $env:XDG_CONFIG_HOME 'dotfiles/editor-choice'), 'Write-Host wrong')
            { Resolve-ConfiguredEditor } | Should -Throw '*Invalid preset*'
        }

        It 'uses micro then nano without sending non-vim users into a modal editor' {
            InModuleScope EditorConfig {
                [IO.File]::WriteAllText((Get-EditorConfigPaths).Default, 'code')
                Mock Find-EditorExecutable { if ($Name -in @('micro', 'nano', 'nvim')) { "/fake/$Name" } }
                (Resolve-ConfiguredEditor).Selected | Should -BeExactly 'micro'
                Mock Find-EditorExecutable { if ($Name -in @('nano', 'nvim')) { "/fake/$Name" } }
                (Resolve-ConfiguredEditor).Selected | Should -BeExactly 'nano'
                Mock Find-EditorExecutable { if ($Name -eq 'nvim') { '/fake/nvim' } }
                { Resolve-ConfiguredEditor } | Should -Throw '*No usable editor*'
            }
        }

        It 'uses vi only for a modal preference and attaches --wait to GUI presets' {
            InModuleScope EditorConfig {
                Mock Find-EditorExecutable { if ($Name -eq 'vi') { '/fake/vi' } }
                (Resolve-ConfiguredEditor).Selected | Should -BeExactly 'vi'
                [IO.File]::WriteAllText((Get-EditorConfigPaths).Default, 'cursor')
                Mock Find-EditorExecutable { if ($Name -eq 'cursor') { '/fake/cursor' } }
                (Resolve-ConfiguredEditor).Arguments | Should -Be @('--wait')
            }
        }
    }

    Describe 'Editor process and shell integration' {
        It 'runs the external cmd adapter and a waiting GUI batch preset on Windows' {
            if (-not $IsWindows) {
                Set-ItResult -Skipped -Because 'cmd.exe adapter requires Windows'
                return
            }
            $moduleRoot = Join-Path $env:XDG_CONFIG_HOME 'powershell/modules'
            $null = New-Item -ItemType Directory $moduleRoot -Force
            Copy-Item (Join-Path $Repo 'dot_config/powershell/modules/EditorConfig') $moduleRoot -Recurse
            $bin = Join-Path $env:XDG_CONFIG_HOME 'bin with space'
            $null = New-Item -ItemType Directory $bin -Force
            Copy-Item (Join-Path $Repo 'dot_local/bin/*') $bin
            $fixture = Join-Path $Repo 'tests/fixtures/editor-stub.ps1'
            $batch = "@echo off`r`n`"$Pwsh`" -NoProfile -File `"$fixture`" %*`r`nexit /b %ERRORLEVEL%`r`n"
            [IO.File]::WriteAllText((Join-Path $bin 'code.cmd'), $batch)
            [IO.File]::WriteAllText((Join-Path $env:XDG_CONFIG_HOME 'dotfiles/editor-default'), 'code')
            $beforePath = $env:PATH
            try {
                $env:PATH = $bin + [IO.Path]::PathSeparator + (Split-Path $Pwsh) + [IO.Path]::PathSeparator + $beforePath
                & (Join-Path $bin 'dotfiles-editor.cmd') '中文 file.md' 'a & b.txt'
                $LASTEXITCODE | Should -Be 23
                (Get-Content -Raw $env:EDITOR_TEST_LOG | ConvertFrom-Json) | Should -Be @('--wait', '中文 file.md', 'a & b.txt')
                Test-Path -LiteralPath $env:EDITOR_TEST_CLOSED | Should -BeTrue
            }
            finally { $env:PATH = $beforePath }
        }
        It 'recognizes Windows temp paths with directory boundaries' {
            if (-not (Get-Command nvim -CommandType Application -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'nvim is not installed'
                return
            }
            $saved = $env:NVIM_QUICK_EDIT_SOURCE
            try {
                $env:NVIM_QUICK_EDIT_SOURCE = Join-Path $Repo 'dot_config/nvim/lua/config/autocmds.lua'
                & nvim --clean --headless -u NONE -l (Join-Path $Repo 'tests/fixtures/nvim_quick_edit_probe.lua')
                $LASTEXITCODE | Should -Be 0
            }
            finally { $env:NVIM_QUICK_EDIT_SOURCE = $saved }
        }
        It 'preserves argv, cwd, wait and nonzero exit without resolving another editor' {
            Mock Find-EditorExecutable -ModuleName EditorConfig { $script:Pwsh }
            $files = @('中文 file.md', "apostrophe' & literal.txt")
            $arguments = @('-NoProfile', '-File', (Join-Path $Repo 'tests/fixtures/editor-stub.ps1')) + $files
            Invoke-ConfiguredEditor -EditorArguments $arguments | Should -Be 23
            (Get-Content -Raw $env:EDITOR_TEST_LOG | ConvertFrom-Json) | Should -Be $files
            [IO.File]::ReadAllText($env:EDITOR_TEST_CLOSED) | Should -Be (Get-Location).Path
            Should -Invoke Find-EditorExecutable -ModuleName EditorConfig -Times 1 -Exactly
        }

        It 'retains commands and completion after sourcing a fragment inside reload scope' {
            function Test-EditorReload {
                . (Join-Path $script:Repo 'dot_config/powershell/profile.d/09_editor.ps1')
            }
            Test-EditorReload
            editorcfg help
            $LASTEXITCODE | Should -Be 0
            (Get-Command dotfiles-editor).CommandType | Should -Be 'Function'
            $completion = TabExpansion2 'editorcfg use m' 15
            $completion.CompletionMatches.CompletionText | Should -Contain 'micro'
        }

        It 'renders old init data with nvim and keeps Yazi directory editing explicit' {
            $default = & chezmoi execute-template --source $Repo '{{ get . "preferredEditor" | default "nvim" }}'
            $LASTEXITCODE | Should -Be 0
            $default | Should -Be 'nvim'
            $yazi = Get-Content -Raw (Join-Path $Repo 'dot_config/yazi/yazi.toml')
            $yazi | Should -Match 'dotfiles-editor %\*'
            $yazi | Should -Match 'url = "\*/".*"nvim_dir"'
        }
    }
}
