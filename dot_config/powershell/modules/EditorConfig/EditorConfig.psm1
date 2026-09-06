#Requires -Version 7.4
#Requires -PSEdition Core
# Native backend; preference files contain one preset, never PowerShell code.

$script:Presets = @('nvim', 'micro', 'vim', 'nano', 'code', 'cursor')

function Get-EditorConfigPaths {
    $root = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    $directory = Join-Path $root 'dotfiles'
    [pscustomobject]@{
        Directory = $directory
        Default = Join-Path $directory 'editor-default'
        Local = Join-Path $directory 'editor-choice'
    }
}

function Get-EditorPreference {
    $paths = Get-EditorConfigPaths
    $source = 'legacy-default'
    $preset = 'nvim'
    if (Test-Path -LiteralPath $paths.Local) { $source = $paths.Local }
    elseif (Test-Path -LiteralPath $paths.Default) { $source = $paths.Default }
    if ($source -ne 'legacy-default') {
        $preset = [IO.File]::ReadAllText($source).TrimEnd("`r", "`n")
    }
    if ($script:Presets -cnotcontains $preset) {
        throw "Invalid preset in $source; use editorcfg use PRESET or reset"
    }
    [pscustomobject]@{ Preset = $preset; Source = $source }
}

function Find-EditorExecutable {
    param([string] $Name)
    # Exclude aliases/functions: a child process cannot call profile functions.
    Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
}

function Resolve-ConfiguredEditor {
    $preference = Get-EditorPreference
    $candidates = @($preference.Preset, 'micro', 'nano')
    if ($preference.Preset -in @('nvim', 'vim')) { $candidates += @('nvim', 'vim', 'vi') }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $executable = Find-EditorExecutable $candidate
        if ($executable) {
            return [pscustomobject]@{
                Preferred = $preference.Preset
                Source = $preference.Source
                Selected = $candidate
                Executable = $executable
                Arguments = @($(if ($candidate -in @('code', 'cursor')) { '--wait' }))
            }
        }
    }
    throw "No usable editor for $($preference.Preset); install micro with scoop install micro, then retry"
}

function Invoke-ConfiguredEditor {
    param([string[]] $EditorArguments = @())
    try { $editor = Resolve-ConfiguredEditor }
    catch { [Console]::Error.WriteLine("dotfiles-editor: $_"); return 127 }
    if ($editor.Selected -ne $editor.Preferred) {
        [Console]::Error.WriteLine("dotfiles-editor: $($editor.Preferred) unavailable; using $($editor.Selected) ($($editor.Executable))")
    }
    # Native argv, no expression evaluation. GUI presets use their blocking CLI.
    # Nonzero editor exits are returned; never launch a second editor afterwards.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.UseShellExecute = $false
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.FileName = $editor.Executable
    if ([IO.Path]::GetExtension($editor.Executable) -in @('.cmd', '.bat')) {
        # Batch launchers need an interpreter. A separate pwsh -File keeps the
        # native invocation out of this function's success-output pipeline.
        $start.FileName = (Get-Process -Id $PID).Path
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'invoke-editor-command.ps1'), $editor.Executable)) {
            $start.ArgumentList.Add($argument)
        }
    }
    foreach ($argument in @($editor.Arguments) + @($EditorArguments)) {
        $start.ArgumentList.Add($argument)
    }
    try {
        # Never redirect stdin/stdout/stderr: a TUI needs the actual console.
        $process = [Diagnostics.Process]::Start($start)
        try { $process.WaitForExit(); return $process.ExitCode }
        finally { $process.Dispose() }
    } catch {
        [Console]::Error.WriteLine("dotfiles-editor: failed to start $($editor.Executable): $_")
        return 126
    }
}

