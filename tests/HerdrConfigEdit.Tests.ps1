#Requires -Version 7
# Fully isolated regression tests for dot_config/herdr/edit-config.ps1.
# Editors and Herdr are stubbed; every config/artifact lives under TestDrive.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidOverwritingBuiltInCmdlets',
    '',
    Justification = 'Pester must intercept the waited Notepad fallback.'
)]
param()

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $HelperPath = Join-Path $RepoRoot 'dot_config' 'herdr' 'edit-config.ps1'
    $script:ConfigTemplate = Join-Path $RepoRoot '.chezmoitemplates' 'herdr' 'config.toml'

    $script:SavedEditor = $env:EDITOR
    $script:SavedConfigState = [pscustomobject]@{
        Present = Test-Path -LiteralPath 'Env:HERDR_CONFIG_PATH'
        Value   = if (Test-Path -LiteralPath 'Env:HERDR_CONFIG_PATH') {
            [string](Get-Item -LiteralPath 'Env:HERDR_CONFIG_PATH').Value
        } else { $null }
    }

    . $HelperPath

    $script:RealResolveEditor = ${function:Resolve-HerdrConfigEditor}
    $script:RealNewBackup = ${function:New-HerdrConfigBackup}
    $script:RealAtomicReplace = ${function:Invoke-HerdrConfigAtomicReplace}
    $script:RealRemoveBackup = ${function:Remove-HerdrConfigBackup}
    $script:RealDefaultPath = ${function:Get-HerdrDefaultConfigPath}
    $script:RealRestoreConfigState = ${function:Restore-HerdrConfigPathState}

    function Add-HerdrConfigEditCall {
        param(
            [Parameter(Mandatory)] [string] $Phase,
            [object[]] $Argument = @(),
            [string] $ConfigPath,
            [string] $BackupPath,
            [bool] $BackupExists = $false,
            [Nullable[IO.UnixFileMode]] $BackupUnixMode,
            [Nullable[IO.FileAttributes]] $BackupAttributes,
            [string] $BackupAclSddl
        )
        $script:Calls += , [pscustomobject]@{
            Phase            = $Phase
            Argument         = @($Argument | ForEach-Object { [string]$_ })
            ConfigPath       = $ConfigPath
            BackupPath       = $BackupPath
            BackupExists     = $BackupExists
            BackupUnixMode   = $BackupUnixMode
            BackupAttributes = $BackupAttributes
            BackupAclSddl    = $BackupAclSddl
        }
    }

    function Set-HerdrConfigEditExit {
        param([int] $ExitCode)
        $global:LASTEXITCODE = $ExitCode
    }

    function Get-HerdrDefaultConfigPath {
        if ($script:DefaultTarget) { return $script:DefaultTarget }
        & $script:RealDefaultPath
    }

    function Resolve-HerdrConfigEditor {
        if ($script:FailurePhase -eq 'editor-selection') {
            throw "EDITOR must name one blocking executable or wrapper path; use a wrapper for arguments such as 'code --wait'"
        }
        $script:EditorSpec
    }

    function Find-HerdrConfigExecutable {
        param([string] $Name)
        $script:ExecutableLookups += $Name
        if ($script:ExecutableMap.ContainsKey($Name)) {
            return [pscustomobject]@{ Source = $script:ExecutableMap[$Name] }
        }
        $null
    }

    function New-HerdrConfigBackup {
        param(
            [Parameter(Mandatory)] [string] $Target,
            [Parameter(Mandatory)] [psobject] $Metadata
        )
        if ($script:FailurePhase -eq 'backup') { throw 'backup stub failed' }
        & $script:RealNewBackup -Target $Target -Metadata $Metadata
    }

    function Invoke-HerdrConfigAtomicReplace {
        param(
            [Parameter(Mandatory)] [string] $Backup,
            [Parameter(Mandatory)] [string] $Target,
            [Parameter(Mandatory)] [string] $Candidate
        )
        if ($script:FailurePhase -eq 'rollback') { throw 'atomic replace stub failed' }
        & $script:RealAtomicReplace -Backup $Backup -Target $Target -Candidate $Candidate
    }

    function Remove-HerdrConfigBackup {
        param([Parameter(Mandatory)] [string] $Path)
        if ($script:FailurePhase -eq 'cleanup') { throw 'cleanup stub failed' }
        & $script:RealRemoveBackup -Path $Path
    }

    function editor-stub {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)
        $target = $Argument[0]
        $directory = [IO.Path]::GetDirectoryName($target)
        $leaf = [IO.Path]::GetFileName($target)
        $backups = @(Get-ChildItem -LiteralPath $directory -Force |
            Where-Object Name -Like "$leaf.backup-*")
        $backup = if ($backups.Count -eq 1) { $backups[0].FullName } else { $null }
        $backupMode = if ($backup -and -not $IsWindows) { [IO.File]::GetUnixFileMode($backup) } else { $null }
        $backupAttributes = if ($backup) { [IO.File]::GetAttributes($backup) } else { $null }
        $backupAcl = if ($backup -and $IsWindows) { (Get-Acl -LiteralPath $backup).Sddl } else { $null }
        Add-HerdrConfigEditCall -Phase editor -Argument $Argument -ConfigPath $env:HERDR_CONFIG_PATH `
            -BackupPath $backup -BackupExists ($backups.Count -eq 1) `
            -BackupUnixMode $backupMode -BackupAttributes $backupAttributes -BackupAclSddl $backupAcl

        if ($script:FailurePhase -eq 'editor-delete') {
            [IO.File]::Delete($target)
            Set-HerdrConfigEditExit $script:FailureCode
            return
        }

        [IO.File]::WriteAllBytes($target, $script:EditedBytes)
        if ($null -ne $script:EditorAttributes) {
            [IO.File]::SetAttributes($target, [IO.FileAttributes]$script:EditorAttributes)
        }
        $rc = if ($script:FailurePhase -eq 'editor') { $script:FailureCode } else { 0 }
        Set-HerdrConfigEditExit $rc
    }

    function herdr {
        $argv = @($args | ForEach-Object { [string]$_ })
        $phase = if ($argv[0] -eq 'config') { 'check' } else { 'reload' }
        Add-HerdrConfigEditCall -Phase $phase -Argument $argv -ConfigPath $env:HERDR_CONFIG_PATH
        $failureName = if ($phase -eq 'check') { 'validation' } else { 'reload' }
        $shouldFail = ($script:FailurePhase -eq $failureName) -or
            ($script:FailurePhase -eq 'rollback' -and $failureName -eq 'validation')
        $rc = if ($shouldFail) { $script:FailureCode } else { 0 }
        Set-HerdrConfigEditExit $rc
        if ($rc -ne 0) { Write-Output "$failureName diagnostic" }
    }

    function Start-Process {
        param(
            [string] $FilePath,
            [object[]] $ArgumentList,
            [switch] $Wait,
            [switch] $PassThru
        )
        Add-HerdrConfigEditCall -Phase StartProcess `
            -Argument (@($FilePath, [string]$Wait, [string]$PassThru) + @($ArgumentList))
        [pscustomobject]@{ ExitCode = $script:StartProcessExitCode }
    }

    function Show-HerdrNotice {
        param([string] $Message, [double] $Seconds = 1.5)
        $null = $Seconds
        $script:Notices += $Message
    }

    function Test-HerdrConfigEditInteractive { $false }
}

Describe 'Herdr runtime config editor' {
    BeforeEach {
        $script:Calls = @()
        $script:Notices = @()
        $script:FailurePhase = ''
        $script:FailureCode = 0
        $script:ExecutableLookups = @()
        $script:ExecutableMap = @{}
        $script:StartProcessExitCode = 0
        $script:EditorAttributes = $null
        $script:DefaultTarget = $null
        $script:OriginalBytes = [Text.Encoding]::UTF8.GetBytes("original`n")
        $script:EditedBytes = [Text.Encoding]::UTF8.GetBytes("edited`n")
        $script:EditorSpec = [pscustomobject]@{ Command = 'editor-stub'; WaitForExit = $false }

        $directory = Join-Path $TestDrive ('runtime config with spaces ' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $script:Target = Join-Path $directory 'config.toml'
        [IO.File]::WriteAllBytes($script:Target, $script:OriginalBytes)
        $env:HERDR_CONFIG_PATH = $script:Target
        Remove-Item -LiteralPath 'Env:EDITOR' -ErrorAction SilentlyContinue
    }

    AfterAll {
        if ($null -eq $script:SavedEditor) {
            Remove-Item -LiteralPath 'Env:EDITOR' -ErrorAction SilentlyContinue
        } else {
            $env:EDITOR = $script:SavedEditor
        }
        & $script:RealRestoreConfigState -State $script:SavedConfigState
    }

    Context 'static command and binding contract' {
        It 'contains no source/render/apply/add command and does not evaluate editor text' {
            $source = Get-Content -Raw -LiteralPath $HelperPath
            $source | Should -Not -Match '(?i)chezmoi\s+(source-path|cat|apply|add|re-add)'
            $source | Should -Not -Match '(?i)Invoke-Expression'
        }

        It 'keeps one Alt+e pane with the runtime edit description and no Alt+g binding' {
            $template = Get-Content -Raw -LiteralPath $script:ConfigTemplate
            $pattern = '(?ms)^\[\[keys\.command\]\]\r?\n' +
                'key = "prefix\+alt\+e"\r?\n' +
                'type = "pane"\r?\n' +
                'command = ''pwsh -NoProfile -File "\{\{ \$herdrDir \}\}/edit-config\.ps1"''\r?\n' +
                'description = "edit runtime config, validate, and reload"$'
            [regex]::Matches($template, $pattern).Count | Should -Be 1
            [regex]::Matches($template, '(?m)^key = "prefix\+alt\+g"$').Count | Should -Be 0
        }

        It 'guards the file entry point so dot-sourcing cannot run orchestration' {
            Get-Content -Raw -LiteralPath $HelperPath |
                Should -Match 'if \(\$MyInvocation\.InvocationName -ne ''\.''\)'
            $script:Calls.Count | Should -Be 0
        }
    }

    Context 'editor selection' {
        It 'uses an EDITOR executable path containing spaces as one token' {
            $path = Join-Path $TestDrive 'Program Files' 'blocking editor.ps1'
            $script:ExecutableMap[$path] = $path
            $env:EDITOR = $path

            $editor = & $script:RealResolveEditor

            $editor.Command | Should -BeExactly $path
            $editor.WaitForExit | Should -BeFalse
            $script:ExecutableLookups | Should -BeExactly @($path)
        }

        It 'invokes a blocking wrapper path containing spaces with the target as one argument' {
            $wrapperDirectory = Join-Path $TestDrive 'editor wrapper with spaces'
            New-Item -ItemType Directory -Force -Path $wrapperDirectory | Out-Null
            $wrapper = Join-Path $wrapperDirectory 'blocking editor.ps1'
            @'
param([string] $TargetPath)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invoked.txt'), $TargetPath)
Write-Output 'wrapper diagnostic'
exit 0
'@ | Set-Content -LiteralPath $wrapper
            $editor = [pscustomobject]@{ Command = $wrapper; WaitForExit = $false }

            $result = Start-HerdrConfigEditor -Editor $editor -Target $script:Target

            $result.ExitCode | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $wrapperDirectory 'invoked.txt')) |
                Should -BeExactly $script:Target
        }

        It 'rejects an EDITOR value with arguments instead of parsing or falling back' {
            $env:EDITOR = 'code --wait'
            $script:ExecutableMap['nvim'] = 'C:\Tools\nvim.exe'

            { & $script:RealResolveEditor } |
                Should -Throw -ExpectedMessage "*one blocking executable or wrapper path*code --wait*"
            $script:ExecutableLookups | Should -BeExactly @('code --wait')
        }

        It 'uses nvim when EDITOR is unset' {
            $script:ExecutableMap['nvim'] = 'C:\Tools\nvim.exe'
            $script:ExecutableMap['notepad.exe'] = 'C:\Windows\notepad.exe'

            $editor = & $script:RealResolveEditor

            $editor.Command | Should -BeExactly 'C:\Tools\nvim.exe'
            $editor.WaitForExit | Should -BeFalse
            $script:ExecutableLookups | Should -BeExactly @('nvim')
        }

        It 'falls back to explicitly waited Notepad' {
            $script:ExecutableMap['notepad.exe'] = 'C:\Windows\notepad.exe'

            $editor = & $script:RealResolveEditor

            $editor.Command | Should -BeExactly 'C:\Windows\notepad.exe'
            $editor.WaitForExit | Should -BeTrue
            $script:ExecutableLookups | Should -BeExactly @('nvim', 'notepad.exe')
        }

        It 'passes a quoted path to waited Notepad without splitting it' {
            $editor = [pscustomobject]@{ Command = 'C:\Windows\notepad.exe'; WaitForExit = $true }

            $result = Start-HerdrConfigEditor -Editor $editor -Target $script:Target

            $result.ExitCode | Should -Be 0
            $start = $script:Calls | Where-Object Phase -EQ StartProcess
            $start.Argument | Should -BeExactly @(
                'C:\Windows\notepad.exe', 'True', 'True', ('"{0}"' -f $script:Target)
            )
        }
    }

    Context 'target resolution and successful transaction' {
        It 'edits the non-empty custom target exactly and follows backup-editor-check-reload-cleanup order' {
            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 0
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor>check>reload'
            $editor = $script:Calls[0]
            $editor.Argument | Should -BeExactly @($script:Target)
            $editor.BackupExists | Should -BeTrue
            [IO.Path]::GetDirectoryName($editor.BackupPath) |
                Should -BeExactly ([IO.Path]::GetDirectoryName($script:Target))
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:EditedBytes
            Test-Path -LiteralPath $editor.BackupPath | Should -BeFalse

            $check = $script:Calls[1]
            $check.Argument | Should -BeExactly @('config', 'check')
            $check.ConfigPath | Should -BeExactly $script:Target
            $reload = $script:Calls[2]
            $reload.Argument | Should -BeExactly @('server', 'reload-config')
            $reload.ConfigPath | Should -BeExactly $script:Target
            $script:Notices | Should -BeNullOrEmpty
        }

        It 'uses the default target when HERDR_CONFIG_PATH is absent' {
            $defaultDirectory = Join-Path $TestDrive 'default config with spaces'
            New-Item -ItemType Directory -Force -Path $defaultDirectory | Out-Null
            $script:DefaultTarget = Join-Path $defaultDirectory 'config.toml'
            [IO.File]::WriteAllBytes($script:DefaultTarget, $script:OriginalBytes)
            Remove-Item -LiteralPath 'Env:HERDR_CONFIG_PATH' -ErrorAction SilentlyContinue

            Invoke-HerdrConfigEdit -NoHold | Should -Be 0

            $script:Calls[0].Argument | Should -BeExactly @($script:DefaultTarget)
            $script:Calls[1].ConfigPath | Should -BeExactly $script:DefaultTarget
            $script:Calls[2].ConfigPath | Should -BeNullOrEmpty
            [IO.File]::ReadAllBytes($script:DefaultTarget) | Should -BeExactly $script:EditedBytes
        }

        It 'treats an empty or whitespace-only configured value as the default' -TestCases @(
            @{ Value = '' }
            @{ Value = '   ' }
        ) {
            param($Value)
            $defaultDirectory = Join-Path $TestDrive ('fallback-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $defaultDirectory | Out-Null
            $script:DefaultTarget = Join-Path $defaultDirectory 'config.toml'
            [IO.File]::WriteAllBytes($script:DefaultTarget, $script:OriginalBytes)

            Resolve-HerdrConfigTarget -State ([pscustomobject]@{ Present = $true; Value = $Value }) |
                Should -BeExactly $script:DefaultTarget
        }

        It 'preserves original metadata in the backup before the editor opens' -Skip:$IsWindows {
            $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor
                [IO.UnixFileMode]::GroupRead
            [IO.File]::SetUnixFileMode($script:Target, $mode)

            Invoke-HerdrConfigEdit -NoHold | Should -Be 0

            $editor = $script:Calls | Where-Object Phase -EQ editor
            $editor.BackupExists | Should -BeTrue
            $editor.BackupUnixMode | Should -Be $mode
            $editor.BackupAttributes | Should -Be ([IO.File]::GetAttributes($script:Target))
            [IO.File]::GetUnixFileMode($script:Target) | Should -Be $mode
        }
    }

    Context 'rollback and artifact retention' {
        It 'preserves editor-failed bytes as an invalid candidate and restores the original' {
            $script:FailurePhase = 'editor'
            $script:FailureCode = 23

            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 23
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor'
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:OriginalBytes
            $candidate = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.invalid-*')
            $candidate.Count | Should -Be 1
            [IO.File]::ReadAllBytes($candidate[0].FullName) | Should -BeExactly $script:EditedBytes
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*').Count | Should -Be 0
            ($script:Notices -join "`n") | Should -Match ([regex]::Escape($script:Target))
            ($script:Notices -join "`n") | Should -Match ([regex]::Escape($candidate[0].FullName))
        }

        It 'restores the backup when the editor deletes the target before failing' {
            $script:FailurePhase = 'editor-delete'
            $script:FailureCode = 24

            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 24
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor'
            Test-Path -LiteralPath $script:Target | Should -BeTrue
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:OriginalBytes
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.invalid-*').Count | Should -Be 0
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*').Count | Should -Be 0
        }

        It 'rolls back a validation failure, never reloads, and restores mode while restricting the candidate' -Skip:$IsWindows {
            $originalMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor
                [IO.UnixFileMode]::GroupRead
            [IO.File]::SetUnixFileMode($script:Target, $originalMode)
            $script:FailurePhase = 'validation'
            $script:FailureCode = 44

            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 44
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor>check'
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:OriginalBytes
            [IO.File]::GetUnixFileMode($script:Target) | Should -Be $originalMode
            $candidate = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.invalid-*')
            $candidate.Count | Should -Be 1
            [IO.File]::ReadAllBytes($candidate[0].FullName) | Should -BeExactly $script:EditedBytes
            $expectedMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
            [IO.File]::GetUnixFileMode($candidate[0].FullName) | Should -Be $expectedMode
        }

        It 'retains edited target and original backup when rollback itself fails' {
            $script:FailurePhase = 'rollback'
            $script:FailureCode = 44

            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 74
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor>check'
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:EditedBytes
            $backup = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*')
            $backup.Count | Should -Be 1
            [IO.File]::ReadAllBytes($backup[0].FullName) | Should -BeExactly $script:OriginalBytes
            ($script:Notices -join "`n") | Should -Match 'rollback failed'
            ($script:Notices -join "`n") | Should -Match ([regex]::Escape($backup[0].FullName))
        }

        It 'keeps a validated edit and its backup when reload fails' {
            $script:FailurePhase = 'reload'
            $script:FailureCode = 55

            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 55
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor>check>reload'
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:EditedBytes
            $backup = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*')
            $backup.Count | Should -Be 1
            [IO.File]::ReadAllBytes($backup[0].FullName) | Should -BeExactly $script:OriginalBytes
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.invalid-*').Count | Should -Be 0
            ($script:Notices -join "`n") | Should -Match ([regex]::Escape($script:Target))
            ($script:Notices -join "`n") | Should -Match ([regex]::Escape($backup[0].FullName))
        }

        It 'keeps a valid target and backup when cleanup alone fails' {
            $script:FailurePhase = 'cleanup'

            $rc = Invoke-HerdrConfigEdit -NoHold

            $rc | Should -Be 74
            ($script:Calls.Phase -join '>') | Should -BeExactly 'editor>check>reload'
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:EditedBytes
            $backup = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*')
            $backup.Count | Should -Be 1
            ($script:Notices -join "`n") | Should -Match 'backup cleanup'
        }
    }

    Context 'preflight and backup failures' {
        It 'does not open the editor when the target is missing' {
            Remove-Item -LiteralPath $script:Target -Force

            Invoke-HerdrConfigEdit -NoHold | Should -Be 66

            $script:Calls | Should -BeNullOrEmpty
            ($script:Notices -join "`n") | Should -Match 'target preflight'
            ($script:Notices -join "`n") | Should -Match 'does not exist'
        }

        It 'does not open the editor or alter the target when backup creation fails' {
            $script:FailurePhase = 'backup'

            Invoke-HerdrConfigEdit -NoHold | Should -Be 74

            $script:Calls | Should -BeNullOrEmpty
            [IO.File]::ReadAllBytes($script:Target) | Should -BeExactly $script:OriginalBytes
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*').Count | Should -Be 0
            ($script:Notices -join "`n") | Should -Match 'backup creation'
        }

        It 'does not create a backup when editor selection fails' {
            $script:FailurePhase = 'editor-selection'

            Invoke-HerdrConfigEdit -NoHold | Should -Be 127

            $script:Calls | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.backup-*').Count | Should -Be 0
        }

        It 'rejects a Windows reparse-point target before editor or backup' -Skip:(-not $IsWindows) {
            $real = $script:Target
            $link = Join-Path ([IO.Path]::GetDirectoryName($real)) 'linked-config.toml'
            try {
                $null = [IO.File]::CreateSymbolicLink($link, $real)
            } catch {
                Set-ItResult -Skipped -Because "this Windows host cannot create a test symlink: $_"
                return
            }
            $env:HERDR_CONFIG_PATH = $link

            Invoke-HerdrConfigEdit -NoHold | Should -Be 66

            $script:Calls | Should -BeNullOrEmpty
            ($script:Notices -join "`n") | Should -Match 'reparse point'
            [IO.File]::ReadAllBytes($real) | Should -BeExactly $script:OriginalBytes
        }
    }

    Context 'Windows metadata recovery' {
        It 'restores original attributes and ACL and restricts the rejected candidate to the current user' -Skip:(-not $IsWindows) {
            $originalAcl = Get-Acl -LiteralPath $script:Target
            [IO.File]::SetAttributes($script:Target, [IO.FileAttributes]::Archive)
            $script:EditorAttributes = [IO.FileAttributes]::Normal
            $script:FailurePhase = 'validation'
            $script:FailureCode = 45

            Invoke-HerdrConfigEdit -NoHold | Should -Be 45

            $editor = $script:Calls | Where-Object Phase -EQ editor
            $editor.BackupExists | Should -BeTrue
            $editor.BackupAttributes | Should -Be ([IO.FileAttributes]::Archive)
            $editor.BackupAclSddl | Should -BeExactly $originalAcl.Sddl
            [IO.File]::GetAttributes($script:Target) | Should -Be ([IO.FileAttributes]::Archive)
            (Get-Acl -LiteralPath $script:Target).Sddl | Should -BeExactly $originalAcl.Sddl
            $candidate = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($script:Target)) -Force |
                Where-Object Name -Like 'config.toml.invalid-*')
            $candidate.Count | Should -Be 1
            $candidateAcl = Get-Acl -LiteralPath $candidate[0].FullName
            $candidateAcl.AreAccessRulesProtected | Should -BeTrue
            $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $ruleSids = @($candidateAcl.Access | ForEach-Object {
                $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            } | Select-Object -Unique)
            $ruleSids | Should -BeExactly @($currentSid)
        }
    }
}
