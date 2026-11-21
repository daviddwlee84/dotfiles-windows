#Requires -Version 7.4
#Requires -PSEdition Core
# Source decisions, not an App Control implementation. Never executes candidates.
# Callers supply rendered data, or explicitly load chezmoi data for a CLI action.
function Initialize-OrganizationPolicy {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Catalog)
    $profile = if ($Data['organizationProfile']) { [string]$Data['organizationProfile'] } else { 'none' }
    if ($profile -notin 'none', 'microsoft') { throw "Unknown organizationProfile '$profile'" }
    $known = @($Catalog.tools.id)
    foreach ($approval in @($Data['organizationSourceApprovals'])) {
        if ($approval -and $approval -notin $known) { throw "Unknown organization source approval '$approval'" }
    }
    $script:OrganizationPolicy = [pscustomobject]@{ Profile = $profile; Data = $Data; Catalog = $Catalog }
}

function Get-OrganizationPolicy {
    if (Get-Variable OrganizationPolicy -Scope Script -ErrorAction SilentlyContinue) { return $script:OrganizationPolicy }
    [pscustomobject]@{ Profile = 'none'; Data = @{}; Catalog = @{ tools = @() } }
}

function Import-OrganizationPolicyData {
    # No-profile maintenance entry points must not infer policy from a stale env var.
    $commands = @(Get-Command chezmoi -CommandType Application -All -ErrorAction Stop)
    $command = $commands | Where-Object { -not (Test-OrganizationScoopPath $_.Source) } | Select-Object -First 1
    if (-not $command) {
        # Preserve ordinary Scoop installations, but never execute Scoop to discover
        # that a machine is restricted. Ambiguous formats require a non-Scoop reader.
        $config = if ($env:CHEZMOI_CONFIG_FILE) { $env:CHEZMOI_CONFIG_FILE } elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'chezmoi\chezmoi.toml' } else { Join-Path $HOME '.config\chezmoi\chezmoi.toml' }
        if (-not (Test-Path -LiteralPath $config) -or [IO.Path]::GetExtension($config) -ne '.toml') {
            throw 'Cannot establish legacy profile without executing Scoop; use a non-Scoop chezmoi.'
        }
        $configText = Get-Content -LiteralPath $config -Raw
        $profileLine = [regex]::Match($configText, '(?m)^\s*organizationProfile\s*=\s*["''](none|microsoft)["'']\s*(?:#.*)?$')
        if (($configText -match '(?m)^\s*organizationProfile\s*=' -and (-not $profileLine.Success -or $profileLine.Groups[1].Value -ne 'none')) -or $env:DOTFILES_ORGANIZATION_PROFILE -eq 'microsoft') {
            throw 'Use an approved non-Scoop chezmoi to read Microsoft policy; no fallback was attempted.'
        }
        $command = $commands[0]
    }
    $json = @(& $command.Source data --format json 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw 'Cannot read chezmoi organization policy.' }
    $data = ($json -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if (-not $data['windowsToolSources']) {
        if ($data['organizationProfile'] -eq 'microsoft') { throw 'Organization source catalog is missing.' }
        $data['windowsToolSources'] = @{ tools = @() }
    }
    Initialize-OrganizationPolicy -Data $data -Catalog $data.windowsToolSources
    Get-OrganizationPolicy
}

function Test-MicrosoftOrganization { (Get-OrganizationPolicy).Profile -eq 'microsoft' }

