#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstrap a fresh Windows machine with these dotfiles.

.DESCRIPTION
    Installs scoop (user-scoped; auto-passes -RunAsAdmin if the shell is
    elevated), then git + PowerShell 7 + chezmoi + uv, then runs `chezmoi init --apply` against this repo. Safe to re-run.
    Works from Windows PowerShell 5.1 or pwsh 7 — chezmoi runs the repo's .ps1
    scripts via pwsh regardless (see [interpreters.ps1] in .chezmoi.toml.tmpl).
    -OrganizationProfile microsoft instead acquires prerequisites through winget,
    including pwsh, Bun and Python before configuration modifiers. It verifies the
    persisted Microsoft settings before a full apply; no Scoop or policy changes.

    Behind the GFW: keep a VPN on for this step. scoop downloads git/pwsh/etc.
    from GitHub releases, which the `useChineseMirror` option does NOT cover
    (that only redirects pip/npm/cargo/go/node at runtime).

.EXAMPLE
    # From a fresh Windows PowerShell / pwsh session:
    irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex

.EXAMPLE
    # Local testing against a checked-out copy:
    ./bootstrap.ps1 -Source .

.EXAMPLE
    # Unattended minimal bootstrap from a checked-out copy:
    ./bootstrap.ps1 -NonInteractive -Role minimal -Name 'Ada Lovelace' -Email 'ada@example.com'
#>
[CmdletBinding()]
param(
    # Remote repo (default) — chezmoi shorthand or full URL.
    [string]$Repo = 'daviddwlee84/dotfiles-windows',
    [string]$Branch = 'main',
    # Local source dir; when set, overrides -Repo (for testing an unpushed tree).
    [string]$Source,
    # A valid initializer is required for no-arg Invoke-Expression; defaulted
    # parameters are not added to $PSBoundParameters, so this does not preseed
    # or otherwise change the interactive path.
    [ValidateSet('workstation', 'minimal')]
    [string]$Role = 'workstation',
    [switch]$NonInteractive,
    [ValidateSet('none', 'microsoft')][string]$OrganizationProfile = 'none',
    [string]$Name,
    [string]$Email
)

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "==> $m" -ForegroundColor Green }

function Test-BootstrapEmail {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -ne $Value.Trim()) { return $false }
    if ($Value -notmatch '^[^@\s]+@[^@\s]+$') { return $false }

    try {
        $address = New-Object System.Net.Mail.MailAddress($Value)
        return $address.Address -eq $Value
    } catch {
        return $false
    }
}

function Assert-BootstrapParameters {
    param(
        [System.Collections.IDictionary]$BoundParameters,
        [switch]$NonInteractive,
        [string]$Role,
        [string]$Name,
        [string]$Email,
        [ValidateSet('none', 'microsoft')][string]$OrganizationProfile = 'none'
    )

    $hasUnattendedValues = $BoundParameters.ContainsKey('Role') -or
                           $BoundParameters.ContainsKey('Name') -or
                           $BoundParameters.ContainsKey('Email')
    if (-not $NonInteractive) {
        if ($hasUnattendedValues) {
            throw '-Role, -Name, and -Email are only valid with -NonInteractive.'
        }
        return
    }

    if (-not $BoundParameters.ContainsKey('Role') -or
        ($Role -ne 'minimal' -and -not ($OrganizationProfile -eq 'microsoft' -and $Role -eq 'workstation'))) {
        throw '-NonInteractive requires an explicit -Role minimal, or -Role workstation with -OrganizationProfile microsoft.'
    }
    if (-not $BoundParameters.ContainsKey('Name') -or [string]::IsNullOrWhiteSpace($Name)) {
        throw '-NonInteractive requires a nonblank -Name.'
    }
    if (-not $BoundParameters.ContainsKey('Email') -or -not (Test-BootstrapEmail $Email)) {
        throw '-NonInteractive requires a valid -Email address.'
    }
}

function Test-Admin {
    # $true when this session is elevated. Works on Windows PowerShell 5.1 and pwsh 7.
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Resolve-BootstrapCommand {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [switch]$AllowExternalScript
    )

    $commandTypes = [System.Management.Automation.CommandTypes]::Application
    if ($AllowExternalScript) {
        $commandTypes = $commandTypes -bor [System.Management.Automation.CommandTypes]::ExternalScript
    }
    $command = Get-Command $CommandName -CommandType $commandTypes -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) { return $null }
    if ($command.PSObject.Properties['Path'] -and $command.Path) { return [string]$command.Path }
    if ($command.Source) { return [string]$command.Source }
    return $null
}

