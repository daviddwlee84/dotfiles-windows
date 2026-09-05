#Requires -Version 7.4
#Requires -PSEdition Core
# Herdr custom commands use cmd /d /c, not terminal.default_shell. Normalize the
# child environment even if the long-lived server inherited Chocolatey-first PATH.
# Dot-source safe for unit tests; run only when invoked as an entry point.

function Start-HerdrLazyGitProcess {
    param([string]$Executable, [string]$WorkingDirectory)
    # Inherit the console directly. Capturing native stdout in a return-value
    # expression would redirect/buffer the TUI and break terminal detection.
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.WorkingDirectory = $WorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    try {
        $null = $process.Start()
        $process.WaitForExit()
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Invoke-HerdrLazyGit {
    [CmdletBinding()]
    param()
    $rc = 1
    $cwd = [string](Get-Location)
    $lazygitPath = '(not resolved)'
    $gitPath = '(not resolved)'
    try {
        . (Join-Path $PSScriptRoot '_common.ps1')
        $environment = Join-Path $PSScriptRoot '../powershell/profile.d/00_env.ps1'
        if (-not (Test-Path -LiteralPath $environment -PathType Leaf)) {
            throw "Managed environment missing: $environment. Run chezmoi apply for the shell environment."
        }
        # Only environment setup: no prompt, completions, local overrides, or daemons.
        . $environment
        $cwd = Resolve-HerdrCwd -PaneId (Resolve-HerdrPane)
        $lazygitPath = (Get-Command lazygit -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        Push-Location -LiteralPath $cwd -ErrorAction Stop
        try {
            $rc = Start-HerdrLazyGitProcess -Executable $lazygitPath -WorkingDirectory $cwd
        } finally { Pop-Location }
    } catch {
        Write-Host "LazyGit launch failed: $($_.Exception.Message)" -ForegroundColor Red
        $rc = 1
    }
    $hold = if ($env:HERDR_RUN_HOLD) { $env:HERDR_RUN_HOLD } else { 'fail' }
    if ($rc -ne 0 -or $hold -eq 'always') {
        Write-Host "cwd:     $cwd"
        Write-Host "lazygit: $lazygitPath"
        Write-Host "git:     $gitPath"
        Write-Host "[exit $rc] Use appsrc lazygit / appsrc git to inspect other installations."
    }
    if ($hold -eq 'always' -or ($hold -ne 'never' -and $rc -ne 0)) {
        if (-not [Console]::IsInputRedirected) { $null = Read-Host 'Press Enter to close' }
    }
    return [int]$rc
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-HerdrLazyGit) }
