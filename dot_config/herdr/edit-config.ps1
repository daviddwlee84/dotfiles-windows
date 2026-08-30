#Requires -Version 7
# ~/.config/herdr/edit-config.ps1
# Source: dot_config/herdr/edit-config.ps1 (managed by chezmoi)
#
# Edit the active Herdr runtime config directly, validate that exact file, then
# reload the current Herdr server. Bound to prefix+alt+e as a temporary pane.
#
# $env:EDITOR is one blocking executable/wrapper path, not a command line. Put
# arguments such as `code --wait` in a wrapper and point EDITOR at that wrapper.
# When EDITOR is unset, fallbacks are nvim, then explicitly waited notepad.exe.

. (Join-Path $PSScriptRoot '_common.ps1')

function Get-HerdrConfigPathState {
    $present = Test-Path -LiteralPath 'Env:HERDR_CONFIG_PATH'
    [pscustomobject]@{
        Present = $present
        Value   = if ($present) { [string](Get-Item -LiteralPath 'Env:HERDR_CONFIG_PATH').Value } else { $null }
    }
}

function Set-HerdrConfigPathForValidation {
    param([Parameter(Mandatory)] [string] $Path)
    Set-Item -LiteralPath 'Env:HERDR_CONFIG_PATH' -Value $Path
}

function Restore-HerdrConfigPathState {
    param([Parameter(Mandatory)] [psobject] $State)
    if ($State.Present) {
        # Set-Item (rather than `$env:... =`) preserves an empty value on pwsh
        # versions whose environment provider supports empty-valued variables.
        Set-Item -LiteralPath 'Env:HERDR_CONFIG_PATH' -Value ([string]$State.Value)
    } else {
        Remove-Item -LiteralPath 'Env:HERDR_CONFIG_PATH' -ErrorAction SilentlyContinue
    }
}

function Get-HerdrDefaultConfigPath {
    Join-Path $HOME '.config/herdr/config.toml'
}

function Resolve-HerdrConfigTarget {
    param([Parameter(Mandatory)] [psobject] $State)

    $requested = if ($State.Present -and -not [string]::IsNullOrWhiteSpace([string]$State.Value)) {
        [string]$State.Value
    } else {
        Get-HerdrDefaultConfigPath
    }

    try {
        $item = Get-Item -LiteralPath $requested -Force -ErrorAction Stop
    } catch {
        throw "runtime config target does not exist: $requested"
    }

    if ($item.PSIsContainer -or $item -isnot [IO.FileInfo]) {
        throw "runtime config target is not a regular file: $requested"
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LinkType) {
        throw "runtime config target must not be a reparse point: $requested"
    }

    $item.FullName
}

function Find-HerdrConfigExecutable {
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Resolve-HerdrConfigEditor {
    if (-not [string]::IsNullOrWhiteSpace($env:EDITOR)) {
        $configured = Find-HerdrConfigExecutable -Name $env:EDITOR
        if (-not $configured) {
            throw "EDITOR must name one blocking executable or wrapper path; use a wrapper for arguments such as 'code --wait': $env:EDITOR"
        }
        return [pscustomobject]@{
            Command     = $configured.Source
            WaitForExit = $false
        }
    }

    $nvim = Find-HerdrConfigExecutable -Name 'nvim'
    if ($nvim) {
        return [pscustomobject]@{
            Command     = $nvim.Source
            WaitForExit = $false
        }
    }

    $notepad = Find-HerdrConfigExecutable -Name 'notepad.exe'
    if ($notepad) {
        return [pscustomobject]@{
            Command     = $notepad.Source
            WaitForExit = $true
        }
    }

    $null
}

function Test-HerdrConfigEditInteractive {
    try {
        [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    } catch {
        $false
    }
}

function New-HerdrConfigSiblingPath {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [ValidateSet('backup', 'invalid')] [string] $Kind
    )

    $directory = [IO.Path]::GetDirectoryName($Target)
    $leaf = [IO.Path]::GetFileName($Target)
    do {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
        $suffix = [Guid]::NewGuid().ToString('N')
        $path = Join-Path $directory "$leaf.$Kind-$stamp-$suffix"
    } while (Test-Path -LiteralPath $path)
    $path
}

function Get-HerdrConfigMetadata {
    param([Parameter(Mandatory)] [string] $Path)

    $unixMode = $null
    $acl = $null
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    } else {
        $unixMode = [IO.File]::GetUnixFileMode($Path)
    }

    [pscustomobject]@{
        Attributes = [IO.File]::GetAttributes($Path)
        UnixMode   = $unixMode
        Acl        = $acl
    }
}

function Set-HerdrConfigMetadata {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [psobject] $Metadata
    )

    if ($IsWindows -and $null -ne $Metadata.Acl) {
        Set-Acl -LiteralPath $Path -AclObject $Metadata.Acl -ErrorAction Stop
    }
    if (-not $IsWindows -and $null -ne $Metadata.UnixMode) {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]$Metadata.UnixMode)
    }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]$Metadata.Attributes)
}

