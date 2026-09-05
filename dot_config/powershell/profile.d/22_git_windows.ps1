# 22_git_windows.ps1 — diagnose Windows-hosted Git checkouts and safely repair
# tracked symlinks that Git materialized as one-line placeholder files.

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return }

function global:git-windows-doctor {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string] $Root,

        [Parameter()]
        [ValidateRange(0, 32)]
        [int] $Depth = 6,

        [Parameter()]
        [switch] $RepairSymlinks
    )

    $gitCommand = (Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1).Source

    function Invoke-GitWindowsProcess {
        param(
            [Parameter(Mandatory)][string] $WorkingDirectory,
            [Parameter(Mandatory)][string[]] $ArgumentList
        )

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $gitCommand
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.Environment['GIT_OPTIONAL_LOCKS'] = '0'
        foreach ($argument in $ArgumentList) {
            [void]$startInfo.ArgumentList.Add($argument)
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                throw "Could not start git in $WorkingDirectory"
            }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            [pscustomobject]@{
                ExitCode = $process.ExitCode
                StdOut   = $stdoutTask.GetAwaiter().GetResult()
                StdErr   = $stderrTask.GetAwaiter().GetResult()
            }
        } finally {
            $process.Dispose()
        }
    }

    function Resolve-GitWindowsRepository {
        param([Parameter(Mandatory)][string] $Path)

        $result = Invoke-GitWindowsProcess -WorkingDirectory $Path -ArgumentList @(
            'rev-parse', '--show-toplevel'
        )
        if ($result.ExitCode -ne 0) { return $null }
        $top = $result.StdOut.Trim()
        if (-not $top) { return $null }
        [IO.Path]::GetFullPath($top)
    }

    function Get-GitWindowsRepositories {
        param([string] $SearchRoot, [int] $MaximumDepth)

        if (-not $SearchRoot) {
            $single = Resolve-GitWindowsRepository -Path $PWD.Path
            if (-not $single) { throw 'The current directory is not inside a Git worktree.' }
            return $single
        }

        try {
            $searchPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SearchRoot)
        } catch {
            throw "Could not resolve repository search root '$SearchRoot': $($_.Exception.Message)"
        }
        $searchPath = [IO.Path]::GetFullPath($searchPath)
        if (-not (Test-Path -LiteralPath $searchPath -PathType Container)) {
            throw "Repository search root is not a directory: $searchPath"
        }

        # If -Root itself is inside a worktree, treat that worktree as the one
        # target. Otherwise scan for top-level repositories beneath it.
        $containing = Resolve-GitWindowsRepository -Path $searchPath
        if ($containing) { return $containing }

        $repositories = [Collections.Generic.List[string]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{ Path = $searchPath; Level = 0 })
        $skipNames = [Collections.Generic.HashSet[string]]::new(
            [string[]]@('.git', '.hg', '.svn', '.venv', 'venv', 'node_modules', 'dist', 'build', 'site', 'target'),
            [StringComparer]::OrdinalIgnoreCase
        )

        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $marker = Join-Path $current.Path '.git'
            if (Test-Path -LiteralPath $marker) {
                $repo = Resolve-GitWindowsRepository -Path $current.Path
                if ($repo -and $seen.Add($repo)) { [void]$repositories.Add($repo) }
                continue
            }
            if ($current.Level -ge $MaximumDepth) { continue }

            foreach ($child in Get-ChildItem -LiteralPath $current.Path -Directory -Force -ErrorAction SilentlyContinue) {
                if ($skipNames.Contains($child.Name)) { continue }
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Level = $current.Level + 1 })
            }
        }

        return $repositories.ToArray()
    }

    function Get-GitWindowsIndexEntries {
        param([Parameter(Mandatory)][string] $Repository)

        $result = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
            '-c', 'core.quotePath=false', 'ls-files', '--stage', '-z'
        )
        if ($result.ExitCode -ne 0) {
            throw "git ls-files failed in ${Repository}: $($result.StdErr.Trim())"
        }

        $entries = [Collections.Generic.List[object]]::new()
        foreach ($record in $result.StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            $match = [regex]::Match(
                $record,
                '^(?<mode>\d{6}) (?<oid>[0-9a-f]+) (?<stage>\d)\t(?<path>.*)$',
                [Text.RegularExpressions.RegexOptions]::Singleline
            )
            if (-not $match.Success) { continue }
            [void]$entries.Add([pscustomobject]@{
                    Mode  = $match.Groups['mode'].Value
                    Oid   = $match.Groups['oid'].Value
                    Stage = [int]$match.Groups['stage'].Value
                    Path  = $match.Groups['path'].Value
                })
        }
        return $entries.ToArray()
    }

    function Get-GitWindowsPathItem {
        param([Parameter(Mandatory)][string] $LiteralPath)

        $parent = Split-Path -Parent $LiteralPath
        $leaf = Split-Path -Leaf $LiteralPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return $null }
        Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
            Where-Object Name -CEQ $leaf |
            Select-Object -First 1
    }

    function Get-GitWindowsSymlinkState {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $IndexEntries,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[string]] $SkipWorktreePaths
        )

        $states = [Collections.Generic.List[object]]::new()
        foreach ($entry in $IndexEntries | Where-Object { $_.Mode -eq '120000' -and $_.Stage -eq 0 }) {
            $blob = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
                'cat-file', 'blob', $entry.Oid
            )
            if ($blob.ExitCode -ne 0) {
                [void]$states.Add([pscustomobject]@{
                        Path = $entry.Path; Target = ''; State = 'Conflict'
                        Message = "could not read index blob $($entry.Oid)"
                    })
                continue
            }

            $target = $blob.StdOut
            $fullPath = Join-Path $Repository $entry.Path
            $item = Get-GitWindowsPathItem -LiteralPath $fullPath
            if (-not $item) {
                if ($SkipWorktreePaths.Contains($entry.Path)) {
                    [void]$states.Add([pscustomobject]@{
                            Path = $entry.Path; Target = $target; State = 'Sparse'
                            Message = 'tracked symlink is intentionally absent because skip-worktree is set'
                        })
                    continue
                }
                [void]$states.Add([pscustomobject]@{
                        Path = $entry.Path; Target = $target; State = 'Missing'
                        Message = 'tracked symlink is missing from the working tree'
                    })
                continue
            }

            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $actualTarget = (($item.Target -join '') -replace '\\', '/')
                $expectedTarget = ($target -replace '\\', '/')
                $state = if ($item.LinkType -eq 'SymbolicLink' -and $actualTarget -ceq $expectedTarget) {
                    'Valid'
                } else {
                    'Conflict'
                }
                [void]$states.Add([pscustomobject]@{
                        Path = $entry.Path; Target = $target; State = $state
                        Message = if ($state -eq 'Valid') { 'symbolic link is correct' } else { "link target is '$actualTarget'" }
                    })
                continue
            }

            if (-not $item.PSIsContainer) {
                try {
                    $content = [IO.File]::ReadAllText($item.FullName, [Text.UTF8Encoding]::new($false, $true))
                } catch {
                    $content = $null
                }
                if ($null -ne $content -and $content -ceq $target) {
                    [void]$states.Add([pscustomobject]@{
                            Path = $entry.Path; Target = $target; State = 'Placeholder'
                            Message = 'regular file exactly matches the index symlink target'
                        })
                    continue
                }
            }

            [void]$states.Add([pscustomobject]@{
                    Path = $entry.Path; Target = $target; State = 'Conflict'
                    Message = if ($item.PSIsContainer) { 'a real directory occupies the symlink path' } else { 'regular file differs from the index symlink target' }
                })
        }
        return $states.ToArray()
    }

    function Get-GitWindowsSkipWorktreePaths {
        param([Parameter(Mandatory)][string] $Repository)

        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $result = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
            '-c', 'core.quotePath=false', 'ls-files', '-t', '-z'
        )
        if ($result.ExitCode -ne 0) { return , $paths }
        foreach ($record in $result.StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            $match = [regex]::Match(
                $record,
                '^(?<tag>.) (?<path>.*)$',
                [Text.RegularExpressions.RegexOptions]::Singleline
            )
            if ($match.Success -and $match.Groups['tag'].Value -eq 'S') {
                [void]$paths.Add($match.Groups['path'].Value)
            }
        }
        return , $paths
    }

    function Test-GitWindowsSymlinkCapability {
        $tempRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
        $probeRoot = Join-Path $tempRoot ('git-windows-doctor-' + [guid]::NewGuid().ToString('N'))
        $target = Join-Path $probeRoot 'target.txt'
        $link = Join-Path $probeRoot 'link.txt'
        try {
            [IO.Directory]::CreateDirectory($probeRoot) | Out-Null
            [IO.File]::WriteAllText($target, 'probe')
            [IO.File]::CreateSymbolicLink($link, $target) | Out-Null
            $item = Get-Item -LiteralPath $link -Force -ErrorAction Stop
            return $item.LinkType -eq 'SymbolicLink'
        } catch {
            return $false
        } finally {
            if ([IO.File]::Exists($link)) { [IO.File]::Delete($link) }
            if ([IO.File]::Exists($target)) { [IO.File]::Delete($target) }
            if ([IO.Directory]::Exists($probeRoot)) { [IO.Directory]::Delete($probeRoot, $true) }
        }
    }

    function Add-GitWindowsFinding {
        param(
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $List,
            [Parameter(Mandatory)][ValidateSet('Info', 'Warning', 'Error')] [string] $Severity,
            [Parameter(Mandatory)][string] $Category,
            [string] $Path,
            [Parameter(Mandatory)][string] $Message
        )
        [void]$List.Add([pscustomobject]@{
                Severity = $Severity
                Category = $Category
                Path     = $Path
                Message  = $Message
            })
    }

    function Get-GitWindowsConfigValue {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][string] $Name,
            [string] $Scope
        )

        $arguments = @('config')
        if ($Scope) { $arguments += "--$Scope" }
        $arguments += @('--get-all', $Name)
        $result = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList $arguments
        if ($result.ExitCode -ne 0) { return @() }
        @($result.StdOut -split "`r?`n" | Where-Object { $_ -ne '' })
    }

    function Add-GitWindowsConfigFindings {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Findings,
            [int] $LongPathCount,
            [int] $MixedEolCount
        )

        $symlinks = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.symlinks') | Select-Object -Last 1
        $localSymlinks = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.symlinks' -Scope local)
        if ($symlinks -ne 'true') {
            Add-GitWindowsFinding $Findings Warning Config '' "effective core.symlinks is '$symlinks' (expected true)"
        }
        if ($localSymlinks -contains 'false') {
            Add-GitWindowsFinding $Findings Warning Config '' 'repo-local core.symlinks=false overrides the managed user setting'
        }

        $autocrlf = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.autocrlf') | Select-Object -Last 1
        if ($autocrlf -ne 'input') {
            Add-GitWindowsFinding $Findings Warning Config '' "effective core.autocrlf is '$autocrlf' (managed Windows default is input)"
        }

        $safecrlf = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.safecrlf') | Select-Object -Last 1
        if ($safecrlf -eq 'true' -and $MixedEolCount -gt 0) {
            Add-GitWindowsFinding $Findings Warning Config '' 'core.safecrlf=true can reject adds while mixed-EOL files remain'
        }

        $filemode = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.filemode') | Select-Object -Last 1
        if ($filemode -eq 'true') {
            Add-GitWindowsFinding $Findings Info Config '' 'core.filemode=true may report executable-bit churn on Windows filesystems'
        }

        $ignorecase = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.ignorecase') | Select-Object -Last 1
        if ($ignorecase -eq 'false') {
            Add-GitWindowsFinding $Findings Info Config '' 'core.ignorecase=false requires a case-sensitive working directory'
        }

        $longpaths = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.longpaths') | Select-Object -Last 1
        if ($LongPathCount -gt 0 -and $longpaths -ne 'true') {
            Add-GitWindowsFinding $Findings Warning Config '' "$LongPathCount tracked path(s) approach Windows path limits while core.longpaths is not true"
        }
    }

    function Add-GitWindowsEolFindings {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Findings
        )

        $result = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
            '-c', 'core.quotePath=false', 'ls-files', '--eol', '-z'
        )
        if ($result.ExitCode -ne 0) {
            Add-GitWindowsFinding $Findings Error EOL '' "git ls-files --eol failed: $($result.StdErr.Trim())"
            return 0
        }

        $mixed = 0
        foreach ($record in $result.StdOut.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            $match = [regex]::Match(
                $record,
                '^(?<index>i/\S+)\s+(?<worktree>w/\S+)\s+(?<attr>attr/[^\t]*)\t(?<path>.*)$',
                [Text.RegularExpressions.RegexOptions]::Singleline
            )
            if (-not $match.Success) { continue }
            $indexEol = $match.Groups['index'].Value
            $worktreeEol = $match.Groups['worktree'].Value
            $attribute = $match.Groups['attr'].Value
            $path = $match.Groups['path'].Value

            if ($worktreeEol -eq 'w/mixed') {
                $mixed++
                Add-GitWindowsFinding $Findings Warning EOL $path 'working-tree file contains mixed line endings'
            }
            if ($attribute -match '\beol=lf\b' -and $worktreeEol -eq 'w/crlf') {
                Add-GitWindowsFinding $Findings Warning EOL $path 'working tree is CRLF although attributes require LF'
            }
            if ($attribute -match '\beol=crlf\b' -and $worktreeEol -eq 'w/lf') {
                Add-GitWindowsFinding $Findings Warning EOL $path 'working tree is LF although attributes require CRLF'
            }
            if ($attribute -match '\beol=lf\b' -and $indexEol -eq 'i/crlf') {
                Add-GitWindowsFinding $Findings Warning EOL $path 'index stores CRLF although attributes require LF'
            }
        }

        if (-not (Test-Path -LiteralPath (Join-Path $Repository '.gitattributes') -PathType Leaf)) {
            Add-GitWindowsFinding $Findings Info EOL '.gitattributes' 'no root .gitattributes; cross-platform EOL policy is not explicit'
        }
        return $mixed
    }

    function Add-GitWindowsPathFindings {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $IndexEntries,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Findings
        )

        $paths = @($IndexEntries | Where-Object Stage -EQ 0 | Select-Object -ExpandProperty Path -Unique)
        $caseGroups = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new(
            [StringComparer]::OrdinalIgnoreCase
        )
        $longPathCount = 0

        foreach ($path in $paths) {
            if (-not $caseGroups.ContainsKey($path)) {
                $caseGroups[$path] = [Collections.Generic.List[string]]::new()
            }
            [void]$caseGroups[$path].Add($path)

            $fullPath = Join-Path $Repository $path
            if ($fullPath.Length -gt 240 -or ($path -split '/' | Where-Object Length -GT 255)) {
                $longPathCount++
                Add-GitWindowsFinding $Findings Warning Path $path "path length is $($fullPath.Length) characters"
            }

            foreach ($segment in ($path -split '/')) {
                if ($segment -match '[<>:"\\|?*]' -or $segment -match '[ .]$' -or
                    $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
                    Add-GitWindowsFinding $Findings Error Path $path "Windows-incompatible path segment: '$segment'"
                    break
                }
            }
        }

        foreach ($group in $caseGroups.Values) {
            $distinct = @($group | Sort-Object -CaseSensitive -Unique)
            if ($distinct.Count -gt 1) {
                Add-GitWindowsFinding $Findings Error Case ($distinct -join ', ') 'tracked paths differ only by case'
            }
        }
        return $longPathCount
    }

    function Add-GitWindowsScriptFindings {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $IndexEntries,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Findings
        )

        foreach ($entry in $IndexEntries | Where-Object {
                $_.Stage -eq 0 -and $_.Mode -eq '100644' -and $_.Path -match '\.(?:sh|bash|zsh|command)$'
            }) {
            Add-GitWindowsFinding $Findings Info Executable $entry.Path 'shell script is not executable in the Git index; verify this is intentional'
        }

        foreach ($entry in $IndexEntries | Where-Object {
                $_.Stage -eq 0 -and $_.Mode -match '^100' -and $_.Path -match '\.(?:sh|bash|zsh|command)$'
            }) {
            $fullPath = Join-Path $Repository $entry.Path
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            $bytes = [IO.File]::ReadAllBytes($fullPath)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                Add-GitWindowsFinding $Findings Warning Encoding $entry.Path 'shell script starts with a UTF-8 BOM, which can break its shebang'
            }
            for ($i = 0; $i -lt ($bytes.Length - 1); $i++) {
                if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) {
                    Add-GitWindowsFinding $Findings Warning EOL $entry.Path 'shell script contains CRLF, which can break execution on Unix'
                    break
                }
            }
        }
    }

    function Add-GitWindowsLfsFindings {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $IndexEntries,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Findings
        )

        $usesLfs = $false
        foreach ($entry in $IndexEntries | Where-Object {
                $_.Stage -eq 0 -and (Split-Path $_.Path -Leaf) -eq '.gitattributes'
            }) {
            $blob = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @('cat-file', 'blob', $entry.Oid)
            if ($blob.ExitCode -eq 0 -and $blob.StdOut -match 'filter=lfs') {
                $usesLfs = $true
                break
            }
        }
        if (-not $usesLfs) { return }

        $lfs = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @('lfs', 'version')
        if ($lfs.ExitCode -ne 0) {
            Add-GitWindowsFinding $Findings Error LFS '.gitattributes' 'repository declares Git LFS filters but git-lfs is unavailable'
        }
    }

    function Repair-GitWindowsSymlinks {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $States,
            [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Findings
        )

        $repairable = @($States | Where-Object State -In 'Placeholder', 'Missing')
        if ($repairable.Count -eq 0) { return 0 }
        if (-not (Test-GitWindowsSymlinkCapability)) {
            Add-GitWindowsFinding $Findings Error Symlink '' 'Windows cannot create an unprivileged symbolic link; enable Developer Mode before repair'
            return 0
        }

        $repaired = 0
        foreach ($state in $repairable) {
            $fullPath = Join-Path $Repository $state.Path
            if (-not $PSCmdlet.ShouldProcess($fullPath, "restore tracked symlink -> $($state.Target)")) {
                continue
            }

            $backupBytes = if ($state.State -eq 'Placeholder') { [IO.File]::ReadAllBytes($fullPath) } else { $null }
            try {
                if ($state.State -eq 'Placeholder') { [IO.File]::Delete($fullPath) }
                $restore = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
                    '-c', 'core.symlinks=true', 'restore', '--worktree', '--', $state.Path
                )
                if ($restore.ExitCode -ne 0) { throw $restore.StdErr.Trim() }

                $item = Get-GitWindowsPathItem -LiteralPath $fullPath
                if (-not $item -or $item.LinkType -ne 'SymbolicLink') {
                    throw 'Git restore completed without creating a symbolic link'
                }
                $repaired++
            } catch {
                $item = Get-GitWindowsPathItem -LiteralPath $fullPath
                if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    if ($item.PSIsContainer) { [IO.Directory]::Delete($fullPath) }
                    else { [IO.File]::Delete($fullPath) }
                }
                if ($null -ne $backupBytes) {
                    [IO.Directory]::CreateDirectory((Split-Path -Parent $fullPath)) | Out-Null
                    [IO.File]::WriteAllBytes($fullPath, $backupBytes)
                }
                Add-GitWindowsFinding $Findings Error Symlink $state.Path "repair failed and prior placeholder was restored: $($_.Exception.Message)"
            }
        }

        if ($repaired -gt 0) {
            $globalSetting = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
                'config', '--global', '--bool', '--get', 'core.symlinks'
            )
            if ($globalSetting.ExitCode -ne 0 -or $globalSetting.StdOut.Trim() -ne 'true') {
                if ($PSCmdlet.ShouldProcess('global Git config', 'set core.symlinks=true')) {
                    $setGlobal = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
                        'config', '--global', 'core.symlinks', 'true'
                    )
                    if ($setGlobal.ExitCode -ne 0) {
                        Add-GitWindowsFinding $Findings Error Config '' "could not set global core.symlinks=true: $($setGlobal.StdErr.Trim())"
                    }
                }
            }

            $localSetting = @(Get-GitWindowsConfigValue -Repository $Repository -Name 'core.symlinks' -Scope local)
            if ($localSetting.Count -gt 0 -and $PSCmdlet.ShouldProcess($Repository, 'remove repo-local core.symlinks override')) {
                $unsetLocal = Invoke-GitWindowsProcess -WorkingDirectory $Repository -ArgumentList @(
                    'config', '--local', '--unset-all', 'core.symlinks'
                )
                if ($unsetLocal.ExitCode -ne 0) {
                    Add-GitWindowsFinding $Findings Error Config '' "could not remove local core.symlinks override: $($unsetLocal.StdErr.Trim())"
                }
            }
        }
        return $repaired
    }

    $repositories = @(Get-GitWindowsRepositories -SearchRoot $Root -MaximumDepth $Depth)
    if ($repositories.Count -eq 0) {
        Write-Warning 'No Git worktrees were found.'
        $global:LASTEXITCODE = 1
        return
    }

    $results = [Collections.Generic.List[object]]::new()
    $hadFailure = $false
    foreach ($repository in $repositories) {
        $findings = [Collections.Generic.List[object]]::new()
        try {
            $indexEntries = @(Get-GitWindowsIndexEntries -Repository $repository)
            $skipWorktreePaths = Get-GitWindowsSkipWorktreePaths -Repository $repository
            $symlinkStates = @(Get-GitWindowsSymlinkState -Repository $repository -IndexEntries $indexEntries -SkipWorktreePaths $skipWorktreePaths)
            $mixedEol = Add-GitWindowsEolFindings -Repository $repository -Findings $findings
            $longPaths = Add-GitWindowsPathFindings -Repository $repository -IndexEntries $indexEntries -Findings $findings
            Add-GitWindowsScriptFindings -Repository $repository -IndexEntries $indexEntries -Findings $findings
            Add-GitWindowsLfsFindings -Repository $repository -IndexEntries $indexEntries -Findings $findings

            $repaired = 0
            if ($RepairSymlinks) {
                $repaired = Repair-GitWindowsSymlinks -Repository $repository -States $symlinkStates -Findings $findings
                if ($repaired -gt 0 -and -not $WhatIfPreference) {
                    $symlinkStates = @(Get-GitWindowsSymlinkState -Repository $repository -IndexEntries $indexEntries -SkipWorktreePaths $skipWorktreePaths)
                }
            }

            foreach ($state in $symlinkStates) {
                switch ($state.State) {
                    'Placeholder' { Add-GitWindowsFinding $findings Warning Symlink $state.Path $state.Message }
                    'Missing'     { Add-GitWindowsFinding $findings Warning Symlink $state.Path $state.Message }
                    'Sparse'      { Add-GitWindowsFinding $findings Info Symlink $state.Path $state.Message }
                    'Conflict'    { Add-GitWindowsFinding $findings Error Symlink $state.Path $state.Message }
                }
            }
            Add-GitWindowsConfigFindings -Repository $repository -Findings $findings -LongPathCount $longPaths -MixedEolCount $mixedEol

            $valid = @($symlinkStates | Where-Object State -EQ 'Valid').Count
            $repairable = @($symlinkStates | Where-Object State -In 'Placeholder', 'Missing').Count
            $sparse = @($symlinkStates | Where-Object State -EQ 'Sparse').Count
            $conflicts = @($symlinkStates | Where-Object State -EQ 'Conflict').Count
            $errorCount = @($findings | Where-Object Severity -EQ 'Error').Count
            $warningCount = @($findings | Where-Object Severity -EQ 'Warning').Count
            $status = if ($errorCount -gt 0 -or $conflicts -gt 0) {
                'Error'
            } elseif ($repairable -gt 0) {
                'Repairable'
            } elseif ($warningCount -gt 0) {
                'Warning'
            } elseif ($repaired -gt 0) {
                'Repaired'
            } else {
                'Clean'
            }
            if ($status -eq 'Error') { $hadFailure = $true }

            Write-Host "[$repository]"
            Write-Host "  symlinks: $valid valid, $repairable repairable, $sparse sparse, $conflicts conflict(s), $repaired repaired"
            foreach ($finding in $findings | Where-Object Severity -NE 'Info') {
                $location = if ($finding.Path) { " [$($finding.Path)]" } else { '' }
                $message = "$($finding.Category)${location}: $($finding.Message)"
                if ($finding.Severity -eq 'Error') { Write-Warning $message }
                else { Write-Host "  warning: $message" -ForegroundColor Yellow }
            }

            [void]$results.Add([pscustomobject]@{
                    PSTypeName               = 'Dotfiles.GitWindowsDoctorResult'
                    Repository               = $repository
                    Status                   = $status
                    TrackedSymlinkCount      = $symlinkStates.Count
                    ValidSymlinkCount        = $valid
                    RepairableSymlinkCount   = $repairable
                    SparseSymlinkCount       = $sparse
                    SymlinkConflictCount     = $conflicts
                    RepairedSymlinkCount     = $repaired
                    MixedEolCount            = $mixedEol
                    CaseCollisionCount       = @($findings | Where-Object Category -EQ 'Case').Count
                    InvalidWindowsPathCount  = @($findings | Where-Object { $_.Category -eq 'Path' -and $_.Severity -eq 'Error' }).Count
                    LongPathCount            = $longPaths
                    Findings                 = $findings.ToArray()
                })
        } catch {
            $hadFailure = $true
            $failureMessage = $_.Exception.Message
            if ($_.InvocationInfo.PositionMessage) {
                $failureMessage += " $($_.InvocationInfo.PositionMessage.Trim())"
            }
            Write-Warning "[$repository] doctor failed: $failureMessage"
            [void]$results.Add([pscustomobject]@{
                    PSTypeName               = 'Dotfiles.GitWindowsDoctorResult'
                    Repository               = $repository
                    Status                   = 'Error'
                    TrackedSymlinkCount      = 0
                    ValidSymlinkCount        = 0
                    RepairableSymlinkCount   = 0
                    SparseSymlinkCount       = 0
                    SymlinkConflictCount     = 0
                    RepairedSymlinkCount     = 0
                    MixedEolCount            = 0
                    CaseCollisionCount       = 0
                    InvalidWindowsPathCount  = 0
                    LongPathCount            = 0
                    Findings                 = @([pscustomobject]@{
                            Severity = 'Error'; Category = 'Doctor'; Path = ''; Message = $failureMessage
                        })
                })
        }
    }

    $global:LASTEXITCODE = if ($hadFailure) { 1 } else { 0 }
    return $results.ToArray()
}

function global:gwinfix {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string] $Root,

        [Parameter()]
        [ValidateRange(0, 32)]
        [int] $Depth = 6
    )

    $parameters = @{ Depth = $Depth }
    if ($Root) { $parameters.Root = $Root }
    if ($PSCmdlet.ShouldProcess(
            $(if ($Root) { $Root } else { $PWD.Path }),
            'repair safe Git symlink placeholders'
        )) {
        $parameters.RepairSymlinks = $true
        $parameters.Confirm = $false
    }
    git-windows-doctor @parameters
}