function Get-UnattendedChezmoiConfigCandidates {
    $candidates = @()
    if ($env:CHEZMOI_CONFIG_FILE) { $candidates += $env:CHEZMOI_CONFIG_FILE }

    $configRoots = @()
    if ($env:XDG_CONFIG_HOME) { $configRoots += (Join-Path $env:XDG_CONFIG_HOME 'chezmoi') }
    if ($env:USERPROFILE) { $configRoots += (Join-Path $env:USERPROFILE '.config\chezmoi') }
    foreach ($root in $configRoots) {
        foreach ($extension in 'json', 'jsonc', 'toml', 'yaml', 'yml') {
            $candidates += (Join-Path $root "chezmoi.$extension")
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        if ($candidate -and -not $seen.ContainsKey($candidate)) {
            $seen[$candidate] = $true
            $candidate
        }
    }
}

function Get-ChezmoiSourcePath {
    param([Parameter(Mandatory)][string]$ChezmoiPath)

    try {
        $global:LASTEXITCODE = $null
        $sourceOutput = @(& $ChezmoiPath source-path 2>$null)
        if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0 -or $sourceOutput.Count -eq 0) {
            return $null
        }
        [string]($sourceOutput | Select-Object -Last 1)
    } catch {
        return $null
    }
}

function Assert-UnattendedFreshState {
    param([switch]$NonInteractive)

    if (-not $NonInteractive) { return }

    foreach ($configPath in @(Get-UnattendedChezmoiConfigCandidates)) {
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            throw "Unattended minimal bootstrap requires fresh chezmoi state; existing config found at '$configPath'. Use interactive chezmoi init or edit the existing chezmoi data/config instead."
        }
    }

    $chezmoiPath = Resolve-BootstrapCommand chezmoi
    if (-not $chezmoiPath) { return }
    $sourcePath = Get-ChezmoiSourcePath -ChezmoiPath $chezmoiPath
    if ($sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Unattended minimal bootstrap requires fresh chezmoi state; existing source found at '$sourcePath'. Use interactive chezmoi init or edit the existing chezmoi data/config instead."
    }
}

function Get-ScoopRoot {
    if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
}

function Reset-ScoopRepos {
    # scoop's core repo + each bucket are disposable git indexes. Hard-reset
    # CRLF-renormalized clones before retrying a failed scoop operation.
    $gitPath = Resolve-BootstrapCommand git
    if (-not $gitPath) { return }
    $root = Get-ScoopRoot
    $repos = @()
    $core = Join-Path $root 'apps\scoop\current'
    if (Test-Path (Join-Path $core '.git')) { $repos += $core }
    $bucketsDir = Join-Path $root 'buckets'
    if (Test-Path $bucketsDir) {
        foreach ($b in (Get-ChildItem $bucketsDir -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path (Join-Path $b.FullName '.git')) { $repos += $b.FullName }
        }
    }
    foreach ($r in $repos) {
        Info "  reset --hard $(Split-Path $r -Leaf)"
        & $gitPath -C $r reset --hard HEAD 2>$null
    }
}

function Invoke-ScoopAttempt {
    param([string[]]$ScoopArgs)

    $scoopPath = Resolve-BootstrapCommand scoop -AllowExternalScript
    if (-not $scoopPath) { throw 'scoop command not found after installation.' }

    $global:LASTEXITCODE = $null
    & $scoopPath @ScoopArgs | Out-Host
    if ($null -eq $LASTEXITCODE) { return $null }
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE }
}

function Get-ScoopAttemptExitCode {
    param($AttemptResult)

    if ($null -eq $AttemptResult -or -not $AttemptResult.PSObject.Properties['ExitCode']) {
        throw 'scoop attempt returned no exit-code result.'
    }
    $exitCode = 0
    if (-not [int]::TryParse([string]$AttemptResult.ExitCode, [ref]$exitCode)) {
        throw 'scoop attempt returned an invalid exit-code result.'
    }
    $exitCode
}

function Invoke-Scoop {
    # A bucket pull can fail on phantom CRLF changes. Reset disposable indexes
    # and retry once, but never report success after a failed or missing result.
    param([Parameter(ValueFromRemainingArguments)][string[]]$ScoopArgs)

    $exitCode = Get-ScoopAttemptExitCode (Invoke-ScoopAttempt -ScoopArgs $ScoopArgs)
    if ($exitCode -eq 0) { return }

    Info "scoop $($ScoopArgs -join ' ') failed (exit $exitCode) -- resetting scoop repos and retrying once"
    Reset-ScoopRepos

    $retryExitCode = Get-ScoopAttemptExitCode (Invoke-ScoopAttempt -ScoopArgs $ScoopArgs)
    if ($retryExitCode -ne 0) {
        throw "scoop $($ScoopArgs -join ' ') failed after retry (exit $retryExitCode)."
    }
}