function Get-OrganizationSourceDecision {
    param([Parameter(Mandatory)][string]$Id,
        [ValidateSet('install', 'upgrade', 'execute', 'build')][string]$Operation = 'install')
    $policy = Get-OrganizationPolicy
    $tool = @($policy.Catalog.tools | Where-Object id -EQ $Id) | Select-Object -First 1
    $state = 'allowed'; $reason = 'Legacy profile; existing source policy applies.'
    if ($policy.Profile -eq 'microsoft') {
        $state = 'pending-approval'; $reason = 'Source is not in the organization catalog.'
        if ($Id -eq 'scoop' -or ($tool -and $tool.provider -eq 'blocked')) {
            $state = 'blocked'; $reason = 'Excluded by Microsoft organization profile.'
        } elseif ($tool) {
            $reason = [string]$tool.reason
            if ($tool.architectures -and [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture -notin $tool.architectures) {
                $state = 'unsupported'; $reason = 'No reviewed artifact for this OS architecture.'
            } elseif ($tool.operations -and $Operation -notin $tool.operations) {
                $state = 'unsupported'; $reason = "No reviewed $Operation operation."
            } elseif (($tool.provider -eq 'corporate' -or ([string]$tool.endpoint).StartsWith('npm:')) -and -not $policy.Data['managedMachine']) {
                $state = 'blocked'; $reason = 'Corporate feed required; enable managedMachine explicitly.'
            } elseif ($tool.provider -in 'winget', 'official', 'corporate') {
                $state = 'allowed'; $reason = 'Cataloged source; executable permission is not yet verified.'
            } elseif ($tool.provider -eq 'approval' -and $Id -in @($policy.Data['organizationSourceApprovals'])) {
                $state = 'allowed'; $reason = 'Explicit local source approval; executable permission is not yet verified.'
            }
        }
    }
    [pscustomobject]@{ Id = $Id; Operation = $Operation; State = $state; Allowed = $state -eq 'allowed'; Reason = $reason; Tool = $tool }
}

function Test-OrganizationSource {
    param([Parameter(Mandatory)][string]$Id,
        [ValidateSet('install', 'upgrade', 'execute', 'build')][string]$Operation = 'install', [switch]$Quiet)
    $decision = Get-OrganizationSourceDecision -Id $Id -Operation $Operation
    if (-not $decision.Allowed -and -not $Quiet) { Write-Warning "$Id [$($decision.State)]: $($decision.Reason)" }
    $decision.Allowed
}

function Get-OrganizationSelectedTools {
    $policy = Get-OrganizationPolicy
    $data = $policy.Data
    foreach ($tool in $policy.Catalog.tools) {
        $selected = $false
        foreach ($feature in $tool.features) {
            if ($feature -eq 'baseline') { $selected = $true }
            elseif ($feature -eq 'herdrGui') { $selected = $data['installHerdr'] -and $data['installWindowsApps'] }
            elseif ($feature -eq 'personalTools') {
                if ($data.Contains('installPersonalTools')) { $selected = $data['installPersonalTools'] -eq $true }
                else { $selected = ($tool.id -eq 'dev-cli' -and $data['installHerdr']) -or ($tool.id -eq 'translate' -and $data['installTranslate']) }
            } elseif ($data[$feature] -eq $true) { $selected = $true }
            if ($selected) { break }
        }
        if ($selected) { $tool }
    }
}

function Test-OrganizationPathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $p = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim('"'))).TrimEnd('\', '/')
        $r = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Root.Trim('"'))).TrimEnd('\', '/')
        $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } catch { $false }
}

function Test-OrganizationScoopPath {
    param([string]$Path)
    $roots = @((Join-Path $HOME 'scoop'), $env:SCOOP, $env:SCOOP_GLOBAL)
    if ($env:ProgramData) { $roots += Join-Path $env:ProgramData 'scoop' }
    foreach ($root in $roots) { if (Test-OrganizationPathUnderRoot $Path $root) { return $true } }
    # Resolve links without launching shims (including a link outside the root).
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $target = $item.ResolveLinkTarget($true)
        if ($target) {
            foreach ($root in $roots) { if (Test-OrganizationPathUnderRoot $target.FullName $root) { return $true } }
        }
    } catch { $null = $_ }
    $false
}

function Remove-OrganizationScoopPath {
    # Process only; preserve local files and both persisted PATH values.
    if (-not (Test-MicrosoftOrganization)) { return }
    $env:PATH = @($env:PATH -split ';' | Where-Object { $_ -and -not (Test-OrganizationScoopPath $_) }) -join ';'
}

