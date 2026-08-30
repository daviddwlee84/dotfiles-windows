#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('UpgradeNpmAgents', 'DocsBuild', 'DocsServe')]
    [string] $Action
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'package-source-runner.ps1')
. (Join-Path $PSScriptRoot 'pi-package-core.ps1')
$policy = Get-ChezmoiPackageSourcePolicy

function Invoke-DocsCommand {
    param([ValidateSet('build', 'serve', 'version')] [string] $Command)

    $uvExecutable = (Get-Command uv -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $arguments = @(
        'run', '--no-project', '--with', 'mkdocs-material', '--with', 'mkdocs-static-i18n',
        'mkdocs'
    )
    if ($Command -eq 'version') { $arguments += '--version' }
    else { $arguments += $Command }
    if ($Command -eq 'build') { $arguments += '--strict' }
    Invoke-PackageSourceCommand -Manager uv -Executable $uvExecutable -Arguments $arguments `
        -Operation "docs-$Command" -ManagedMachine $policy.ManagedMachine `
        -AllowPublicFallback $policy.AllowPublicFallback -TimeoutSeconds 1200
}

switch ($Action) {
    'UpgradeNpmAgents' {
        $npmCommand = (Get-Command npm -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $npm = Get-NpmGlobalExecutionContext -NpmCommandPath $npmCommand
        $piNpmCommand = Get-PiOwnedNpmCommandPath
        if (-not (Test-Path -LiteralPath $piNpmCommand -PathType Leaf)) {
            throw "owned Scoop npm is unavailable: $piNpmCommand"
        }
        $piNpm = Get-PiOwnedNpmContext -NpmContext `
            (Get-NpmGlobalExecutionContext -NpmCommandPath $piNpmCommand)
        $piResult = Invoke-PiCodingAgentPackageCommand -NpmContext $piNpm -Action Update `
            -ManagedMachine $policy.ManagedMachine -AllowPublicFallback $policy.AllowPublicFallback `
            -TimeoutSeconds 1200
        if (-not $piResult.Succeeded) {
            if ($piResult.Failure) { [Console]::Error.WriteLine("Pi upgrade failed: $($piResult.Failure)") }
            exit $piResult.ExitCode
        }
        foreach ($package in @('opencode-ai', '@openai/codex', '@github/copilot')) {
            $result = Invoke-PackageSourceCommand -Manager npm -Executable $npm.NodeExecutable `
                -Arguments @($npm.NpmCli, 'update', '-g', $package) `
                -Operation $package -PackageSpec $package -NpmPrefix $npm.Prefix -NpmCache $npm.Cache `
                -NpmConfigValues $npm.ConfigValues -ManagedMachine $policy.ManagedMachine -AllowPublicFallback $policy.AllowPublicFallback `
                -TimeoutSeconds 1200
            if (-not $result.Succeeded) { exit $result.ExitCode }
        }
    }
    'DocsBuild' {
        $result = Invoke-DocsCommand -Command build
        if (-not $result.Succeeded) { exit $result.ExitCode }
    }
    'DocsServe' {
        # Resolve dependencies in a short classified command, then attach the
        # long-running server directly to this console using the successful source.
        $probe = Invoke-DocsCommand -Command version
        if (-not $probe.Succeeded) { exit $probe.ExitCode }

        $uvExecutable = (Get-Command uv -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $serveArguments = @(
            'run', '--no-project', '--with', 'mkdocs-material', '--with', 'mkdocs-static-i18n',
            'mkdocs', 'serve'
        )
        $finalSource = $probe.Attempts[-1].Source
        $environment = @{}
        if ($finalSource -ne 'ambient') {
            $sourceUrl = if ($finalSource -eq 'corporate') { $script:CorporatePyPiIndex } else { $script:PublicPyPiIndex }
            $serveArguments = Add-UvSourceArguments -Arguments $serveArguments -SourceUrl $sourceUrl
            $environment = New-PackageAttemptEnvironment -Manager uv
        }
        $serve = Invoke-InteractivePackageProcess -Executable $uvExecutable -Arguments $serveArguments `
            -Environment $environment -WorkingDirectory $repoRoot
        if ($serve.ExitCode -ne 0) { exit $serve.ExitCode }
    }
}