function Initialize-Scoop {
    if (Resolve-BootstrapCommand scoop -AllowExternalScript) { return }

    $installer = [scriptblock]::Create((Invoke-RestMethod get.scoop.sh))
    if (Test-Admin) {
        Info 'Installing scoop (elevated console: passing -RunAsAdmin)'
        & $installer -RunAsAdmin
    } else {
        Info 'Installing scoop'
        & $installer
    }
}

function Initialize-GitForScoop {
    # Install git first and prevent Git for Windows from rewriting scoop's LF
    # manifests. Keep this mirror aligned with .chezmoitemplates/git/gitconfig.
    if (-not (Resolve-BootstrapCommand git)) {
        Info 'Installing git'
        Invoke-Scoop install git
    }

    $gitPath = Resolve-BootstrapCommand git
    if (-not $gitPath) { return }
    $autocrlf = & $gitPath config --global core.autocrlf 2>$null
    if ([string]::IsNullOrWhiteSpace($autocrlf) -or $autocrlf -eq 'true') {
        Info "git core.autocrlf was '$autocrlf' -> setting 'input' (prevents scoop bucket CRLF churn)"
        & $gitPath config --global core.autocrlf input
    }
    Reset-ScoopRepos
}

function Install-BaselineTools {
    Info 'Installing 7zip, PowerShell 7, chezmoi, uv'
    $pwshMissing = -not (Resolve-BootstrapCommand pwsh)
    if ($pwshMissing) {
        # Refresh Scoop and bucket metadata so `install pwsh` resolves the current
        # stable manifest. This does not upgrade an already-installed pwsh.
        Invoke-Scoop update
    }

    Invoke-Scoop install 7zip
    foreach ($tool in 'pwsh', 'chezmoi', 'uv') {
        if (-not (Resolve-BootstrapCommand $tool)) { Invoke-Scoop install $tool }
    }
}

function ConvertTo-BootstrapPathEntries {
    param([AllowNull()][string[]]$PathValues)

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in $PathValues) {
        $expandedValue = [Environment]::ExpandEnvironmentVariables([string]$value)
        foreach ($entry in ($expandedValue -split ';')) {
            $candidate = $entry.Trim()
            if ($candidate -and $seen.Add($candidate)) {
                $candidate
            }
        }
    }
}

function Merge-BootstrapPath {
    param([AllowNull()][string[]]$PathValues)
    @(ConvertTo-BootstrapPathEntries -PathValues $PathValues) -join ';'
}

function Get-PersistedBootstrapPath {
    param([ValidateSet('Machine', 'User')][string]$Scope)
    [System.Environment]::GetEnvironmentVariable('Path', $Scope)
}

function Update-BootstrapPath {
    # Keep this self-contained mirror aligned with
    # scripts/windows-path-precedence.ps1: process-only/portable entries first,
    # persisted User entries next in stored order, and Machine entries last.
    $processEntries = @(ConvertTo-BootstrapPathEntries -PathValues $env:PATH)
    $userEntries = @(ConvertTo-BootstrapPathEntries -PathValues (
        Get-PersistedBootstrapPath -Scope User
    ))
    $machineEntries = @(ConvertTo-BootstrapPathEntries -PathValues (
        Get-PersistedBootstrapPath -Scope Machine
    ))

    $persisted = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in @($userEntries) + @($machineEntries)) {
        $null = $persisted.Add($entry)
    }
    $processOnlyEntries = @($processEntries | Where-Object {
        -not $persisted.Contains($_)
    })

    $env:PATH = Merge-BootstrapPath -PathValues @(
        $processOnlyEntries -join ';'
        $userEntries -join ';'
        $machineEntries -join ';'
    )
}