function Resolve-OrganizationCommand {
    param([Parameter(Mandatory)][string]$Name, [string]$ExplicitPath)
    if ($ExplicitPath) {
        if (-not [IO.Path]::IsPathFullyQualified($ExplicitPath) -or
            -not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) -or
            (Test-OrganizationScoopPath $ExplicitPath)) { throw "Invalid or disallowed $Name override: $ExplicitPath" }
        return [IO.Path]::GetFullPath($ExplicitPath)
    }
    foreach ($command in @(Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if (-not (Test-OrganizationScoopPath $command.Source)) { return $command.Source }
    }
    $null
}

function Resolve-OrganizationNode {
    $explicit = [string](Get-OrganizationPolicy).Data['nodeExecutable']
    if ($explicit) { return Resolve-OrganizationCommand -Name node -ExplicitPath $explicit }
    if ($env:NVM_SYMLINK) {
        $node = Join-Path $env:NVM_SYMLINK 'node.exe'
        if (Test-Path -LiteralPath $node -PathType Leaf) { return Resolve-OrganizationCommand -Name node -ExplicitPath $node }
    }
    Resolve-OrganizationCommand -Name node
}

function Resolve-OrganizationPython {
    $explicit = [string](Get-OrganizationPolicy).Data['pythonExecutable']
    if ($explicit) {
        if ($explicit -match '(?i)[\\/]Microsoft[\\/]WindowsApps[\\/]python(?:3)?\.exe$') {
            throw 'pythonExecutable points to the in-box Store alias, not an approved Python runtime.'
        }
        return Resolve-OrganizationCommand -Name python -ExplicitPath $explicit
    }
    foreach ($command in @(Get-Command python, python3 -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if ($command.Source -match '(?i)[\\/]Microsoft[\\/]WindowsApps[\\/]python(?:3)?\.exe$') { continue }
        if (-not (Test-OrganizationScoopPath $command.Source)) { return $command.Source }
    }
    $null
}

function Get-OrganizationNpmLayout {
    $node = Resolve-OrganizationNode
    if (-not $node) { throw 'No approved non-Scoop Node runtime; install/select Node before npm operations.' }
    $root = Split-Path -Parent $node
    $npm = Join-Path $root 'npm.cmd'
    $cli = Join-Path $root 'node_modules\npm\bin\npm-cli.js'
    if (-not (Test-Path -LiteralPath $npm -PathType Leaf) -or -not (Test-Path -LiteralPath $cli -PathType Leaf)) {
        throw "Unsupported Node/npm layout at $root; no other runtime was substituted."
    }
    [pscustomobject]@{ NodeExecutable = $node; NpmCommand = $npm; NpmCli = $cli; Prefix = (Join-Path $env:LOCALAPPDATA 'dotfiles\npm') }
}

function Get-OrganizationPiLocation {
    $layout = Get-OrganizationNpmLayout
    $prefixes = @($layout.Prefix)
    if ($env:APPDATA) { $prefixes += Join-Path $env:APPDATA 'npm' }
    $prefixes += Split-Path $layout.NodeExecutable
    foreach ($prefix in $prefixes) {
        if (Test-OrganizationScoopPath $prefix) { continue }
        $root = Join-Path $prefix 'node_modules\@earendil-works\pi-coding-agent'
        $manifest = Join-Path $root 'package.json'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            $metadata = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($metadata.name -ne '@earendil-works/pi-coding-agent') { throw "Unexpected Pi manifest at $manifest" }
            return [pscustomobject]@{ NodeExecutable = $layout.NodeExecutable; Prefix = $prefix; PackageRoot = $root; Owned = $prefix -eq $layout.Prefix }
        }
    }
    [pscustomobject]@{ NodeExecutable = $layout.NodeExecutable; Prefix = $layout.Prefix; PackageRoot = (Join-Path $layout.Prefix 'node_modules\@earendil-works\pi-coding-agent'); Owned = $true }
}