function Show-EditorOverrides {
    foreach ($name in @('EDITOR', 'VISUAL')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        Write-Host "${name}: $(if ($value) { $value } else { '(unset)' })"
        if ($value -ne 'dotfiles-editor') {
            Write-Host '  overrides/bypasses managed selection; reload the profile or check local.ps1'
        }
    }
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $PSNativeCommandUseErrorActionPreference = $false
        Write-Host "Git effective editor: $(& git var GIT_EDITOR 2>$null)"
        & git config --show-origin --get core.editor | Out-Host
        if ($env:GIT_EDITOR) { Write-Host "GIT_EDITOR override: $env:GIT_EDITOR" }
    }
}

function Invoke-EditorConfig {
    param([string[]] $CommandArguments = @())
    $action = if ($CommandArguments.Count) { $CommandArguments[0] } else { 'status' }
    $paths = Get-EditorConfigPaths
    try {
        switch -CaseSensitive ($action) {
            'use' {
                if ($CommandArguments.Count -ne 2 -or $script:Presets -cnotcontains $CommandArguments[1]) {
                    throw 'usage: editorcfg use {nvim|micro|vim|nano|code|cursor}'
                }
                $preset = $CommandArguments[1]
                if (-not (Find-EditorExecutable $preset)) {
                    [Console]::Error.WriteLine("editorcfg: $preset is not installed/on PATH; preference unchanged")
                    return 127
                }
                $null = [IO.Directory]::CreateDirectory($paths.Directory)
                $temporary = Join-Path $paths.Directory ('.editor-choice.' + [guid]::NewGuid().ToString('N'))
                try {
                    [IO.File]::WriteAllText($temporary, "$preset`n", [Text.UTF8Encoding]::new($false))
                    [IO.File]::Move($temporary, $paths.Local, $true)
                } finally {
                    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
                }
                Write-Host "Preferred editor: $preset (next managed launch; no apply needed)"
                Show-EditorOverrides
            }
            'reset' {
                if ($CommandArguments.Count -gt 1) { throw 'usage: editorcfg reset' }
                # Deletes only the dedicated override, never its parent directory.
                [IO.File]::Delete($paths.Local)
                Write-Host "Restored init preference: $((Get-EditorPreference).Preset)"
            }
            'list' {
                if ($CommandArguments.Count -gt 1) { throw 'usage: editorcfg list' }
                foreach ($preset in $script:Presets) {
                    $path = Find-EditorExecutable $preset
                    Write-Host "$preset`t$(if ($path) { $path } else { '(not installed)' })"
                }
            }
            { $_ -in @('status', 'doctor') } {
                if ($CommandArguments.Count -gt 1) { throw "usage: editorcfg $action" }
                $preference = Get-EditorPreference
                Write-Host "Preferred: $($preference.Preset)`nSource: $($preference.Source)"
                $result = 0
                try {
                    $editor = Resolve-ConfiguredEditor
                    Write-Host "Resolved: $($editor.Selected) ($($editor.Executable))"
                } catch { [Console]::Error.WriteLine("editorcfg: $_"); $result = 127 }
                Show-EditorOverrides
                if ($action -eq 'doctor') {
                    $launcher = Find-EditorExecutable 'dotfiles-editor'
                    if ($launcher) { Write-Host "Launcher: $launcher" }
                    else { [Console]::Error.WriteLine('Launcher missing on PATH; apply dotfiles and reload your profile'); $result = 127 }
                    Write-Host 'Availability only: GUI wait, terminal input and IME require an interactive smoke test.'
                }
                return $result
            }
            { $_ -in @('help', '--help', '-h') } {
                Write-Host 'editorcfg [status|list|doctor|use PRESET|reset]'
                Write-Host "Presets: $($script:Presets -join ' ')"
            }
            default { throw "Unknown command $action (see --help)" }
        }
        return 0
    } catch { [Console]::Error.WriteLine("editorcfg: $_"); return 2 }
}

Export-ModuleMember -Function Invoke-EditorConfig, Invoke-ConfiguredEditor, Resolve-ConfiguredEditor
