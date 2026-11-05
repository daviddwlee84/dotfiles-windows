#Requires -Version 7.4
#Requires -PSEdition Core
# Small adapter over the existing installer helpers, not a second package manager.
function Invoke-OrganizationWingetProcess {
    param([string[]]$Arguments, [switch]$StreamOutput)
    $winget = Resolve-OrganizationCommand winget
    if (-not $winget) { throw 'winget unavailable; no alternative provider was attempted.' }
    $output = [Collections.Generic.List[string]]::new()
    $global:LASTEXITCODE = $null
    & $winget @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $output.Add($line)
        if ($StreamOutput) { Write-Host $line }
    }
    $code = if ($null -eq $LASTEXITCODE) { 126 } else { $LASTEXITCODE }
    [pscustomobject]@{ ExitCode = $code; Output = ($output -join "`n") }
}

function Invoke-OrganizationWinget {
    param([Parameter(Mandatory)]$Tool, [switch]$Upgrade)
    $source = if ($Tool.source) { $Tool.source } else { 'winget' }
    $identity = @('--id', $Tool.packageId, '--exact', '--source', $source, '--accept-source-agreements', '--disable-interactivity')
    $installed = Invoke-OrganizationWingetProcess -Arguments (@('list') + $identity)
    if ($installed.ExitCode -eq 0 -and -not $Upgrade) { return 'installed-unverified' }
    # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND is the only absence result.
    if ($installed.ExitCode -ne 0 -and $installed.ExitCode -ne -1978335212) {
        throw "winget inventory failed ($($installed.ExitCode)): $($installed.Output)"
    }
    if ($Upgrade -and $installed.ExitCode -ne 0) { return 'missing-not-upgraded' }
    if (-not $Upgrade) {
        # Do not silently duplicate a portable, NVM or differently owned install.
        foreach ($name in $Tool.commands) {
            $candidate = if ($name -eq 'node') { Resolve-OrganizationNode } else { Resolve-OrganizationCommand $name }
            if ($candidate) { return "existing-owner-preserved:$candidate" }
        }
    }
    # Validate the exact provider entry before any acquisition. No fuzzy search.
    $metadata = Invoke-OrganizationWingetProcess -Arguments (@('show') + $identity)
    if ($metadata.ExitCode -ne 0) { throw "No compatible package metadata for $($Tool.packageId): $($metadata.Output)" }
    if ($Tool.scope -eq 'machine') {
        $identityToken = [Security.Principal.WindowsIdentity]::GetCurrent()
        $admin = ([Security.Principal.WindowsPrincipal]$identityToken).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) { return 'needs-explicit-administrator-session' }
    }
    $arguments = @($(if ($Upgrade) { 'upgrade' } else { 'install' })) + $identity + @('--silent', '--accept-package-agreements')
    if (-not $Upgrade) { $arguments += '--no-upgrade' }
    if ($Tool.scope -and $Tool.scope -ne 'default') { $arguments += @('--scope', $Tool.scope) }
    if ($Tool.custom) { $arguments += @('--custom', $Tool.custom) }
    Write-Host "==> winget $($arguments[0]) $($Tool.packageId) (approve the Windows UAC prompt if requested)"
    $result = Invoke-OrganizationWingetProcess -Arguments $arguments -StreamOutput
    # 0x8A15002B: no applicable upgrade; never install a missing package instead.
    if ($Upgrade -and $result.ExitCode -eq -1978335189) { return 'unchanged' }
    if ($result.ExitCode -ne 0) { throw "winget failed ($($result.ExitCode)); no scope/source retry attempted." }
    if (Get-Command Set-WindowsPathPrecedence -ErrorAction SilentlyContinue) { Set-WindowsPathPrecedence }
    Remove-OrganizationScoopPath
    if ($Upgrade) { 'updated-unverified' } else { 'installed-unverified' }
}

function Invoke-OrganizationPackageAction {
    param([Parameter(Mandatory)]$Tool, [switch]$Upgrade)
    if ($Tool.provider -eq 'winget') { return Invoke-OrganizationWinget -Tool $Tool -Upgrade:$Upgrade }
    if ($Upgrade) { return 'unsupported-upgrade-adapter; use the approved component command' }
    switch ($Tool.id) {
        'herdr' { Install-Herdr }
        'herdr-gui' { Install-HerdrGui }
        'omp' { if (-not (Install-OmpBinary)) { throw 'OMP installation failed.' } }
        'pi' { Install-PiCodingAgent }
        'opencode' { Npm-InstallGlobal @('opencode-ai') }
        'codex' { Npm-InstallGlobal @('@openai/codex') }
        'copilot-cli' { Npm-InstallGlobal @('@github/copilot') }
        'summarize' { Npm-InstallGlobal @('@steipete/summarize') }
        'specstory' { Install-WindowsCliRelease -Name specstory }
        'dev-cli' { Install-WindowsCliRelease -Name dev-cli }
        'herdr-plus' { Install-HerdrPlus }
        'uv-python' {
            $uv = Resolve-OrganizationCommand uv
            if (-not $uv) { throw 'uv unavailable' }
            & $uv python install --default --preview
            if ($LASTEXITCODE -ne 0) { throw 'uv Python installation failed' }
        }
        { $_ -in 'apprise', 'litellm' } {
            $uv = Resolve-OrganizationCommand uv
            if (-not $uv) { throw 'uv unavailable' }
            $arguments = if ($Tool.id -eq 'apprise') { @('tool', 'install', '--with', 'pywin32', 'apprise') } else { @('tool', 'install', 'litellm[proxy]') }
            $policy = Get-OrganizationPolicy
            $result = Invoke-PackageSourceCommand -Manager uv -Executable $uv -Arguments $arguments -Operation $Tool.id `
                -ManagedMachine ([bool]$policy.Data['managedMachine']) -AllowPublicFallback ([bool]$policy.Data['allowPublicPackageFallback'])
            if (-not $result.Succeeded) { throw "$($Tool.id) dependency installation failed" }
        }
        # Acquisition belongs to a separately gated apply/runtime entry point.
        { $_ -in 'pi-agents', 'yazi-plugins', 'nvim-plugins', 'tomlkit', 'copilot-runtime', 'copilot-cdn', 'agent-plugins' } {
            return 'approved-for-gated-component-entrypoint'
        }
        default { return 'unsupported-adapter; source approval does not implement an installer' }
    }
    'component-invoked; inspect component verification/failure summary'
}

function Invoke-OrganizationPackages {
    param([switch]$Upgrade, [string[]]$Only)
    if (-not (Test-MicrosoftOrganization)) { throw 'Organization package adapter requires the Microsoft profile.' }
    Set-OrganizationEnvironment
    $operation = if ($Upgrade) { 'upgrade' } else { 'install' }
    foreach ($tool in @(Get-OrganizationSelectedTools)) {
        if ($Only -and $tool.id -notin $Only) { continue }
        $decision = Get-OrganizationSourceDecision -Id $tool.id -Operation $operation
        $status = $decision.State; $detail = $decision.Reason
        if ($decision.Allowed) {
            try {
                $status = Invoke-OrganizationPackageAction -Tool $tool -Upgrade:$Upgrade
                $detail = ''
            } catch {
                $status = 'failed'; $detail = $_.Exception.Message
            }
        }
        [pscustomobject]@{ Tool = $tool.id; Status = $status; Detail = $detail }
    }
}