function Invoke-PwshProbeProcess {
    param([Parameter(Mandatory)][string]$Path)

    $probeCommand = @'
$payload = [ordered]@{
    PSEdition = [string]$PSVersionTable.PSEdition
    Major = [int]$PSVersionTable.PSVersion.Major
    Version = $PSVersionTable.PSVersion.ToString()
}
[Console]::Out.WriteLine('__DOTFILES_BOOTSTRAP_PWSH__' + ($payload | ConvertTo-Json -Compress))
'@

    try {
        $output = @(& $Path -NoProfile -NonInteractive -Command $probeCommand 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    } catch {
        throw "PowerShell candidate '$Path' could not be launched: $($_.Exception.Message)"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-PwshRuntime {
    param([Parameter(Mandatory)][string]$Path)

    $probe = Invoke-PwshProbeProcess -Path $Path
    if ($probe.ExitCode -ne 0) {
        throw "PowerShell candidate '$Path' exited with code $($probe.ExitCode)."
    }

    $marker = '__DOTFILES_BOOTSTRAP_PWSH__'
    $markedLine = @($probe.Output | ForEach-Object { [string]$_ } |
        Where-Object { $_.StartsWith($marker) } | Select-Object -Last 1)
    if ($markedLine.Count -ne 1) {
        throw "PowerShell candidate '$Path' returned no valid version probe result."
    }

    try {
        $data = $markedLine[0].Substring($marker.Length) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "PowerShell candidate '$Path' returned an invalid version probe result."
    }

    $major = 0
    if (-not [int]::TryParse([string]$data.Major, [ref]$major) -or
        [string]::IsNullOrWhiteSpace([string]$data.Version) -or
        [string]::IsNullOrWhiteSpace([string]$data.PSEdition)) {
        throw "PowerShell candidate '$Path' returned an incomplete version probe result."
    }
    if ([string]$data.PSEdition -ne 'Core') {
        throw "PowerShell candidate '$Path' is PSEdition '$($data.PSEdition)'; Core is required."
    }
    $runtimeVersion = $null
    # Compare the full version, not just Major: modern scripts depend on the
    # .NET 8 / native-argument baseline. This probe itself remains 5.1-compatible.
    $numericVersion = ([string]$data.Version -split '[-+]', 2)[0]
    if (-not [version]::TryParse($numericVersion, [ref]$runtimeVersion)) {
        throw "PowerShell candidate '$Path' returned an invalid version '$($data.Version)'."
    }
    if ($runtimeVersion -lt [version]'7.4') {
        throw "PowerShell candidate '$Path' is version '$($data.Version)'; version 7.4 or newer is required. Upgrade the owning installation (for Scoop: scoop update pwsh), open a new terminal, then retry bootstrap."
    }

    [pscustomobject]@{
        Path = $Path
        PSEdition = [string]$data.PSEdition
        Major = $major
        Version = [string]$data.Version
    }
}

function Get-RequiredPwshRuntime {
    $pwshPath = Resolve-BootstrapCommand pwsh
    if (-not $pwshPath) {
        throw 'pwsh not found on PATH after install — open a new terminal and re-run bootstrap.'
    }
    Get-PwshRuntime -Path $pwshPath
}

function Invoke-ChezmoiCommand {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [ValidateSet('none', 'microsoft')][string]$OrganizationProfile = 'none',
        [string]$PowerShellExecutable,
        [string]$PythonExecutable
    )

    $savedOrganization = $env:DOTFILES_BOOTSTRAP_ORGANIZATION_PROFILE
    $savedPowerShell = $env:DOTFILES_BOOTSTRAP_POWERSHELL_EXECUTABLE
    $savedPython = $env:DOTFILES_BOOTSTRAP_PYTHON_EXECUTABLE
    try {
        $env:DOTFILES_BOOTSTRAP_ORGANIZATION_PROFILE = $OrganizationProfile
        $env:DOTFILES_BOOTSTRAP_POWERSHELL_EXECUTABLE = $PowerShellExecutable
        $env:DOTFILES_BOOTSTRAP_PYTHON_EXECUTABLE = $PythonExecutable
        & $Path @ArgumentList
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "chezmoi $($ArgumentList[0]) failed (exit $exitCode)."
        }
    } finally {
        $env:DOTFILES_BOOTSTRAP_ORGANIZATION_PROFILE = $savedOrganization
        $env:DOTFILES_BOOTSTRAP_POWERSHELL_EXECUTABLE = $savedPowerShell
        $env:DOTFILES_BOOTSTRAP_PYTHON_EXECUTABLE = $savedPython
    }
}

function Test-ChezmoiSourceRepo {
    param([Parameter(Mandatory)][string]$Path)

    $sourcePath = Get-ChezmoiSourcePath -ChezmoiPath $Path
    return [bool]($sourcePath -and (Test-Path -LiteralPath (Join-Path $sourcePath '.git')))
}

function Get-UnattendedChezmoiArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('workstation', 'minimal')][string]$Role,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Email,
        [ValidateSet('none', 'microsoft')][string]$OrganizationProfile = 'none'
    )

    @(
        '--no-tty'
        '--promptDefaults'
        '--promptChoice'
        "Role: workstation (full desktop) or minimal (shell only)=$Role"
        '--promptChoice'
        "Organization profile (none|microsoft)=$OrganizationProfile"
        '--promptString'
        "Your full name (git)=$Name"
        '--promptString'
        "Your git email=$Email"
    )
}

