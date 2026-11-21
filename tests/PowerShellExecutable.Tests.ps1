#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
    $script:Chezmoi = (Get-Command chezmoi -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $script:Config = Join-Path $TestDrive 'config.json'
    $script:State = Join-Path $TestDrive 'state.db'
    $script:Destination = Join-Path $TestDrive 'home'
    New-Item -ItemType Directory -Path $Destination | Out-Null

    function Invoke-ShellTemplate {
        param(
            [string]$Path,
            [AllowEmptyString()][string]$Executable = '',
            [switch]$AsToml
        )
        $data = @{
            installCodingAgents = $false
            installHerdr = $true
        }
        if ($Executable) { $data.powerShellExecutable = $Executable }
        @{data = $data} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Config
        $expression = '{{ includeTemplate "' + $Path.Replace('\', '/') + '" .'
        if ($AsToml) { $expression += ' | fromToml | toJson' }
        $expression += ' }}'
        $inputFile = Join-Path $TestDrive 'input.tmpl'
        [IO.File]::WriteAllText($inputFile, $expression)
        $result = & $Chezmoi execute-template --source $Repo --config $Config `
            --persistent-state $State --destination $Destination --file $inputFile 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw $result }
        if ($AsToml) { return ($result | ConvertFrom-Json) }
        $result
    }
}

Describe 'Explicit PowerShell executable' {
    It 'preserves the override across init and writes the matching interpreter' {
        $initConfig = Join-Path $TestDrive 'init.toml'
        $arguments = @('--source', $Repo, '--config', $initConfig,
            '--persistent-state', $State, '--destination', $Destination)
        & $Chezmoi init @arguments --no-tty --promptDefaults
        $LASTEXITCODE | Should -Be 0
        $content = Get-Content -LiteralPath $initConfig -Raw
        $content | Should -Match 'command = "pwsh"'
        $path = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $encoded = ConvertTo-Json -InputObject $path -Compress
        $content.Replace('powerShellExecutable = ""', "powerShellExecutable = $encoded") |
            Set-Content -LiteralPath $initConfig
        & $Chezmoi init @arguments --no-tty --promptDefaults
        $LASTEXITCODE | Should -Be 0
        $reinitialized = Get-Content -LiteralPath $initConfig -Raw
        $reinitialized | Should -Match ([regex]::Escape("command = $encoded"))
        $reinitialized | Should -Match ([regex]::Escape("powerShellExecutable = $encoded"))
    }

    It 'keeps PATH lookup when old chezmoi data has no override' {
        (Invoke-ShellTemplate -Path 'powershell-executable').Trim() | Should -BeExactly 'pwsh'
        $config = Invoke-ShellTemplate -Path 'herdr/config.toml' -AsToml
        $config.terminal.default_shell | Should -BeExactly 'pwsh'
        $edit = $config.keys.command | Where-Object key -EQ 'prefix+alt+e'
        $edit.command | Should -Match '^pwsh -NoProfile -File '
    }

    It 'uses the selected runtime in Alacritty rather than inherited Scoop PATH' {
        $path = 'C:\Users\Test User\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
        $config = Invoke-ShellTemplate -Path 'AppData/Roaming/alacritty/alacritty.toml.tmpl' -Executable $path -AsToml
        $config.terminal.shell.program | Should -BeExactly $path
        $config.terminal.shell.args | Should -Contain '-NoLogo'
    }

    It 'keeps the legacy Alacritty PATH default without an explicit runtime' {
        $config = Invoke-ShellTemplate -Path 'AppData/Roaming/alacritty/alacritty.toml.tmpl' -AsToml
        $config.terminal.shell.program | Should -BeExactly 'pwsh'
    }

    It 'preserves a path with spaces, apostrophes and Unicode through TOML' {
        $path = "C:\Users\O'Brien $([char]0x6E2C)\PowerShell\pwsh.exe"
        $config = Invoke-ShellTemplate -Path 'herdr/config.toml' -Executable $path -AsToml
        $config.terminal.default_shell | Should -BeExactly $path
        $commands = @($config.keys.command | Where-Object command -Match '-NoProfile -File')
        $commands.Count | Should -BeGreaterThan 5
        foreach ($command in $commands) {
            $command.command.StartsWith('"' + $path + '" -NoProfile -File "') | Should -BeTrue
        }
        $scratch = $config.keys.command | Where-Object key -CEQ 'prefix+`'
        $scratch.command | Should -BeExactly ('"' + $path + '"')
        $lazygit = $config.keys.command | Where-Object key -CEQ 'prefix+G'
        $alternate = $config.keys.command | Where-Object key -CEQ 'alt+g'
        $alternate.command | Should -BeExactly $lazygit.command
        $translator = $config.keys.command | Where-Object key -CEQ 'prefix+t'
        $translator.type | Should -BeExactly 'popup'
        $translator.command | Should -BeExactly 'translate'
    }

    It 'rejects unsafe or non-executable overrides: <Path>' -TestCases @(
        @{Path = 'pwsh -NoProfile'}
        @{Path = 'relative\pwsh.exe'}
        @{Path = 'C:\Windows\powershell.exe'}
        @{Path = 'C:\Tools%PATH%\pwsh.exe'}
        @{Path = 'C:\Tools!\pwsh.exe'}
        @{Path = "C:\Tools`n\pwsh.exe"}
        @{Path = 'C:\Tools"\pwsh.exe'}
    ) {
        param($Path)
        { Invoke-ShellTemplate -Path 'powershell-executable' -Executable $Path } |
            Should -Throw '*powerShellExecutable must be*'
    }

    It 'renders every quick action with the selected executable and retains plugin substitutions' {
        $root = Join-Path $Repo 'dot_config\herdr\plugins\config\cloudmanic.herdr-plus\quick-actions'
        $files = @(Get-ChildItem -LiteralPath $root -Filter '*.toml.tmpl')
        $files.Count | Should -BeGreaterThan 10
        $path = 'C:\Program Files\PowerShell\7\pwsh.exe'
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($Repo, $file.FullName)
            $action = Invoke-ShellTemplate -Path $relative -Executable $path -AsToml
            $action.command.StartsWith('"' + $path + '" -NoProfile ') | Should -BeTrue -Because $file.Name
            $standard = Invoke-ShellTemplate -Path $relative -AsToml
            $standard.command.StartsWith('pwsh -NoProfile ') | Should -BeTrue -Because $file.Name
            if ($file.Name -eq 'google-search.toml.tmpl') {
                $action.command | Should -Match '\{\{\.Value \| urlquery\}\}'
            }
            if ($file.Name -eq 'open-working-dir.toml.tmpl') {
                $action.command | Should -Match '\{\{\.WorkDir\}\}'
            }
        }
    }

    It 'places the selected runtime ahead of inherited shims without loading other profile fragments' {
        $path = Join-Path $PSHOME 'pwsh.exe'
        $rendered = Invoke-ShellTemplate -Path 'dot_config/powershell/profile.d/00_env.ps1.tmpl' -Executable $path
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        # Execute only the override block, not tool activations or other profile setup.
        $statements = @($ast.EndBlock.Statements)
        $assignment = $statements | Where-Object { $_.Extent.Text -like '$SelectedPowerShell =*' }
        $guard = $statements | Where-Object { $_.Extent.Text -like 'if (-not (Test-Path -LiteralPath $SelectedPowerShell*' }
        $assignment | Should -Not -BeNullOrEmpty
        $guard | Should -Not -BeNullOrEmpty
        . (Join-Path $Repo 'scripts\windows-path-precedence.ps1')
        $original = $env:PATH
        try {
            $env:PATH = 'C:\blocked\scoop\shims;' + $original
            & ([scriptblock]::Create($assignment.Extent.Text + "`n" + $guard.Extent.Text))
            ($env:PATH -split ';')[0] | Should -BeExactly $PSHOME
            (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source | Should -BeExactly $path
        } finally {
            $env:PATH = $original
        }
    }

    It 'uses the running host for nested helpers instead of PATH' {
        $run = Get-Content -LiteralPath (Join-Path $Repo 'dot_config\herdr\run-command.ps1') -Raw
        $run | Should -Match "& \(Join-Path \`$PSHOME 'pwsh\.exe'\) @pwshArgs"
        $translate = Get-Content -LiteralPath (Join-Path $Repo 'dot_config\herdr\pane-translate.ps1') -Raw
        $translate | Should -Match "Join-Path \`$PSHOME 'pwsh\.exe'"
    }

    It 'launches the rendered command through Windows cmd with a spaced script path' -Skip:(-not $IsWindows) {
        $path = Join-Path $PSHOME 'pwsh.exe'
        $config = Invoke-ShellTemplate -Path 'herdr/config.toml' -Executable $path -AsToml
        $edit = $config.keys.command | Where-Object key -EQ 'prefix+alt+e'
        $probe = Join-Path $TestDrive 'shell probe.ps1'
        "[Console]::WriteLine('shell-probe-ok')" | Set-Content -LiteralPath $probe
        $command = $edit.command -replace '-File ".*"$', ('-File "' + $probe + '"')
        $output = & $env:ComSpec /d /c $command
        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain 'shell-probe-ok'
    }
}
