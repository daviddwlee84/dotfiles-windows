#Requires -Version 7.4
#Requires -PSEdition Core
# Read-only, local evidence. Never execute a candidate, package manager, shim,
# uninstall command or init script. No persistent inventory/cache is written.

function Test-SourceChild {
    param([string]$Path, [string]$Root)
    if (-not $Root -or -not $Path) { return $false }
    $rootPrefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SourcePathEntries {
    param([string]$Value)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($part in ($Value -split ';')) {
        $entry = [Environment]::ExpandEnvironmentVariables($part.Trim().Trim('"'))
        if (-not $entry) { continue }
        try {
            $entry = [IO.Path]::GetFullPath($entry)
            if ($entry -ne [IO.Path]::GetPathRoot($entry)) { $entry = $entry.TrimEnd([IO.Path]::DirectorySeparatorChar) }
        }
        catch { continue }
        if ($seen.Add($entry)) { $entry }
    }
}

function Get-SourceContext {
    $scoop = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
    $scoopGlobal = if ($env:SCOOP_GLOBAL) { $env:SCOOP_GLOBAL } else { Join-Path $env:ProgramData 'scoop' }
    $choco = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { Join-Path $env:ProgramData 'chocolatey' }
    [pscustomobject]@{
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PSEdition = $PSVersionTable.PSEdition
        ProcessPath = @(Get-SourcePathEntries $env:PATH)
        PersistedPath = @(Get-SourcePathEntries (([Environment]::GetEnvironmentVariable('Path', 'Machine')) + ';' +
            ([Environment]::GetEnvironmentVariable('Path', 'User'))))
        ScoopRoots = @($scoop, $scoopGlobal)
        ChocolateyRoot = $choco
        HomePath = $HOME
        LocalAppData = $env:LOCALAPPDATA
        AppData = $env:APPDATA
        WindowsRoot = $env:SystemRoot
        VirtualEnv = $env:VIRTUAL_ENV
        CondaPrefix = $env:CONDA_PREFIX
        PathExt = @('.ps1') + @($env:PATHEXT -split ';' | Where-Object { $_ })
    }
}

function Read-SourceText {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -gt 2MB) { throw 'metadata exceeds the 2 MiB read limit' }
    [IO.File]::ReadAllText($item.FullName)
}

function Read-SourceXml {
    param([string]$Path)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new((Read-SourceText $Path)), $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        $document
    } finally { $reader.Dispose() }
}