function Assert-MicrosoftChezmoiConfiguration {
    param([string]$ChezmoiPath, [string]$Source, [string]$PowerShellExecutable, [string]$PythonExecutable)
    $arguments = @('data', '--format', 'json')
    if ($Source) { $arguments += @('--source', $Source) }
    $raw = @(& $ChezmoiPath @arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'Cannot verify Microsoft config; apply was not started.' }
    $data = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
    if ($data.organizationProfile -ne 'microsoft' -or $data.windowsToolSources.schemaVersion -ne 1 -or
        -not $PowerShellExecutable -or $data.powerShellExecutable -ne $PowerShellExecutable -or
        -not $PythonExecutable -or $data.pythonExecutable -ne $PythonExecutable) {
        throw 'Source/config does not support the selected Microsoft runtimes and catalog; apply was not started. Use the branch containing the Microsoft profile implementation.'
    }
}

function Invoke-ChezmoiSetup {
    param(
        [Parameter(Mandatory)][string]$ChezmoiPath,
        [string]$Repo = 'daviddwlee84/dotfiles-windows',
        [string]$Branch = 'main',
        [string]$Source,
        [ValidateSet('workstation', 'minimal')][string]$Role,
        [switch]$NonInteractive,
        [string]$Name,
        [string]$Email,
        [ValidateSet('none', 'microsoft')][string]$OrganizationProfile = 'none',
        [string]$PowerShellExecutable,
        [string]$PythonExecutable
    )

    $promptArgs = if ($NonInteractive) {
        @(Get-UnattendedChezmoiArguments -Role $Role -Name $Name -Email $Email -OrganizationProfile $OrganizationProfile)
    } else {
        @()
    }
    # Invoke-ChezmoiCommand freezes the pre-install choice in the child's env;
    # unlike --override-data, the config template persists those values.

    if ($OrganizationProfile -eq 'microsoft') {
        if ($Source) {
            $arguments = @('init', '--source', $Source) + $promptArgs
        } elseif (-not $NonInteractive -and (Test-ChezmoiSourceRepo -Path $ChezmoiPath)) {
            $arguments = @('update', '--apply=false', '--init') + $promptArgs
        } else {
            $arguments = @('init', '--branch', $Branch, $Repo) + $promptArgs
        }
        Invoke-ChezmoiCommand -Path $ChezmoiPath -ArgumentList $arguments -OrganizationProfile microsoft -PowerShellExecutable $PowerShellExecutable -PythonExecutable $PythonExecutable
        Assert-MicrosoftChezmoiConfiguration -ChezmoiPath $ChezmoiPath -Source $Source -PowerShellExecutable $PowerShellExecutable -PythonExecutable $PythonExecutable
        $applyArguments = @('apply')
        if ($Source) { $applyArguments += @('--source', $Source) }
        if ($NonInteractive) { $applyArguments += '--no-tty' }
        Info 'Microsoft prerequisites and persisted profile verified; starting full chezmoi apply'
        Invoke-ChezmoiCommand -Path $ChezmoiPath -ArgumentList $applyArguments -OrganizationProfile microsoft -PowerShellExecutable $PowerShellExecutable -PythonExecutable $PythonExecutable
        return
    }

    if ($Source) {
        $arguments = @('init', '--apply', '--source', $Source) + $promptArgs
        Info "chezmoi init --apply --source $Source"
        Invoke-ChezmoiCommand -Path $ChezmoiPath -ArgumentList $arguments -OrganizationProfile $OrganizationProfile -PowerShellExecutable $PowerShellExecutable -PythonExecutable $PythonExecutable
        return
    }

    if (-not $NonInteractive -and (Test-ChezmoiSourceRepo -Path $ChezmoiPath)) {
        Info 'chezmoi update (git pull + apply — picks up new commits)'
        Invoke-ChezmoiCommand -Path $ChezmoiPath -ArgumentList (@('update', '--init') + $promptArgs) -OrganizationProfile $OrganizationProfile -PowerShellExecutable $PowerShellExecutable -PythonExecutable $PythonExecutable
        return
    }

    $arguments = @('init', '--apply', '--branch', $Branch, $Repo) + $promptArgs
    Info "chezmoi init --apply --branch $Branch $Repo"
    Invoke-ChezmoiCommand -Path $ChezmoiPath -ArgumentList $arguments -OrganizationProfile $OrganizationProfile -PowerShellExecutable $PowerShellExecutable -PythonExecutable $PythonExecutable
}