function Get-OrganizationUvEnvironment {
    param([hashtable]$Environment = @{})
    $values = @{}
    if (-not (Test-MicrosoftOrganization)) { return $values }
    $root = Join-Path $env:LOCALAPPDATA 'dotfiles\uv'
    $defaults = @{
        UV_TOOL_DIR = (Join-Path $root 'tools')
        UV_TOOL_BIN_DIR = (Join-Path $root 'bin')
        UV_CACHE_DIR = (Join-Path $root 'cache')
        UV_PYTHON_INSTALL_DIR = (Join-Path $root 'python')
        UV_PYTHON_BIN_DIR = (Join-Path $root 'python-bin')
    }
    foreach ($name in $defaults.Keys) {
        $current = if ($Environment.ContainsKey($name)) { $Environment[$name] } else { [Environment]::GetEnvironmentVariable($name, 'Process') }
        # Recognize the old Scoop owner, not arbitrary user locations. Never move
        # old environments or rewrite persisted User variables during migration.
        if (-not $current -or (Test-OrganizationScoopPath $current)) { $values[$name] = $defaults[$name] }
    }
    $values
}

function Set-OrganizationEnvironment {
    if (-not (Test-MicrosoftOrganization)) {
        if ($env:DOTFILES_ORGANIZATION_PROFILE -eq 'microsoft') { Remove-Item Env:DOTFILES_ORGANIZATION_PROFILE }
        return
    }
    $env:DOTFILES_ORGANIZATION_PROFILE = 'microsoft'
    $uvEnvironment = Get-OrganizationUvEnvironment
    foreach ($name in $uvEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $uvEnvironment[$name], 'Process') }
    if ($env:UV_TOOL_BIN_DIR -and (Test-Path -LiteralPath $env:UV_TOOL_BIN_DIR -PathType Container)) {
        $env:PATH = $env:UV_TOOL_BIN_DIR + ';' + (@($env:PATH -split ';' | Where-Object { $_ -ne $env:UV_TOOL_BIN_DIR }) -join ';')
    }
    # uv distributions bypass PyPI. Disallow implicit downloads unless separately approved.
    if (-not (Test-OrganizationSource uv-python -Quiet)) { $env:UV_PYTHON_DOWNLOADS = 'never' }
    # Downstream extension autoinstall is separately opt-in.
    if (-not (Test-OrganizationSource azure-devops -Quiet)) { $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no' }
    Remove-OrganizationScoopPath
    # The official 7-Zip installer does not add its CLI to PATH. Match bootstrap's
    # vendor locations, and promote only an existing executable in this process.
    if (Test-OrganizationSource 7zip -Operation execute -Quiet) {
        foreach ($programRoot in @($env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique) {
            $archiveDirectory = Join-Path $programRoot '7-Zip'
            if ((Test-Path -LiteralPath (Join-Path $archiveDirectory '7z.exe') -PathType Leaf) -and
                -not (Test-OrganizationScoopPath $archiveDirectory)) {
                $env:PATH = $archiveDirectory + ';' + (@($env:PATH -split ';' | Where-Object { $_ -ne $archiveDirectory }) -join ';')
            }
        }
    }
    $python = Resolve-OrganizationPython
    if ($python) {
        $pythonDirectory = Split-Path -Parent $python
        $env:PATH = $pythonDirectory + ';' + (@($env:PATH -split ';' | Where-Object { $_ -ne $pythonDirectory }) -join ';')
        $env:UV_PYTHON = $python
    }
    $npmPrefix = Join-Path $env:LOCALAPPDATA 'dotfiles\npm'
    if (Test-Path -LiteralPath $npmPrefix -PathType Container) {
        $env:PATH = $npmPrefix + ';' + (@($env:PATH -split ';' | Where-Object { $_ -ne $npmPrefix }) -join ';')
    }
}