function Remove-HerdrConfigFile {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal) } catch { $null = $_ }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function New-HerdrConfigBackup {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [psobject] $Metadata
    )

    $backup = New-HerdrConfigSiblingPath -Target $Target -Kind backup
    try {
        [IO.File]::Copy($Target, $backup, $false)
        Set-HerdrConfigMetadata -Path $backup -Metadata $Metadata
    } catch {
        try { Remove-HerdrConfigFile -Path $backup } catch { $null = $_ }
        throw
    }
    $backup
}

function Protect-HerdrInvalidCandidate {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not $IsWindows) {
        $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        [IO.File]::SetUnixFileMode($Path, $mode)
        return
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $null = $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Invoke-HerdrConfigAtomicReplace {
    param(
        [Parameter(Mandatory)] [string] $Backup,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $Candidate
    )
    if ([IO.File]::Exists($Target)) {
        # All three paths are siblings, so File.Replace is one same-volume atomic
        # operation: backup -> active target, edited target -> invalid candidate.
        [IO.File]::Replace($Backup, $Target, $Candidate, $true)
        return $true
    }

    # An editor can delete the target before exiting non-zero. There are no edited
    # bytes to preserve, but restoring the same-directory backup still avoids a
    # missing active config.
    [IO.File]::Move($Backup, $Target)
    $false
}

function Restore-HerdrConfigBackup {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $Backup,
        [Parameter(Mandatory)] [string] $Candidate,
        [Parameter(Mandatory)] [psobject] $Metadata
    )

    $candidateCreated = Invoke-HerdrConfigAtomicReplace -Backup $Backup -Target $Target -Candidate $Candidate

    $recoveryErrors = [Collections.Generic.List[string]]::new()
    try { Set-HerdrConfigMetadata -Path $Target -Metadata $Metadata } catch {
        $recoveryErrors.Add("could not restore target metadata: $_")
    }
    if ($candidateCreated) {
        try { Protect-HerdrInvalidCandidate -Path $Candidate } catch {
            $recoveryErrors.Add("could not restrict invalid candidate: $_")
        }
    }
    if ($recoveryErrors.Count -gt 0) {
        throw ($recoveryErrors -join ' | ')
    }
    [bool]$candidateCreated
}