function Get-SourceMetadata {
    param($Context, [Collections.Generic.List[string]]$Warnings)
    $packages = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $targetCache = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $Context.ScoopRoots) {
        $directories.Add((Join-Path $root 'shims'))
        $apps = Join-Path $root 'apps'
        if (-not (Test-Path -LiteralPath $apps)) { continue }
        try {
            foreach ($app in Get-ChildItem -LiteralPath $apps -Directory -ErrorAction Stop) {
                $current = Join-Path $app.FullName 'current'
                $manifest = Join-Path $current 'manifest.json'
                if (-not (Test-Path -LiteralPath $manifest)) { continue }
                try {
                    $data = Read-SourceText $manifest | ConvertFrom-Json -ErrorAction Stop
                    $packages.Add([pscustomobject]@{ Manager = 'Scoop'; Name = $app.Name; Root = (Resolve-SourceTarget $current -Cache $targetCache);
                        Version = [string]$data.version; Evidence = $manifest; Files = @() })
                    # Only manifest-declared executable directories, never recurse.
                    foreach ($relative in @($data.env_add_path)) {
                        if (-not $relative) { continue }
                        $dir = [IO.Path]::GetFullPath((Join-Path $current $relative))
                        if (Test-SourceChild $dir $app.FullName) { $directories.Add($dir) }
                    }
                } catch { $Warnings.Add("Cannot read $manifest : $($_.Exception.Message)") }
            }
        } catch { $Warnings.Add("Cannot enumerate $apps : $($_.Exception.Message)") }
    }
    $directories.Add((Join-Path $Context.ChocolateyRoot 'bin'))
    $lib = Join-Path $Context.ChocolateyRoot 'lib'
    if (Test-Path -LiteralPath $lib) {
        try {
            foreach ($package in Get-ChildItem -LiteralPath $lib -Directory -ErrorAction Stop) {
                $nuspec = Join-Path $package.FullName ($package.Name + '.nuspec')
                if (-not (Test-Path -LiteralPath $nuspec)) { continue }
                try {
                    $xml = Read-SourceXml $nuspec
                    $version = $xml.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='version']").InnerText
                    $snapshot = Join-Path $Context.ChocolateyRoot ".chocolatey/$($package.Name).$version/.files"
                    $ownedFiles = @()
                    if (Test-Path -LiteralPath $snapshot) {
                        $snapshotXml = Read-SourceXml $snapshot
                        $ownedFiles = @($snapshotXml.SelectNodes('//file') | ForEach-Object { $_.GetAttribute('path') } |
                            Where-Object { [IO.Path]::GetExtension($_) -in '.exe', '.com', '.cmd', '.bat', '.ps1' })
                        # Package snapshot can be stale; never claim a missing file is installed.
                        foreach ($owned in $ownedFiles) {
                            $shim = Join-Path $Context.ChocolateyRoot ('bin/' + [IO.Path]::GetFileName($owned))
                            if ((Test-Path -LiteralPath $shim -PathType Leaf) -and (Test-Path -LiteralPath $owned -PathType Leaf)) {
                                $files.Add($owned)
                            }
                        }
                    }
                    $packages.Add([pscustomobject]@{ Manager = 'Chocolatey'; Name = $package.Name; Root = $package.FullName;
                        Version = $version; Evidence = $nuspec; Files = $ownedFiles })
                } catch { $Warnings.Add("Cannot read $nuspec : $($_.Exception.Message)") }
            }
        } catch { $Warnings.Add("Cannot enumerate $lib : $($_.Exception.Message)") }
    }
    foreach ($relative in 'Microsoft/WinGet/Links', 'Microsoft/WindowsApps') {
        $directories.Add((Join-Path $Context.LocalAppData $relative))
    }
    $ownersByRoot = @{}
    $ownersByFile = @{}
    foreach ($package in $packages) {
        $ownersByRoot[$package.Root.TrimEnd('\', '/')] = $package
        foreach ($file in $package.Files) { $ownersByFile[$file] = $package }
    }
    [pscustomobject]@{ Packages = $packages.ToArray(); Directories = $directories.ToArray(); Files = $files.ToArray();
        TargetCache = $targetCache; OwnersByRoot = $ownersByRoot; OwnersByFile = $ownersByFile }
}

function Get-SourceInstallLocations {
    param([Collections.Generic.List[string]]$Warnings)
    # An Uninstall entry proves registered installation metadata, NOT that
    # winget/Chocolatey originally installed the application. Never read/run its command.
    if (-not $IsWindows) { return }
    foreach ($key in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        try {
            foreach ($child in Get-ChildItem -LiteralPath $key -ErrorAction Stop) {
                $item = Get-ItemProperty -LiteralPath $child.PSPath -Name DisplayName, DisplayVersion, InstallLocation -ErrorAction SilentlyContinue
                if ($item.InstallLocation -and $item.DisplayName) {
                    [pscustomobject]@{ Name = $item.DisplayName; Version = $item.DisplayVersion;
                        Root = $item.InstallLocation.TrimEnd('\'); Evidence = $child.Name }
                }
            }
        } catch { $Warnings.Add("Cannot read installation locations at $key") }
    }
}

function Resolve-SourceTarget {
    param([string]$Path, [Collections.Generic.Dictionary[string, string]]$Cache)
    # Resolve ancestor junctions as well as leaf symlinks. Bounded traversal;
    # do not open executable handles or follow App Execution Alias reparse data.
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $resolved = $root
    foreach ($part in $full.Substring($root.Length).Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $resolved = Join-Path $resolved $part
        if ($null -ne $Cache -and $Cache.ContainsKey($resolved)) { $resolved = $Cache[$resolved]; continue }
        $unresolved = $resolved
        $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
        if ($item.LinkType -in 'SymbolicLink', 'Junction') {
            $target = $item.ResolveLinkTarget($true)
            if (-not $target -or -not $target.Exists) { throw 'link target does not exist' }
            $resolved = $target.FullName
        }
        if ($null -ne $Cache -and $item.PSIsContainer) { $Cache[$unresolved] = $resolved }
    }
    $resolved
}

function Get-SourceAncestorMatch {
    param([string]$Path, [hashtable]$Index)
    $probe = $Path.TrimEnd('\', '/')
    while ($probe) {
        if ($Index.ContainsKey($probe)) { return $Index[$probe] }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
}

function Get-SourceCandidate {
    param([string]$Path, $Context, $Metadata, [hashtable]$InstallLocations)
    $path = [IO.Path]::GetFullPath($Path)
    $record = [ordered]@{
        Name = [IO.Path]::GetFileNameWithoutExtension($path); CommandType = 'Application'; Path = $path;
        Target = $path; Manager = 'Unknown'; Package = $null; Version = $null; VersionSource = $null;
        Confidence = 'unknown'; Evidence = @(); Status = 'present'; ExpectedOverride = $false;
        Identity = $path.ToLowerInvariant()
    }
    if ([IO.Path]::GetExtension($path) -eq '.ps1') { $record.CommandType = 'ExternalScript' }
    $evidence = [Collections.Generic.List[string]]::new()
    $appAliasRoot = Join-Path $Context.LocalAppData 'Microsoft/WindowsApps'
    if (Test-SourceChild $path $appAliasRoot) {
        $record.Manager = 'AppExecutionAlias'; $record.Confidence = 'heuristic'
        $evidence.Add('WindowsApps location; activation is deliberately not attempted')
    }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($record.Manager -ne 'AppExecutionAlias') { $record.Target = Resolve-SourceTarget $path -Cache $Metadata.TargetCache }
    } catch {
        $record.Status = 'unavailable'; $evidence.Add($_.Exception.Message)
        $record.Evidence = $evidence.ToArray()
        return [pscustomobject]$record
    }

    foreach ($root in $Context.ScoopRoots) {
        if (-not (Test-SourceChild $path (Join-Path $root 'shims'))) { continue }
        $shim = [IO.Path]::ChangeExtension($path, '.shim')
        if (Test-Path -LiteralPath $shim) {
            try {
                $text = Read-SourceText $shim
                if ($text -match '(?m)^path\s*=\s*"([^"\r\n]+)"\s*$') {
                    $record.Target = Resolve-SourceTarget $Matches[1] -Cache $Metadata.TargetCache
                    $evidence.Add($shim)
                }
            } catch { $record.Status = 'unavailable'; $evidence.Add("Invalid shim target: $($_.Exception.Message)") }
        }
    }
    # Standard npm .cmd/.ps1 shims point at the same JS entry. Parse only that
    # fixed quoted form; never evaluate script bodies or arbitrary shell syntax.
    if ($item.Extension -in '.cmd', '.ps1' -and [IO.Path]::GetExtension($record.Target) -in '.cmd', '.ps1') {
        try {
            $body = Read-SourceText $path
            $pattern = if ($item.Extension -eq '.cmd') {
                '"%dp0%[\\/](node_modules[\\/][^"\r\n]+)"'
            } else { '"\$basedir[\\/](node_modules[\\/][^"\r\n]+)"' }
            if ($body -match $pattern) {
                $npmRoot = Join-Path $item.DirectoryName 'node_modules'
                $entry = [IO.Path]::GetFullPath((Join-Path $item.DirectoryName $Matches[1]))
                if ((Test-SourceChild $entry $npmRoot) -and (Test-Path -LiteralPath $entry -PathType Leaf)) {
                    $record.Target = Resolve-SourceTarget $entry -Cache $Metadata.TargetCache
                    $record.Manager = 'npm'; $record.Confidence = 'heuristic'
                    $evidence.Add('Standard npm shim target; installation method not proven')
                    $parent = [IO.Path]::GetDirectoryName($entry)
                    for ($depth = 0; $depth -lt 8 -and (Test-SourceChild $parent $npmRoot); $depth++) {
                        $packageJson = Join-Path $parent 'package.json'
                        if (Test-Path -LiteralPath $packageJson) {
                            $packageData = Read-SourceText $packageJson | ConvertFrom-Json -ErrorAction Stop
                            $record.Package = [string]$packageData.name
                            $record.Version = [string]$packageData.version
                            $record.VersionSource = 'package.json'; $evidence.Add($packageJson)
                            break
                        }
                        $parent = [IO.Path]::GetDirectoryName($parent)
                    }
                }
            }
        } catch { $evidence.Add('Script shim metadata unreadable; body was not executed') }
    }
    $owner = @(Get-SourceAncestorMatch $record.Target $Metadata.OwnersByRoot)
    if (-not $owner.Count -and $Metadata.OwnersByFile.ContainsKey($path)) { $owner = @($Metadata.OwnersByFile[$path]) }
    if (-not $owner.Count -and (Test-SourceChild $path (Join-Path $Context.ChocolateyRoot 'bin'))) {
        # Binary Chocolatey shims do not offer Scoop's text sidecar. A unique
        # matching recorded executable is only heuristic, never authoritative.
        $matchesByName = @($Metadata.Packages | Where-Object {
            $_.Manager -eq 'Chocolatey' -and @($_.Files | Where-Object {
                [IO.Path]::GetFileName($_) -eq [IO.Path]::GetFileName($path) -and $_ -ne $path -and
                    (Test-Path -LiteralPath $_ -PathType Leaf)
            }).Count -eq 1
        })
        $record.Manager = 'Chocolatey'; $record.Confidence = 'heuristic'
        $evidence.Add('Chocolatey bin location; binary shim not executed')
        if ($matchesByName.Count -eq 1) {
            $owner = $matchesByName
            $target = @($owner[0].Files | Where-Object {
                [IO.Path]::GetFileName($_) -eq [IO.Path]::GetFileName($path) -and $_ -ne $path -and
                    (Test-Path -LiteralPath $_ -PathType Leaf)
            })[0]
            $record.Target = Resolve-SourceTarget $target -Cache $Metadata.TargetCache
            $evidence.Add('Unique same-name executable in package snapshot (inferred shim target)')
        }
    }
    if ($owner.Count) {
        $record.Manager = $owner[0].Manager; $record.Package = $owner[0].Name
        $record.Version = $owner[0].Version; $record.VersionSource = 'package metadata'
        if ($record.Confidence -eq 'unknown') { $record.Confidence = 'authoritative' }
        $evidence.Add($owner[0].Evidence)
    } elseif ($record.Manager -eq 'Unknown') {
        $locations = @(Get-SourceAncestorMatch $record.Target $InstallLocations)
        if ($locations.Count) {
            $record.Manager = 'RegisteredInstaller'; $record.Package = $locations[0].Name
            $record.Version = $locations[0].Version; $record.VersionSource = 'registered installation'
            $record.Confidence = 'heuristic'; $evidence.Add($locations[0].Evidence)
        } else {
            $known = @(
                @('WinGet', (Join-Path $Context.LocalAppData 'Microsoft/WinGet')),
                @('npm', (Join-Path $Context.AppData 'npm')),
                @('uv', (Join-Path $Context.AppData 'uv')),
                @('uv', (Join-Path $Context.LocalAppData 'uv')),
                @('pipx', (Join-Path $Context.HomePath '.local/share/pipx')),
                @('pipx', (Join-Path $Context.HomePath 'pipx')),
                @('Cargo', (Join-Path $Context.HomePath '.cargo/bin')),
                @('dotnet', (Join-Path $Context.HomePath '.dotnet/tools')),
                @('Windows', $Context.WindowsRoot)
            )
            foreach ($pair in $known) {
                if ((Test-SourceChild $path $pair[1]) -or (Test-SourceChild $record.Target $pair[1])) {
                    $record.Manager = $pair[0]; $record.Confidence = 'heuristic'
                    $evidence.Add("Known location: $($pair[1]); package ownership not proven")
                    break
                }
            }
        }
    }
    foreach ($virtualRoot in @($Context.VirtualEnv, $Context.CondaPrefix)) {
        if (Test-SourceChild $path $virtualRoot) {
            $record.ExpectedOverride = $true; $evidence.Add('Active virtual environment override')
        }
    }
    if (-not $record.Version -and $record.Manager -ne 'AppExecutionAlias' -and
        $record.Status -eq 'present' -and [IO.Path]::GetExtension($record.Target) -eq '.exe') {
        try {
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($record.Target).ProductVersion
            if ($version) { $record.Version = $version; $record.VersionSource = 'PE product version' }
        } catch { $evidence.Add('PE version metadata unavailable') }
    }
    $record.Identity = $record.Target.ToLowerInvariant()
    if ($owner.Count) {
        # Git's bin/git.exe and cmd/git.exe are separate files in one package,
        # not two installations. Keep all candidate paths but count the package once.
        $record.Identity = "$($owner[0].Manager):$($owner[0].Root):$($record.Name)".ToLowerInvariant()
    }
    $record.Evidence = $evidence.ToArray()
    [pscustomobject]$record
}

function Get-SourceResolution {
    param([string]$Name)
    # -ListImported forbids command discovery from auto-importing arbitrary modules.
    @(Get-Command -Name ([WildcardPattern]::Escape($Name)) -All -ListImported -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; CommandType = $_.CommandType.ToString();
                Path = $(if ($_.CommandType -in 'Application', 'ExternalScript') { $_.Path } else { $null });
                AliasTarget = $(if ($_.CommandType -eq 'Alias') { $_.Definition } else { $null });
                ModuleName = $_.ModuleName }
        })
}

function Get-SourcePathWinner {
    param([string]$Name, [object[]]$Candidates, [hashtable]$DirectoryRanks, [string[]]$Extensions)
    $winner = $null
    $best = [int]::MaxValue
    $literalFile = [IO.Path]::GetExtension($Name) -in $Extensions
    foreach ($candidate in $Candidates) {
        $dir = [IO.Path]::GetDirectoryName($candidate.Path)
        if ($candidate.Status -ne 'present' -or -not $DirectoryRanks.ContainsKey($dir)) { continue }
        if ($literalFile -and [IO.Path]::GetFileName($candidate.Path) -ne $Name) { continue }
        $extension = [IO.Path]::GetExtension($candidate.Path)
        for ($i = 0; $i -lt $Extensions.Count; $i++) {
            if ($extension -ne $Extensions[$i]) { continue }
            $rank = $DirectoryRanks[$dir] * ($Extensions.Count + 1) + $i
            if ($rank -lt $best) { $best = $rank; $winner = $candidate.Path }
            break
        }
    }
    $winner
}

function Get-AppSourceReport {
    [CmdletBinding()]
    param([string]$Name, [string]$Path, [switch]$Conflicts)
    if ($Name -and $Path) { throw 'Choose a command name or -Path, not both.' }
    if ($Name -and ($Name -match '[/\\]' -or [WildcardPattern]::ContainsWildcardCharacters($Name))) {
        throw 'Use one literal command name; use -Path for a file path.'
    }
    $context = Get-SourceContext
    $warnings = [Collections.Generic.List[string]]::new()
    $metadata = Get-SourceMetadata $context $warnings
    $locations = @{}
    foreach ($location in @(Get-SourceInstallLocations $warnings)) {
        try {
            $key = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($location.Root.Trim('"'))).TrimEnd('\', '/')
            $locations[$key] = $location
        } catch { $warnings.Add('An invalid registered installation location was skipped') }
    }
    $processRanks = @{}
    $persistedRanks = @{}
    for ($i = 0; $i -lt $context.ProcessPath.Count; $i++) { $processRanks[$context.ProcessPath[$i]] = $i }
    for ($i = 0; $i -lt $context.PersistedPath.Count; $i++) { $persistedRanks[$context.PersistedPath[$i]] = $i }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Path) {
        $null = $paths.Add([IO.Path]::GetFullPath($Path))
    } else {
        $dirs = @($context.ProcessPath) + @($context.PersistedPath) + @($metadata.Directories) |
            Select-Object -Unique
        $baseName = if ($Name) { [IO.Path]::GetFileNameWithoutExtension($Name) } else { '' }
        # Extension-less command names can contain dots (e.g. clang++ or dotnet-tool).
        if ($Name -and [IO.Path]::GetExtension($Name) -notin $context.PathExt) { $baseName = $Name }
        foreach ($dir in $dirs) {
            if ($dir.StartsWith('\\')) { $warnings.Add("Skipped network PATH directory: $dir"); continue }
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            try {
                foreach ($file in Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction Stop) {
                    if ($file.Extension -notin '.exe', '.com', '.cmd', '.bat', '.ps1') { continue }
                    if ($Name -and $file.BaseName -ne $baseName) { continue }
                    $null = $paths.Add($file.FullName)
                }
            } catch { $warnings.Add("Cannot enumerate $dir : $($_.Exception.Message)") }
        }
        foreach ($file in $metadata.Files) {
            if (-not $Name -or [IO.Path]::GetFileNameWithoutExtension($file) -eq $baseName) { $null = $paths.Add($file) }
        }
    }
    $candidates = @($paths | Sort-Object | ForEach-Object {
        try { Get-SourceCandidate $_ $context $metadata $locations }
        catch { $warnings.Add("Cannot inspect $_ : $($_.Exception.Message)") }
    })
    $groups = [Collections.Generic.List[object]]::new()
    foreach ($group in $candidates | Group-Object Name | Sort-Object Name) {
        $copies = @($group.Group | Where-Object Status -eq present | Select-Object -ExpandProperty Identity -Unique).Count
        $findings = [Collections.Generic.List[string]]::new()
        if ($copies -gt 1) { $findings.Add('multiple-installations') }
        if (@($group.Group | Where-Object Status -ne present).Count) { $findings.Add('unavailable-target') }
        $lookupName = if ($Name) { $Name } else { $group.Name }
        $processWinner = Get-SourcePathWinner $lookupName $group.Group $processRanks $context.PathExt
        $persistedWinner = Get-SourcePathWinner $lookupName $group.Group $persistedRanks $context.PathExt
        if ($processWinner -and $persistedWinner) {
            $a = @($group.Group | Where-Object Path -eq $processWinner)[0]
            $b = @($group.Group | Where-Object Path -eq $persistedWinner)[0]
            if ($a.Identity -ne $b.Identity) { $findings.Add('process-vs-persisted-PATH') }
        }
        $resolution = @()
        if ($Name -or $copies -gt 1) { $resolution = @(Get-SourceResolution $(if ($Name) { $Name } else { $group.Name })) }
        if ($resolution.Count -and $resolution[0].CommandType -in 'Alias', 'Function', 'Filter', 'Cmdlet') {
            $findings.Add('shell-wrapper')
        }
        if ($Conflicts -and -not $findings.Count) { continue }
        $groups.Add([pscustomobject]@{ Name = $group.Name; Installations = $copies;
            Resolution = $resolution; ProcessPathCandidate = $processWinner; PersistedPathCandidate = $persistedWinner;
            Findings = $findings.ToArray(); Candidates = @($group.Group) })
    }
    if ($Name -and -not $candidates.Count) {
        $resolution = @(Get-SourceResolution $Name)
        $groups.Add([pscustomobject]@{ Name = $Name; Installations = 0; Resolution = $resolution;
            ProcessPathCandidate = $null; PersistedPathCandidate = $null;
            Findings = @($(if ($resolution.Count) { 'shell-only' } else { 'not-found' })); Candidates = @() })
    }
    [pscustomobject]@{
        SchemaVersion = 1
        Context = [pscustomobject]@{ PowerShellVersion = $context.PowerShellVersion; PSEdition = $context.PSEdition;
            PersistedPathMeaning = 'Machine + User PATH simulation, not a running GUI/server environment';
            ProcessPath = $context.ProcessPath; PersistedPath = $context.PersistedPath }
        Groups = $groups.ToArray(); Warnings = $warnings.ToArray()
    }
}

function Invoke-AppSource {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Command = 'scan', [Parameter(Position = 1)][string]$Name,
        [string]$Path, [switch]$Conflicts, [switch]$Json)
    if ($Command -in 'help', '--help') {
        'appsrc [scan [-Conflicts] | [which] NAME | which -Path FILE] [-Json]'
        return
    }
    if ($Command -notin 'which', 'scan') {
        if ($Name -or $Path) { throw 'usage: appsrc [which] NAME | appsrc which -Path FILE' }
        $Name = $Command; $Command = 'which'
    }
    if ($Command -eq 'which' -and -not $Name -and -not $Path) { throw 'which requires NAME or -Path.' }
    if ($Command -eq 'scan' -and ($Name -or $Path)) { throw 'Use appsrc which NAME or appsrc which -Path FILE.' }
    $report = Get-AppSourceReport -Name $Name -Path $Path -Conflicts:$Conflicts
    if ($Json) { $report | ConvertTo-Json -Depth 12; return }
    Write-Host "PowerShell $($report.Context.PowerShellVersion) $($report.Context.PSEdition) | read-only local evidence"
    Write-Host $report.Context.PersistedPathMeaning
    if ($Name -or $Path) {
        foreach ($group in $report.Groups) {
            Write-Host "`n$($group.Name): $($group.Findings -join ', ')"
            $group.Resolution | Format-Table CommandType, Path, AliasTarget, ModuleName -AutoSize | Out-Host
            Write-Host "Process PATH candidate:   $($group.ProcessPathCandidate)"
            Write-Host "Persisted PATH candidate: $($group.PersistedPathCandidate)"
            $group.Candidates | Format-List Path, Target, Manager, Package, Version, VersionSource, Confidence, Status, ExpectedOverride, Evidence | Out-Host
        }
    } else {
        $report.Groups | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Copies = $_.Installations;
                Sources = ($_.Candidates.Manager | Select-Object -Unique) -join ', ';
                Findings = $_.Findings -join ', '; ProcessCandidate = $_.ProcessPathCandidate }
        } | Format-Table -AutoSize | Out-Host
    }
    foreach ($warning in $report.Warnings) { Write-Warning $warning }
    if (-not $report.Groups.Count) { Write-Host 'No matching findings.' }
}

Export-ModuleMember -Function Get-AppSourceReport, Invoke-AppSource