# This prerequisite-only mirror intentionally remains PS 5.1 compatible.
function Test-BootstrapScoopPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $roots = @((Join-Path $HOME 'scoop'), $env:SCOOP, $env:SCOOP_GLOBAL)
    if ($env:ProgramData) { $roots += Join-Path $env:ProgramData 'scoop' }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $expanded = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($root)).TrimEnd('\', '/')
        $candidate = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim('"'))).TrimEnd('\', '/')
        if ($candidate.Equals($expanded, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($expanded + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Resolve-BootstrapOrganizationProfile {
    param([string]$ExplicitProfile, [switch]$NonInteractive)
    if ($ExplicitProfile) { return $ExplicitProfile }
    $files = @(Get-UnattendedChezmoiConfigCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($files.Count -gt 1) { throw 'Multiple chezmoi configs: specify -OrganizationProfile before bootstrap.' }
    if ($files.Count -eq 1) {
        $text = [IO.File]::ReadAllText($files[0])
        if ([IO.Path]::GetExtension($files[0]) -eq '.json') {
            $value = ($text | ConvertFrom-Json -ErrorAction Stop).data.organizationProfile
        } elseif ([IO.Path]::GetExtension($files[0]) -eq '.toml') {
            $section = [regex]::Match($text, '(?ms)^\s*\[data\]\s*\r?\n(?<body>.*?)(?=^\s*\[|\z)').Groups['body'].Value
            $matches = [regex]::Matches($section, '(?m)^\s*organizationProfile\s*=\s*["''](none|microsoft)["'']\s*(?:#.*)?$')
            if ($section -match '(?m)^\s*organizationProfile\s*=' -and $matches.Count -ne 1) { throw 'Cannot safely read organizationProfile; specify it explicitly.' }
            $value = if ($matches.Count) { $matches[0].Groups[1].Value } else { 'none' }
        } else { throw 'Specify -OrganizationProfile explicitly for this config format.' }
        if (-not $value) { return 'none' }
        if ($value -notin 'none', 'microsoft') { throw 'Invalid stored organizationProfile.' }
        return $value
    }
    if ($NonInteractive) { return 'none' }
    $answer = Read-Host 'Organization profile (none|microsoft) [none]'
    if (-not $answer) { return 'none' }
    if ($answer -notin 'none', 'microsoft') { throw 'Organization profile must be none or microsoft.' }
    $answer
}

function Get-BootstrapRegisteredCandidates {
    # Metadata discovery only. Installation does not refresh the parent's PATH.
    # Do not persist a versioned Program Files\WindowsApps package directory as pwsh.
    param([string]$Name)
    if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$Name.exe"
        if ($Name -in 'pwsh', 'winget') { Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$Name.exe" }
    }
    if ($Name -in 'pwsh', 'winget' -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        $packageName = if ($Name -eq 'pwsh') { 'Microsoft.PowerShell' } else { 'Microsoft.DesktopAppInstaller' }
        $registeredPackages = try { @(Get-AppxPackage -Name $packageName -ErrorAction Stop) } catch { @() }
        foreach ($package in $registeredPackages) {
            if ($Name -eq 'winget' -and $package.InstallLocation) {
                Join-Path $package.InstallLocation 'winget.exe'
            } elseif ($env:LOCALAPPDATA -and $package.PackageFamilyName) {
                Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$($package.PackageFamilyName)\pwsh.exe"
            }
        }
    }
    $programRoots = @($env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $programRoots) {
        switch ($Name) {
            'pwsh' { Join-Path $root 'PowerShell\7\pwsh.exe' }
            'git' { Join-Path $root 'Git\cmd\git.exe' }
            '7z' { Join-Path $root '7-Zip\7z.exe' }
        }
    }
    if ($Name -eq 'pwsh') {
        foreach ($registryRoot in 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions', 'HKCU:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions') {
            foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
                $location = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue).InstallLocation
                if ($location -and $location -notmatch '(?i)preview') { Join-Path $location 'pwsh.exe' }
            }
        }
    }
    if ($Name -eq 'python') {
        # PEP 514 covers per-user official installers even when PrependPath is off.
        foreach ($registryRoot in 'HKCU:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore') {
            foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending)) {
                if ($key.PSChildName -notmatch '^3\.(?:1[1-9]|[2-9][0-9])(?:-|$)') { continue }
                $install = Get-Item -LiteralPath (Join-Path $key.PSPath 'InstallPath') -ErrorAction SilentlyContinue
                if (-not $install) { continue }
                $executable = [string]$install.GetValue('ExecutablePath')
                if ($executable) { $executable }
                else {
                    $location = [string]$install.GetValue('')
                    if ($location) { Join-Path $location 'python.exe' }
                }
            }
        }
    }
}

function Test-BootstrapPythonAlias {
    param([string]$Path)
    # The in-box Python app-execution alias opens the Store; it is not Python.
    $Path -match '(?i)[\\/]Microsoft[\\/]WindowsApps[\\/]python(?:3)?\.exe$'
}

function Resolve-BootstrapOrganizationCommand {
    param([string]$Name)
    $candidates = @(
        Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        Get-BootstrapRegisteredCandidates -Name $Name
    )
    foreach ($path in @($candidates | Select-Object -Unique)) {
        if (-not $path -or (Test-BootstrapScoopPath $path)) { continue }
        if ($Name -eq 'python' -and (Test-BootstrapPythonAlias $path)) { continue }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    $null
}

function Update-OrganizationBootstrapPath {
    param([string[]]$ExecutablePaths = @())
    Update-BootstrapPath
    $directories = @($ExecutablePaths | Where-Object { $_ } | ForEach-Object { Split-Path -Parent $_ })
    if ($env:LOCALAPPDATA) {
        $directories += Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
        $directories += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    }
    $env:PATH = Merge-BootstrapPath -PathValues @(($directories -join ';'), $env:PATH)
    $env:PATH = @($env:PATH -split ';' | Where-Object { $_ -and -not (Test-BootstrapScoopPath $_) }) -join ';'
}

function Invoke-OrganizationBootstrapWinget {
    param([Parameter(Mandatory)][string]$Winget, [Parameter(Mandatory)][string]$PackageId)
    $arguments = @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--no-upgrade', '--silent', '--disable-interactivity', '--accept-source-agreements', '--accept-package-agreements')
    if ($PackageId -eq 'Python.Python.3.14') { $arguments += @('--scope', 'user') }
    # Windows PowerShell 5.1 turns native stderr into ErrorRecords. Judge the exit
    # code, not a harmless progress line; a launch failure must not inherit exit 0.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = $null
        & $Winget @arguments 2>&1 | Out-Host
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($null -eq $code -or ($code -ne 0 -and $code -ne -1978335189)) { throw "Approved bootstrap package $PackageId failed (exit $code); no alternate source or scope attempted." }
}

function Test-BootstrapPythonRuntime {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-BootstrapPythonAlias $Path) { throw 'The Windows Store Python alias is not a usable interpreter.' }
    $output = @(& $Path -I -c "import sys; print('__DOTFILES_PYTHON__%d.%d.%d' % sys.version_info[:3])" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Approved Python could not run at $Path; no alternative source attempted." }
    $versionLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^__DOTFILES_PYTHON__\d+\.\d+\.\d+$' } | Select-Object -Last 1)
    if ($versionLine.Count -ne 1 -or [version]($versionLine[0].Substring('__DOTFILES_PYTHON__'.Length)) -lt [version]'3.11') {
        throw 'Microsoft full apply requires an approved Python 3.11 or newer.'
    }
}

function Get-BootstrapConfiguredRuntime {
    param([ValidateSet('powerShellExecutable', 'pythonExecutable')][string]$Key)
    if (-not @(Get-UnattendedChezmoiConfigCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count) { return $null }
    $reader = Resolve-BootstrapOrganizationCommand chezmoi
    if (-not $reader) { throw 'Existing config requires a non-Scoop chezmoi reader before Microsoft migration.' }
    $raw = @(& $reader data --format json 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the existing runtime override; bootstrap has not installed anything.' }
    $data = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
    $path = [string]$data.$Key
    if ($path -and ($path -notmatch '^[a-zA-Z]:[\\/]' -or (Test-BootstrapScoopPath $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf))) {
        throw "Existing $Key is missing, relative or Scoop-owned; review the explicit override before migration."
    }
    $path
}

function Get-BootstrapPowerShellOverride { Get-BootstrapConfiguredRuntime -Key powerShellExecutable }
function Get-BootstrapPythonOverride { Get-BootstrapConfiguredRuntime -Key pythonExecutable }

function Get-OrganizationBootstrapPackages {
    # Keep package IDs aligned with windows-tool-sources.json (covered by tests).
    # Bun and Python must precede apply: modify_ scripts run before run_after packages.
    [ordered]@{
        pwsh = 'Microsoft.PowerShell'; git = 'Git.Git'; chezmoi = 'twpayne.chezmoi'
        uv = 'astral-sh.uv'; bun = 'Oven-sh.Bun'; python = 'Python.Python.3.14'; '7z' = '7zip.7zip'
    }
}

function Test-OrganizationBootstrapRuntime {
    param([string]$Name, [string]$Path)
    if ($Name -eq 'pwsh') { $null = Get-PwshRuntime -Path $Path; return }
    if ($Name -eq 'python') { Test-BootstrapPythonRuntime -Path $Path; return }
    if ($Name -eq '7z') { return }
    $output = @(& $Path --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not $output) { throw "Bootstrap prerequisite $Name failed its version probe at $Path; full apply was not started." }
}

function Install-OrganizationBaselineTools {
    param([string]$PowerShellExecutable, [string]$PythonExecutable)
    $winget = Resolve-BootstrapOrganizationCommand winget
    if (-not $winget) { throw 'Microsoft profile requires approved App Installer/winget; install it through IT first.' }
    $packages = Get-OrganizationBootstrapPackages
    $selected = [ordered]@{}
    foreach ($name in $packages.Keys) {
        $path = if ($name -eq 'pwsh' -and $PowerShellExecutable) { $PowerShellExecutable }
            elseif ($name -eq 'python' -and $PythonExecutable) { $PythonExecutable }
            else { Resolve-BootstrapOrganizationCommand $name }
        if (-not $path) {
            Info "Installing fresh-machine prerequisite $($packages[$name]) through winget"
            Invoke-OrganizationBootstrapWinget -Winget $winget -PackageId $packages[$name]
            Update-OrganizationBootstrapPath -ExecutablePaths @($selected.Values)
            $path = Resolve-BootstrapOrganizationCommand $name
        }
        if (-not $path) { throw "$($packages[$name]) is installed but its executable is unavailable. Check registration/IT policy; no alternate source was attempted and apply has not started." }
        if (Test-BootstrapScoopPath $path) { throw "Scoop prerequisite is not allowed: $path" }
        Test-OrganizationBootstrapRuntime -Name $name -Path $path
        $selected[$name] = $path
        Update-OrganizationBootstrapPath -ExecutablePaths @($selected.Values)
    }
    [pscustomobject]@{
        PowerShellExecutable = $selected['pwsh']; PythonExecutable = $selected['python']
        ChezmoiExecutable = $selected['chezmoi']; Executables = $selected
    }
}

function Invoke-Bootstrap {
    [CmdletBinding()]
    param(
        [string]$Repo = 'daviddwlee84/dotfiles-windows',
        [string]$Branch = 'main',
        [string]$Source,
        [ValidateSet('workstation', 'minimal')]
        [string]$Role = 'workstation',
        [switch]$NonInteractive,
        [ValidateSet('none', 'microsoft')][string]$OrganizationProfile,
        [string]$Name,
        [string]$Email
    )

    $selectedOrganization = Resolve-BootstrapOrganizationProfile -ExplicitProfile $OrganizationProfile -NonInteractive:$NonInteractive
    Assert-BootstrapParameters -BoundParameters $PSBoundParameters `
        -NonInteractive:$NonInteractive -Role $Role -Name $Name -Email $Email -OrganizationProfile $selectedOrganization
    # Normalize before unattended-state probes or installer command resolution.
    Update-BootstrapPath
    if ($selectedOrganization -eq 'microsoft') {
        $env:PATH = @($env:PATH -split ';' | Where-Object { $_ -and -not (Test-BootstrapScoopPath $_) }) -join ';'
    }
    Assert-UnattendedFreshState -NonInteractive:$NonInteractive

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Info 'Windows dotfiles bootstrap'

        if ($selectedOrganization -eq 'microsoft') {
            $savedPwsh = Get-BootstrapPowerShellOverride
            $savedPython = Get-BootstrapPythonOverride
            if ($savedPwsh) { $null = Get-PwshRuntime -Path $savedPwsh }
            if ($savedPython) { Test-BootstrapPythonRuntime -Path $savedPython }
            $foundation = Install-OrganizationBaselineTools -PowerShellExecutable $savedPwsh -PythonExecutable $savedPython
            Invoke-ChezmoiSetup -ChezmoiPath $foundation.ChezmoiExecutable -Repo $Repo -Branch $Branch -Source $Source `
                -Role $Role -NonInteractive:$NonInteractive -Name $Name -Email $Email `
                -OrganizationProfile microsoft -PowerShellExecutable $foundation.PowerShellExecutable -PythonExecutable $foundation.PythonExecutable
            return
        }

        if ((Get-ExecutionPolicy -Scope CurrentUser) -notin 'RemoteSigned', 'Unrestricted', 'Bypass') {
            Info 'Setting execution policy: RemoteSigned (CurrentUser)'
            Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        }

        Initialize-Scoop
        # A fresh Scoop install persists its shim path; merge it into this process
        # before resolving the external scoop/git commands used by later stages.
        Update-BootstrapPath
        Initialize-GitForScoop
        Install-BaselineTools
        Update-BootstrapPath

        $runtime = Get-RequiredPwshRuntime
        Ok "PowerShell $($runtime.Version) ($($runtime.PSEdition)): $($runtime.Path)"

        $chezmoiPath = Resolve-BootstrapCommand chezmoi
        if (-not $chezmoiPath) {
            throw 'chezmoi not found on PATH after install — open a new terminal and re-run bootstrap.'
        }

        Invoke-ChezmoiSetup -ChezmoiPath $chezmoiPath -Repo $Repo -Branch $Branch -Source $Source `
            -Role $Role -NonInteractive:$NonInteractive -Name $Name -Email $Email

        Ok 'Done. Open a new pwsh session to load the managed profile.'
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

# Dot-sourcing loads testable functions; file execution and the canonical
# `irm .../bootstrap.ps1 | iex` path still run the bootstrap with no arguments.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Bootstrap @PSBoundParameters
}