function Start-HerdrConfigEditor {
    param(
        [Parameter(Mandatory)] [psobject] $Editor,
        [Parameter(Mandatory)] [string] $Target
    )

    try {
        if ($Editor.WaitForExit) {
            # Start-Process joins ArgumentList into one command line. Quote the
            # single file argument so Windows paths containing spaces stay intact.
            $quotedTarget = '"{0}"' -f $Target
            $process = Start-Process -FilePath $Editor.Command -ArgumentList $quotedTarget `
                -Wait -PassThru
            return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Detail = [string]$Editor.Command }
        }

        # Keep wrapper/editor diagnostics visible in the pane without allowing
        # pipeline output to contaminate this function's structured result.
        & $Editor.Command $Target | Out-Host
        return [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Detail = [string]$Editor.Command }
    } catch {
        [pscustomobject]@{ ExitCode = 1; Detail = [string]$_ }
    }
}

function Get-HerdrConfigEditDetail {
    param([psobject] $Stream)
    (@($Stream.Err, $Stream.Out) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' | '
}

function Invoke-HerdrConfigCommand {
    param([Parameter(Mandatory)] [string[]] $Argument)

    try {
        $raw = @(& herdr @Argument 2>&1)
        $exitCode = [int]$LASTEXITCODE
        $stream = Split-HerdrStream $raw
        [pscustomobject]@{
            ExitCode = $exitCode
            Detail   = Get-HerdrConfigEditDetail $stream
            Stream   = $stream
        }
    } catch {
        [pscustomobject]@{ ExitCode = 127; Detail = [string]$_; Stream = $null }
    }
}

function Invoke-HerdrConfigCheck {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [psobject] $OriginalState
    )

    $result = $null
    $restoreError = $null
    $overridden = $false
    try {
        Set-HerdrConfigPathForValidation -Path $Target
        $overridden = $true
        $result = Invoke-HerdrConfigCommand -Argument @('config', 'check')
    } catch {
        $result = [pscustomobject]@{ ExitCode = 1; Detail = "could not set HERDR_CONFIG_PATH: $_"; Stream = $null }
    } finally {
        if ($overridden) {
            try { Restore-HerdrConfigPathState -State $OriginalState } catch { $restoreError = [string]$_ }
        }
    }

    if ($restoreError) {
        return [pscustomobject]@{
            ExitCode = 1
            Detail   = "could not restore HERDR_CONFIG_PATH: $restoreError"
            Stream   = $null
        }
    }
    $result
}

function Show-HerdrConfigEditFailure {
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [int] $ExitCode,
        [string] $Detail,
        [string] $Target,
        [string] $Candidate,
        [string] $Backup,
        [switch] $NoHold
    )

    $message = "edit-config: $Phase failed (exit $ExitCode)"
    if ($Detail) { $message += ": $Detail" }
    Show-HerdrNotice $message 0
    if ($Target) { Show-HerdrNotice "  target: $Target" 0 }
    if ($Candidate) { Show-HerdrNotice "  invalid candidate: $Candidate" 0 }
    if ($Backup) { Show-HerdrNotice "  backup: $Backup" 0 }

    if (-not $NoHold -and (Test-HerdrConfigEditInteractive)) {
        Write-Host ''
        Write-Host "[exit $ExitCode] press Enter to close..." -NoNewline
        $null = Read-Host
    }
    $ExitCode
}

function Invoke-HerdrConfigRollback {
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [int] $ExitCode,
        [string] $Detail,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $Backup,
        [Parameter(Mandatory)] [psobject] $Metadata,
        [switch] $NoHold
    )

    $candidate = $null
    try {
        $candidate = New-HerdrConfigSiblingPath -Target $Target -Kind invalid
        $candidateCreated = Restore-HerdrConfigBackup -Target $Target -Backup $Backup `
            -Candidate $candidate -Metadata $Metadata
        if (-not $candidateCreated) { $candidate = $null }
    } catch {
        $rollbackDetail = if ($Detail) { "$Detail | rollback failed: $_" } else { "rollback failed: $_" }
        return (Show-HerdrConfigEditFailure -Phase $Phase -ExitCode 74 -Detail $rollbackDetail `
                -Target $Target -Candidate $candidate -Backup $Backup -NoHold:$NoHold)
    }

    Show-HerdrConfigEditFailure -Phase $Phase -ExitCode $ExitCode -Detail $Detail `
        -Target $Target -Candidate $candidate -NoHold:$NoHold
}

function Remove-HerdrConfigBackup {
    param([Parameter(Mandatory)] [string] $Path)
    Remove-HerdrConfigFile -Path $Path
}

function Invoke-HerdrConfigEdit {
    param([switch] $NoHold)

    $configState = Get-HerdrConfigPathState
    try {
        $target = Resolve-HerdrConfigTarget -State $configState
    } catch {
        return (Show-HerdrConfigEditFailure -Phase 'target preflight' -ExitCode 66 `
                -Detail ([string]$_) -NoHold:$NoHold)
    }

    try {
        $editor = Resolve-HerdrConfigEditor
    } catch {
        return (Show-HerdrConfigEditFailure -Phase 'editor selection' -ExitCode 127 `
                -Detail ([string]$_) -Target $target -NoHold:$NoHold)
    }
    if (-not $editor) {
        return (Show-HerdrConfigEditFailure -Phase 'editor selection' -ExitCode 127 `
                -Detail 'EDITOR is unset and neither nvim nor notepad.exe was found' `
                -Target $target -NoHold:$NoHold)
    }

    try {
        $metadata = Get-HerdrConfigMetadata -Path $target
        $backup = New-HerdrConfigBackup -Target $target -Metadata $metadata
    } catch {
        return (Show-HerdrConfigEditFailure -Phase 'backup creation' -ExitCode 74 `
                -Detail ([string]$_) -Target $target -NoHold:$NoHold)
    }

    $editorResult = Start-HerdrConfigEditor -Editor $editor -Target $target
    if ($editorResult.ExitCode -ne 0) {
        return (Invoke-HerdrConfigRollback -Phase 'editor' -ExitCode $editorResult.ExitCode `
                -Detail $editorResult.Detail -Target $target -Backup $backup -Metadata $metadata `
                -NoHold:$NoHold)
    }

    try {
        # Editors that save through rename can replace attributes/ACL. Restore the
        # original file metadata before validating the edited bytes.
        Set-HerdrConfigMetadata -Path $target -Metadata $metadata
    } catch {
        return (Invoke-HerdrConfigRollback -Phase 'edited target metadata restoration' -ExitCode 74 `
                -Detail ([string]$_) -Target $target -Backup $backup -Metadata $metadata `
                -NoHold:$NoHold)
    }

    $validation = Invoke-HerdrConfigCheck -Target $target -OriginalState $configState
    if ($validation.ExitCode -ne 0) {
        return (Invoke-HerdrConfigRollback -Phase 'herdr config check' -ExitCode $validation.ExitCode `
                -Detail $validation.Detail -Target $target -Backup $backup -Metadata $metadata `
                -NoHold:$NoHold)
    }

    $reload = Invoke-HerdrConfigCommand -Argument @('server', 'reload-config')
    if ($reload.ExitCode -ne 0) {
        if ($reload.Stream) { $null = Resolve-HerdrFailure $reload.Stream.Err $reload.Stream.Out }
        return (Show-HerdrConfigEditFailure -Phase 'herdr server reload-config' `
                -ExitCode $reload.ExitCode -Detail $reload.Detail -Target $target -Backup $backup `
                -NoHold:$NoHold)
    }

    try {
        Remove-HerdrConfigBackup -Path $backup
    } catch {
        return (Show-HerdrConfigEditFailure -Phase 'backup cleanup' -ExitCode 74 `
                -Detail ([string]$_) -Target $target -Backup $backup -NoHold:$NoHold)
    }

    0
}

# Pester dot-sources this file to exercise Invoke-HerdrConfigEdit against stubs.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-HerdrConfigEdit)
}
