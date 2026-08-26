BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl'
    $RenderedPath = Join-Path $TestDrive 'run_onchange_after_25_claude_settings.ps1'
    $Utf8 = [Text.UTF8Encoding]::new($false, $true)
    $PwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    $renderData = @{ installCodingAgents = $true; agentSounds = 'notify' } | ConvertTo-Json -Compress
    $rendered = & chezmoi execute-template --source $RepoRoot --override-data $renderData --file $TemplatePath
    if ($LASTEXITCODE -ne 0) { throw 'failed to render Claude settings script' }
    [IO.File]::WriteAllText($RenderedPath, ($rendered -join "`n"), [Text.UTF8Encoding]::new($false))

    function ConvertTo-Hex {
        param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)
        [Convert]::ToHexString($Bytes)
    }

    function Assert-ExactBytes {
        param(
            [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Actual,
            [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Expected
        )
        (ConvertTo-Hex $Actual) | Should -BeExactly (ConvertTo-Hex $Expected)
    }

    function Read-StrictJson {
        param([Parameter(Mandatory)] [string] $Path)
        [byte[]] $bytes = [IO.File]::ReadAllBytes($Path)
        $text = $Utf8.GetString($bytes)
        $text | ConvertFrom-Json -AsHashtable
    }

    function Invoke-ClaudeSettingsScript {
        param(
            [Parameter(Mandatory)] [string] $ConfigDir,
            [string] $ScriptPath = $RenderedPath
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $PwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-NonInteractive')
        $startInfo.ArgumentList.Add('-File')
        $startInfo.ArgumentList.Add($ScriptPath)
        $startInfo.Environment['CLAUDE_CONFIG_DIR'] = $ConfigDir

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw 'failed to start rendered Claude settings script' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            [pscustomobject]@{
                Stdout   = $stdout.GetAwaiter().GetResult()
                Stderr   = $stderr.GetAwaiter().GetResult()
                ExitCode = $process.ExitCode
            }
        } finally {
            $process.Dispose()
        }
    }

    function New-TestConfigDir {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        $path
    }
}

Describe 'Claude settings and HUD overlays' {
    It 'creates settings and the Full 0.7.1 HUD policy from empty state' {
        $configDir = New-TestConfigDir
        $result = Invoke-ClaudeSettingsScript -ConfigDir $configDir

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        $settingsPath = Join-Path $configDir 'settings.json'
        $hudPath = Join-Path $configDir 'plugins/claude-hud/config.json'
        $settingsPath | Should -Exist
        $hudPath | Should -Exist

        $settings = Read-StrictJson $settingsPath
        $settings.enabledPlugins.'claude-hud@claude-hud' | Should -BeTrue
        $settings.statusLine.type | Should -BeExactly 'command'
        @($settings.hooks.Keys).Count | Should -Be 2
        $settings.hooks.Contains('Notification') | Should -BeTrue
        $settings.hooks.Contains('Stop') | Should -BeTrue
        $settings.hooks.Contains('SubagentStart') | Should -BeFalse
        $settings.hooks.Contains('SubagentStop') | Should -BeFalse

        $hud = Read-StrictJson $hudPath
        foreach ($key in @(
            'showModel', 'showProject', 'showAddedDirs', 'showContextBar',
            'showConfigCounts', 'showTokenBreakdown', 'showUsage', 'showResetLabel',
            'showCost', 'showDuration', 'showTools', 'showSkills', 'showMcp',
            'showAgents', 'showTodos', 'showSessionName', 'showSessionTokens',
            'showEffortLevel', 'showOutputStyle', 'showMemoryUsage',
            'showPromptCache', 'showClaudeCodeVersion', 'showCompactions', 'showAdvisor'
        )) {
            $hud.display[$key] | Should -BeTrue -Because "$key is part of Full 0.7.1"
        }
        $hud.gitStatus.enabled | Should -BeTrue
        $hud.gitStatus.showDirty | Should -BeTrue
        $hud.gitStatus.showAheadBehind | Should -BeFalse
        $hud.gitStatus.showFileStats | Should -BeFalse
        $hud.jjStatus.enabled | Should -BeTrue
        $hud.jjStatus.showDirty | Should -BeTrue
        $hud.jjStatus.showConflicts | Should -BeTrue
    }

    It 'reasserts owned HUD leaves while preserving advanced and unknown state' {
        $configDir = New-TestConfigDir
        $hudDir = Join-Path $configDir 'plugins/claude-hud'
        New-Item -ItemType Directory -Force -Path $hudDir | Out-Null
        $live = [ordered]@{
            language = 'zh-CN'
            lineLayout = 'compact'
            display = [ordered]@{
                showTools = $false
                showRoutedCost = $true
                showSpeed = $true
                showAuth = $true
                promptCacheTtlSeconds = 42
                customLine = 'keep me'
            }
            gitStatus = [ordered]@{ enabled = $false; showFileStats = $true; pushWarningThreshold = 7 }
            colors = [ordered]@{ model = 'brightRed'; custom = 123 }
            futurePluginState = [ordered]@{ nested = 'preserve-me' }
        }
        $live | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $hudDir 'config.json') -Encoding utf8

        $result = Invoke-ClaudeSettingsScript -ConfigDir $configDir
        $result.ExitCode | Should -Be 0
        $hud = Read-StrictJson (Join-Path $hudDir 'config.json')

        $hud.display.showTools | Should -BeTrue
        $hud.gitStatus.enabled | Should -BeTrue
        $hud.language | Should -BeExactly 'zh-CN'
        $hud.lineLayout | Should -BeExactly 'compact'
        $hud.display.showRoutedCost | Should -BeTrue
        $hud.display.showSpeed | Should -BeTrue
        $hud.display.showAuth | Should -BeTrue
        $hud.display.promptCacheTtlSeconds | Should -Be 42
        $hud.display.customLine | Should -BeExactly 'keep me'
        $hud.gitStatus.showFileStats | Should -BeFalse
        $hud.gitStatus.pushWarningThreshold | Should -Be 7
        $hud.colors.model | Should -BeExactly 'brightRed'
        $hud.colors.custom | Should -Be 123
        $hud.futurePluginState.nested | Should -BeExactly 'preserve-me'
    }

    It 'preserves foreign Claude settings and hooks while adding managed entries' {
        $configDir = New-TestConfigDir
        $foreignCommand = 'pwsh -NoProfile -File foreign.ps1'
        $live = [ordered]@{
            customTopLevel = 'preserve-me'
            permissions = [ordered]@{ allow = @('Read'); customPolicy = 'keep' }
            enabledPlugins = [ordered]@{ 'foreign@example' = $true }
            hooks = [ordered]@{
                Stop = @(@{ matcher = ''; hooks = @(@{ type = 'command'; command = $foreignCommand }) })
            }
        }
        $live | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $configDir 'settings.json') -Encoding utf8

        $result = Invoke-ClaudeSettingsScript -ConfigDir $configDir
        $result.ExitCode | Should -Be 0
        $settings = Read-StrictJson (Join-Path $configDir 'settings.json')

        $settings.customTopLevel | Should -BeExactly 'preserve-me'
        $settings.permissions.allow | Should -Contain 'Read'
        $settings.permissions.customPolicy | Should -BeExactly 'keep'
        $settings.enabledPlugins.'foreign@example' | Should -BeTrue
        @($settings.hooks.Stop.hooks.command) | Should -Contain $foreignCommand
        @($settings.hooks.Stop.hooks.command) | Should -Contain 'exec pwsh -NoProfile -File "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notify.ps1"'
    }

    It 'wires peon only to user-facing events' {
        $peonRenderedPath = Join-Path $TestDrive 'run_onchange_after_25_claude_settings_peon.ps1'
        $renderData = @{ installCodingAgents = $true; agentSounds = 'peon' } | ConvertTo-Json -Compress
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $renderData --file $TemplatePath
        $LASTEXITCODE | Should -Be 0
        [IO.File]::WriteAllText($peonRenderedPath, ($rendered -join "`n"), [Text.UTF8Encoding]::new($false))

        $configDir = New-TestConfigDir
        $result = Invoke-ClaudeSettingsScript -ConfigDir $configDir -ScriptPath $peonRenderedPath
        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        $settings = Read-StrictJson (Join-Path $configDir 'settings.json')

        @($settings.hooks.Keys).Count | Should -Be 8
        $settings.hooks.Contains('SubagentStart') | Should -BeFalse
        foreach ($eventName in @(
            'SessionStart', 'SessionEnd', 'Stop', 'Notification',
            'PermissionRequest', 'PreToolUse', 'PostToolUseFailure', 'PreCompact'
        )) {
            $settings.hooks.Contains($eventName) | Should -BeTrue
        }

        $foreignCommand = 'pwsh -NoProfile -File foreign-subagent.ps1'
        $settings.hooks['SubagentStart'] = @(
            @{ matcher = ''; hooks = @(@{ type = 'command'; command = 'powershell -File peon.ps1' }) }
            @{ matcher = ''; hooks = @(@{ type = 'command'; command = $foreignCommand }) }
        )
        $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $configDir 'settings.json') -Encoding utf8

        (Invoke-ClaudeSettingsScript -ConfigDir $configDir -ScriptPath $peonRenderedPath).ExitCode | Should -Be 0
        $settings = Read-StrictJson (Join-Path $configDir 'settings.json')
        @($settings.hooks.SubagentStart).Count | Should -Be 1
        @($settings.hooks.SubagentStart.hooks.command) | Should -Contain $foreignCommand
        @($settings.hooks.SubagentStart.hooks.command) | Should -Not -Match 'peon\.ps1'
    }

    It 'preserves Windows attributes when atomically replacing an existing file' {
        $configDir = New-TestConfigDir
        $settingsPath = Join-Path $configDir 'settings.json'
        '{"custom":"preserve"}' | Set-Content -LiteralPath $settingsPath -Encoding utf8
        [IO.File]::SetAttributes($settingsPath, [IO.FileAttributes]::Hidden)
        try {
            (Invoke-ClaudeSettingsScript -ConfigDir $configDir).ExitCode | Should -Be 0
            ([IO.File]::GetAttributes($settingsPath) -band [IO.FileAttributes]::Hidden) |
                Should -Be ([IO.FileAttributes]::Hidden)
            (Read-StrictJson $settingsPath).custom | Should -BeExactly 'preserve'
        } finally {
            [IO.File]::SetAttributes($settingsPath, [IO.FileAttributes]::Normal)
        }
    }

    It 'preserves a settings symlink and updates its resolved target' {
        $configDir = New-TestConfigDir
        $targetDir = New-TestConfigDir
        $targetPath = Join-Path $targetDir 'settings-target.json'
        $linkPath = Join-Path $configDir 'settings.json'
        '{"custom":"through-link"}' | Set-Content -LiteralPath $targetPath -Encoding utf8
        try {
            $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -ErrorAction Stop
        } catch {
            Set-ItResult -Skipped -Because 'creating symbolic links is unavailable'
            return
        }

        (Invoke-ClaudeSettingsScript -ConfigDir $configDir).ExitCode | Should -Be 0
        ((Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) |
            Should -Be ([IO.FileAttributes]::ReparsePoint)
        $settings = Read-StrictJson $targetPath
        $settings.custom | Should -BeExactly 'through-link'
        $settings.enabledPlugins.'claude-hud@claude-hud' | Should -BeTrue
    }

    It 'follows a multi-hop settings symlink without replacing either link' {
        $configDir = New-TestConfigDir
        $targetDir = New-TestConfigDir
        $targetPath = Join-Path $targetDir 'settings-target.json'
        $middlePath = Join-Path $targetDir 'settings-middle.json'
        $linkPath = Join-Path $configDir 'settings.json'
        '{"custom":"two-hops"}' | Set-Content -LiteralPath $targetPath -Encoding utf8
        try {
            $null = New-Item -ItemType SymbolicLink -Path $middlePath -Target $targetPath -ErrorAction Stop
            $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $middlePath -ErrorAction Stop
        } catch {
            Set-ItResult -Skipped -Because 'creating multi-hop symbolic links is unavailable'
            return
        }

        (Invoke-ClaudeSettingsScript -ConfigDir $configDir).ExitCode | Should -Be 0
        foreach ($path in $linkPath, $middlePath) {
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) |
                Should -Be ([IO.FileAttributes]::ReparsePoint)
        }
        $settings = Read-StrictJson $targetPath
        $settings.custom | Should -BeExactly 'two-hops'
        $settings.enabledPlugins.'claude-hud@claude-hud' | Should -BeTrue
    }

    It 'initializes the target of a dangling settings symlink' {
        $configDir = New-TestConfigDir
        $targetDir = Join-Path (New-TestConfigDir) 'not-created-yet'
        $targetPath = Join-Path $targetDir 'settings-target.json'
        $linkPath = Join-Path $configDir 'settings.json'
        try {
            $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -ErrorAction Stop
        } catch {
            Set-ItResult -Skipped -Because 'creating dangling symbolic links is unavailable'
            return
        }

        (Invoke-ClaudeSettingsScript -ConfigDir $configDir).ExitCode | Should -Be 0
        ((Get-Item -LiteralPath $linkPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) |
            Should -Be ([IO.FileAttributes]::ReparsePoint)
        $targetPath | Should -Exist
        (Read-StrictJson $targetPath).enabledPlugins.'claude-hud@claude-hud' | Should -BeTrue
    }

    It 'is byte-idempotent after the first successful merge' {
        $configDir = New-TestConfigDir
        (Invoke-ClaudeSettingsScript -ConfigDir $configDir).ExitCode | Should -Be 0
        $settingsPath = Join-Path $configDir 'settings.json'
        $hudPath = Join-Path $configDir 'plugins/claude-hud/config.json'
        [byte[]] $settingsFirst = [IO.File]::ReadAllBytes($settingsPath)
        [byte[]] $hudFirst = [IO.File]::ReadAllBytes($hudPath)

        $second = Invoke-ClaudeSettingsScript -ConfigDir $configDir
        $second.ExitCode | Should -Be 0
        Assert-ExactBytes -Actual ([IO.File]::ReadAllBytes($settingsPath)) -Expected $settingsFirst
        Assert-ExactBytes -Actual ([IO.File]::ReadAllBytes($hudPath)) -Expected $hudFirst
    }

    It 'writes BOM-free strict UTF-8 JSON with one final LF' {
        $configDir = New-TestConfigDir
        (Invoke-ClaudeSettingsScript -ConfigDir $configDir).ExitCode | Should -Be 0
        foreach ($path in @(
            (Join-Path $configDir 'settings.json'),
            (Join-Path $configDir 'plugins/claude-hud/config.json')
        )) {
            [byte[]] $bytes = [IO.File]::ReadAllBytes($path)
            $bytes.Length | Should -BeGreaterThan 3
            (ConvertTo-Hex $bytes[0..2]) | Should -Not -BeExactly 'EFBBBF'
            $bytes | Should -Not -Contain 0x0D
            $bytes[-1] | Should -Be 0x0A
            $bytes[-2] | Should -Not -Be 0x0A
            { $null = $Utf8.GetString($bytes) | ConvertFrom-Json -AsHashtable } | Should -Not -Throw
        }
    }

    It 'preserves malformed settings byte-for-byte while still updating HUD' {
        $configDir = New-TestConfigDir
        $settingsPath = Join-Path $configDir 'settings.json'
        [byte[]] $malformed = $Utf8.GetBytes("{`n  `"keep`": [`n")
        [IO.File]::WriteAllBytes($settingsPath, $malformed)

        $result = Invoke-ClaudeSettingsScript -ConfigDir $configDir
        $result.ExitCode | Should -Be 0
        ($result.Stdout + $result.Stderr) | Should -Match 'Claude settings overlay skipped; not overwriting'
        Assert-ExactBytes -Actual ([IO.File]::ReadAllBytes($settingsPath)) -Expected $malformed
        (Join-Path $configDir 'plugins/claude-hud/config.json') | Should -Exist
    }

    It 'preserves malformed HUD config byte-for-byte while still updating settings' {
        $configDir = New-TestConfigDir
        $hudDir = Join-Path $configDir 'plugins/claude-hud'
        New-Item -ItemType Directory -Force -Path $hudDir | Out-Null
        $hudPath = Join-Path $hudDir 'config.json'
        [byte[]] $malformed = $Utf8.GetBytes("{`n  `"keep`": [`n")
        [IO.File]::WriteAllBytes($hudPath, $malformed)

        $result = Invoke-ClaudeSettingsScript -ConfigDir $configDir
        $result.ExitCode | Should -Be 0
        ($result.Stdout + $result.Stderr) | Should -Match 'claude-hud overlay skipped; not overwriting'
        Assert-ExactBytes -Actual ([IO.File]::ReadAllBytes($hudPath)) -Expected $malformed
        (Join-Path $configDir 'settings.json') | Should -Exist
    }

    It 'keeps the status line silent when no plugin cache or controlling TTY exists' {
        $bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $bash) { Set-ItResult -Skipped -Because 'Git Bash is unavailable' }
        $configDir = New-TestConfigDir
        $settingsOverlayPath = Join-Path $RepoRoot 'claude/settings-overlay.json'
        $command = (Get-Content -Raw $settingsOverlayPath | ConvertFrom-Json).statusLine.command
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $bash.Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-lc')
        $startInfo.ArgumentList.Add($command)
        $startInfo.Environment['CLAUDE_CONFIG_DIR'] = $configDir
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw 'failed to start Git Bash' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0
            $stdout.GetAwaiter().GetResult() | Should -BeNullOrEmpty
            $stderr.GetAwaiter().GetResult() | Should -BeNullOrEmpty
        } finally {
            $process.Dispose()
        }
    }
}
