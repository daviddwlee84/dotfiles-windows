#Requires -Version 7.4
#Requires -PSEdition Core
# Corporate-first package command runner. Public fallback is explicit, bounded,
# source-isolated, and limited to transient failures; it never changes the parent
# process environment or persistent npm/uv configuration.

$script:CorporatePyPiIndex = 'https://packagefeedproxy.microsoft.io/pypi/simple/'
$script:PublicPyPiIndex = 'https://pypi.org/simple'
$script:CorporateNpmRegistry = 'https://packagefeedproxy.microsoft.io/npm/'
$script:PublicNpmRegistry = 'https://registry.npmjs.org/'

function Protect-PackageSourceOutput {
    param([AllowEmptyString()] [string] $Text)

    if (-not $Text) { return '' }
    $protected = $Text -replace '(?i)(https?://)[^/@\s:]+:[^/@\s]+@', '$1***:***@'
    $protected = $protected -replace '(?im)((?:_authToken|token|password)\s*[=:]\s*)\S+', '$1***'
    $protected
}

function Write-PackageSourceDiagnostic {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Host', 'StandardError', 'Capture')] [string] $OutputMode = 'Host'
    )

    if ($OutputMode -eq 'Capture') { return }
    if ($OutputMode -eq 'StandardError') { [Console]::Error.WriteLine($Message); return }
    Write-Host $Message
}

function Get-PackageFailureClass {
    param(
        [AllowEmptyString()] [string] $Output,
        [bool] $TimedOut,
        [bool] $LaunchFailed
    )

    if ($LaunchFailed) { return 'runner-error' }
    $text = "$Output"
    $lines = @($text -split "`r?`n")
    $corporateSegments = [Collections.Generic.List[string]]::new()
    $corporateHostPattern = '(?i)(?<![A-Za-z0-9.-])(?:packagefeedproxy\.microsoft\.io|[A-Za-z0-9-]+\.pkgs\.visualstudio\.com)(?=[:/\s]|$)'
    $failureMarkerPattern = '(?i)(?:failed|failure|error|\bERR!?\b|request(?:ing)?\s+(?:to|from)|could not|cannot|timed out|timeout|caused by)'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $corporateHostPattern -and
            $lines[$index] -match $failureMarkerPattern -and
            $lines[$index] -notmatch '(?i)\b(?:success|succeeded|successful|completed|downloaded|installed|resolved)\b') {
            $last = [Math]::Min($lines.Count - 1, $index + 4)
            [void] $corporateSegments.Add(($lines[$index..$last] -join "`n"))
        }
    }
    $corporateFailureText = $corporateSegments -join "`n"
    $corporateContext = $corporateSegments.Count -gt 0

    # Deny-first: a diagnostic mentioning both a transient symptom and a policy,
    # auth, or TLS failure must never bypass the company source.
    if ($text -match '(?i)(?:HTTP[^\r\n]{0,48}\b40[13]\b|status[^\r\n]{0,32}\b40[13]\b|\bE40[13]\b)|unauthori[sz]ed|forbidden|authentication required|invalid auth|access denied|blocked by (?:your )?(?:administrator|organization|policy)|organization(?:al)? policy') {
        return 'auth-policy'
    }
    if ($text -match '(?i)certificate|self[- ]signed|unknown issuer|unable to get local issuer|CERT_|TLS|SSL|handshake|peer certificate') {
        return 'tls-certificate'
    }
    if ($text -match '(?i)(?:HTTP[^\r\n]{0,48}\b429\b|status[^\r\n]{0,32}\b429\b|\bE429\b)|too many requests|rate limit') {
        return 'rate-limit'
    }
    if ($text -match '(?i)(?:HTTP[^\r\n]{0,48}\b404\b|status[^\r\n]{0,32}\b404\b|\bE404\b)|\bETARGET\b|no matching version|not in this registry|not found in the package registry|no matching distribution|could not find a version') {
        return 'package-absence'
    }
    if ($text -match '(?i)\bERESOLVE\b|no solution found|incompatible (?:python|platform|version)|build failed|failed to build|postinstall|compiler|subprocess.+failed|\bE(?:PERM|ACCES|BUSY|NOSPC|INVAL)\b|disk full|no space left|resource busy|file is locked') {
        return 'package-or-local'
    }

    if ($corporateContext -and ($TimedOut -or $corporateFailureText -match '(?i)HTTP[^\r\n]{0,48}\b408\b|\bETIMEDOUT\b|\bESOCKETTIMEDOUT\b|\bERR_SOCKET_TIMEOUT\b|UND_ERR_(?:CONNECT|HEADERS|BODY)_TIMEOUT|timed out|request timeout')) {
        return 'timeout'
    }
    if ($TimedOut) { return 'timeout-unknown' }
    if ($corporateContext -and $corporateFailureText -match '(?i)\b(?:ECONNRESET|ECONNREFUSED|EAI_AGAIN|ENETUNREACH|EHOSTUNREACH|ENOTFOUND)\b|socket hang up|connection reset|connection refused|could not resolve host|no such host is known|temporary (?:failure|error).+(?:DNS|name resolution)') {
        return 'transient-network'
    }
    if ($corporateContext -and $corporateFailureText -match '(?i)(?:HTTP[^\r\n]{0,64}\b5\d\d\b|status[^\r\n]{0,48}\b5\d\d\b|\bE5\d\d\b)') {
        return 'http-5xx'
    }
    'other'
}

function Test-PackageFallbackEligible {
    param([Parameter(Mandatory)] [string] $FailureClass)
    $FailureClass -in @('timeout', 'transient-network', 'http-5xx')
}

function Invoke-InteractivePackageProcess {
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments,
        [hashtable] $Environment = @{},
        [string] $WorkingDirectory,
        [ValidateRange(0, 86400)] [int] $TimeoutSeconds = 0
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add([string] $argument) }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) { $startInfo.Environment.Remove([string] $name) }
        else { $startInfo.Environment[[string] $name] = [string] $Environment[$name] }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timedOut = $false
    try {
        if (-not $process.Start()) { throw "failed to start $Executable" }
        if ($TimeoutSeconds -eq 0) {
            $process.WaitForExit()
        } elseif (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { $null = $_ }
            $process.WaitForExit()
        }
        [pscustomobject]@{
            ExitCode = if ($timedOut) { -1 } else { $process.ExitCode }
            TimedOut = $timedOut
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-CapturedPackageProcess {
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments,
        [hashtable] $Environment = @{},
        [string] $WorkingDirectory,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 600,
        [ValidateSet('Host', 'StandardError', 'Capture')] [string] $OutputMode = 'Host'
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add([string] $argument) }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) { $startInfo.Environment.Remove([string] $name) }
        else { $startInfo.Environment[[string] $name] = [string] $Environment[$name] }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timedOut = $false
    $launchFailed = $false
    $exitCode = -1
    $stdout = ''
    $stderr = ''
    try {
        try {
            if (-not $process.Start()) { throw 'process did not start' }
        } catch {
            $launchFailed = $true
            $stderr = "failed to start $Executable`: $($_.Exception.Message)"
            return [pscustomobject]@{
                ExitCode = -1; TimedOut = $false; LaunchFailed = $true; Terminated = $true
                Stdout = ''; Stderr = (Protect-PackageSourceOutput $stderr)
            }
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $terminated = $true
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $terminated = $false
            try {
                $process.Kill($true)
                $terminated = $process.WaitForExit(5000)
            } catch {
                $terminated = $false
            }
        }
        if ($terminated) {
            $streamTasks = [Threading.Tasks.Task[]] @($stdoutTask, $stderrTask)
            $streamsCompleted = [Threading.Tasks.Task]::WaitAll($streamTasks, 5000)
            if ($streamsCompleted) {
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
            } else {
                $timedOut = $true
                $terminated = $false
                $stderr = "process output pipes did not close after exit: $Executable"
            }
        } else {
            $stderr = "process timed out and could not be terminated: $Executable"
        }
        $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    } finally {
        $process.Dispose()
    }

    $stdout = Protect-PackageSourceOutput $stdout
    $stderr = Protect-PackageSourceOutput $stderr
    if ($OutputMode -eq 'Host') {
        if ($stdout) { Write-Host $stdout.TrimEnd() }
        if ($stderr) { [Console]::Error.Write($stderr) }
    } elseif ($OutputMode -eq 'StandardError') {
        if ($stdout) { [Console]::Error.Write($stdout) }
        if ($stderr) { [Console]::Error.Write($stderr) }
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        LaunchFailed = $launchFailed
        Terminated = $terminated
        Stdout = $stdout
        Stderr = $stderr
    }
}

function New-PackageAttemptEnvironment {
    param(
        [ValidateSet('uv', 'npm')] [string] $Manager,
        [hashtable] $AdditionalEnvironment = @{}
    )

    $environment = @{}
    foreach ($key in $AdditionalEnvironment.Keys) { $environment[$key] = $AdditionalEnvironment[$key] }

    if ($Manager -eq 'uv') {
        foreach ($name in @(
            'UV_INDEX', 'UV_DEFAULT_INDEX', 'UV_INDEX_URL', 'UV_EXTRA_INDEX_URL',
            'UV_FIND_LINKS', 'UV_NO_INDEX', 'UV_CONFIG_FILE', 'UV_INSECURE_HOST',
            'PIP_INDEX_URL', 'PIP_EXTRA_INDEX_URL', 'PIP_FIND_LINKS', 'PIP_NO_INDEX',
            'PIP_CONFIG_FILE', 'PIP_TRUSTED_HOST'
        )) { $environment[$name] = $null }
    } else {
        foreach ($entry in [Environment]::GetEnvironmentVariables('Process').Keys) {
            $name = [string] $entry
            if ($name -match '(?i)^npm_config_.*(?:registry|auth|token|password|otp)') { $environment[$name] = $null }
        }
        foreach ($name in 'npm_config_registry', 'NODE_AUTH_TOKEN', 'NPM_AUTH_TOKEN', 'NPM_TOKEN') { $environment[$name] = $null }
    }
    $environment
}

function Get-NpmPackageScope {
    param([string] $PackageSpec)
    if ($PackageSpec -match '^(@[^/]+)/') { return $Matches[1] }
    $null
}

function Get-NpmGlobalExecutionContext {
    param([Parameter(Mandatory)] [string] $NpmCommandPath)

    $npmDirectory = Split-Path -Parent $NpmCommandPath
    $nodeExecutable = Join-Path $npmDirectory 'node.exe'
    $npmPrefixScript = Join-Path $npmDirectory 'node_modules\npm\bin\npm-prefix.js'
    $npmCli = Join-Path $npmDirectory 'node_modules\npm\bin\npm-cli.js'
    foreach ($requiredPath in $nodeExecutable, $npmPrefixScript, $npmCli) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "unsupported npm wrapper layout; expected repo-managed Scoop Node files beside $NpmCommandPath"
        }
    }
    $prefixOutput = @(& $nodeExecutable $npmPrefixScript 2>$null)
    if ($LASTEXITCODE -eq 0 -and $prefixOutput) {
        $prefixCli = Join-Path (([string] $prefixOutput[-1]).Trim()) 'node_modules\npm\bin\npm-cli.js'
        if (Test-Path -LiteralPath $prefixCli -PathType Leaf) { $npmCli = $prefixCli }
    }

    $rootOutput = @(& $NpmCommandPath root -g 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $rootOutput) { throw 'cannot resolve global npm root' }
    $npmRoot = ([string] $rootOutput[-1]).Trim()
    $cacheOutput = @(& $NpmCommandPath config get cache 2>$null)
    $npmCache = if ($LASTEXITCODE -eq 0 -and $cacheOutput) { ([string] $cacheOutput[-1]).Trim() } else { '' }
    $configValues = @{}
    foreach ($key in @(
        'proxy', 'https-proxy', 'noproxy', 'cafile', 'cert', 'key', 'strict-ssl',
        'ignore-scripts', 'foreground-scripts', 'script-shell', 'engine-strict', 'legacy-peer-deps'
    )) {
        $valueOutput = @(& $NpmCommandPath config get $key 2>$null)
        if ($LASTEXITCODE -eq 0 -and $valueOutput) {
            $value = ([string] $valueOutput[-1]).Trim()
            if ($value -and $value -notin @('null', 'undefined')) { $configValues[$key] = $value }
        }
    }

    [pscustomobject]@{
        NodeExecutable = $nodeExecutable
        NpmCli = $npmCli
        Root = $npmRoot
        Prefix = Split-Path -Parent $npmRoot
        Cache = $npmCache
        ConfigValues = $configValues
    }
}

function Add-UvSourceArguments {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $SourceUrl
    )

    $sourceArguments = @('--default-index', $SourceUrl, '--index-strategy', 'first-index')
    if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'tool' -and $Arguments[1] -eq 'install') {
        $remaining = if ($Arguments.Count -gt 2) { @($Arguments[2..($Arguments.Count - 1)]) } else { @() }
        return @('--no-config', 'tool', 'install') + $sourceArguments + $remaining
    }
    if ($Arguments.Count -ge 1 -and $Arguments[0] -eq 'run') {
        $remaining = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }
        return @('--no-config', 'run') + $sourceArguments + $remaining
    }
    throw "unsupported isolated uv command: $($Arguments -join ' ')"
}

function Invoke-PackageSourceCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('uv', 'npm')] [string] $Manager,
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)] [bool] $ManagedMachine,
        [Parameter(Mandatory)] [bool] $AllowPublicFallback,
        [string] $PackageSpec,
        [string] $NpmPrefix,
        [string] $NpmCache,
        [hashtable] $NpmConfigValues = @{},
        [hashtable] $AdditionalEnvironment = @{},
        [ValidateSet('Host', 'StandardError', 'Capture')] [string] $OutputMode = 'Host',
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 600,
        [string] $CorporatePyPiIndex = $script:CorporatePyPiIndex,
        [string] $PublicPyPiIndex = $script:PublicPyPiIndex,
        [string] $CorporateNpmRegistry = $script:CorporateNpmRegistry,
        [string] $PublicNpmRegistry = $script:PublicNpmRegistry
    )

    $attempts = [Collections.Generic.List[object]]::new()
    $tempRoot = $null
    try {
        $workingDirectory = $null
        $baseEnvironment = @{}
        foreach ($key in $AdditionalEnvironment.Keys) { $baseEnvironment[$key] = $AdditionalEnvironment[$key] }
        if ($Manager -eq 'npm') {
            $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('package-source-npm-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        }
        if ($ManagedMachine) {
            $baseEnvironment = New-PackageAttemptEnvironment -Manager $Manager -AdditionalEnvironment $AdditionalEnvironment
            if ($Manager -eq 'npm') {
                if (-not $NpmPrefix) { throw 'NpmPrefix is required for npm source isolation' }
                $userConfig = Join-Path $tempRoot 'user.npmrc'
                $globalConfig = Join-Path $tempRoot 'global.npmrc'
                $npmConfigLines = @($NpmConfigValues.Keys | Sort-Object | ForEach-Object {
                    $value = [string] $NpmConfigValues[$_]
                    if ($value -match '[\r\n]') { throw "npm config value contains a newline: $_" }
                    "$_=$value"
                })
                $npmConfigText = if ($npmConfigLines) { ($npmConfigLines -join "`n") + "`n" } else { '' }
                [IO.File]::WriteAllText($userConfig, $npmConfigText, [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($globalConfig, '', [Text.UTF8Encoding]::new($false))
                $baseEnvironment['NPM_CONFIG_USERCONFIG'] = $userConfig
                $baseEnvironment['NPM_CONFIG_GLOBALCONFIG'] = $globalConfig
                $workingDirectory = $tempRoot
            }
        }

        $sourceQueue = [Collections.Generic.Queue[string]]::new()
        $sourceQueue.Enqueue($(if ($ManagedMachine) { 'corporate' } else { 'ambient' }))
        while ($sourceQueue.Count -gt 0) {
            $sourceKind = $sourceQueue.Dequeue()
            $attemptNumber = $attempts.Count + 1
            $sourceLabel = if ($sourceKind -eq 'ambient') { 'ambient package policy' } elseif ($Manager -eq 'uv') { "$sourceKind PyPI" } else { "$sourceKind npm" }
            Write-PackageSourceDiagnostic -OutputMode $OutputMode -Message "package-source[$Manager`:$Operation]: attempt $attemptNumber using $sourceLabel"

            $attemptArguments = @($Arguments)
            $attemptEnvironment = @{} + $baseEnvironment
            if ($sourceKind -ne 'ambient') {
                $sourceUrl = if ($Manager -eq 'uv') {
                    if ($sourceKind -eq 'corporate') { $CorporatePyPiIndex } else { $PublicPyPiIndex }
                } else {
                    if ($sourceKind -eq 'corporate') { $CorporateNpmRegistry } else { $PublicNpmRegistry }
                }
                if ($Manager -eq 'uv') {
                    $attemptArguments = Add-UvSourceArguments -Arguments $attemptArguments -SourceUrl $sourceUrl
                } else {
                    $attemptArguments += "--registry=$sourceUrl"
                    $scope = Get-NpmPackageScope -PackageSpec $PackageSpec
                    if ($scope) { $attemptArguments += "--$scope`:registry=$sourceUrl" }
                    $attemptArguments += "--prefix=$NpmPrefix"
                    if ($NpmCache) { $attemptArguments += "--cache=$NpmCache" }
                }
            }

            $processResult = Invoke-CapturedPackageProcess -Executable $Executable -Arguments $attemptArguments `
                -Environment $attemptEnvironment -WorkingDirectory $workingDirectory `
                -TimeoutSeconds $TimeoutSeconds -OutputMode $OutputMode
            $combinedOutput = "$($processResult.Stdout)`n$($processResult.Stderr)"
            $failureClass = if ($processResult.ExitCode -eq 0) { 'none' } else {
                Get-PackageFailureClass -Output $combinedOutput -TimedOut $processResult.TimedOut `
                    -LaunchFailed ($processResult.LaunchFailed -or -not $processResult.Terminated)
            }
            $attempts.Add([pscustomobject]@{
                Source = $sourceKind
                ExitCode = $processResult.ExitCode
                TimedOut = $processResult.TimedOut
                ProcessTerminated = $processResult.Terminated
                FailureClass = $failureClass
                Stdout = $processResult.Stdout
                Stderr = $processResult.Stderr
            })

            if ($processResult.ExitCode -eq 0) { break }
            Write-PackageSourceDiagnostic -OutputMode $OutputMode -Message "package-source[$Manager`:$Operation]: $sourceKind attempt failed: $failureClass"

            if ($sourceKind -eq 'corporate' -and $AllowPublicFallback -and (Test-PackageFallbackEligible $failureClass)) {
                Write-PackageSourceDiagnostic -OutputMode $OutputMode -Message "package-source[$Manager`:$Operation]: public fallback enabled; retrying once"
                $sourceQueue.Enqueue('public')
            } elseif ($sourceKind -eq 'corporate') {
                $reason = if (-not $AllowPublicFallback) { 'fallback is disabled' } else { "$failureClass is not eligible" }
                Write-PackageSourceDiagnostic -OutputMode $OutputMode -Message "package-source[$Manager`:$Operation]: $reason; not retrying"
            }
        }

        $final = $attempts[$attempts.Count - 1]
        [pscustomobject]@{
            Succeeded = $final.ExitCode -eq 0
            ExitCode = $final.ExitCode
            TimedOut = $final.TimedOut
            ProcessTerminated = $final.ProcessTerminated
            FallbackUsed = $attempts.Count -gt 1 -and $attempts[1].Source -eq 'public'
            FailureClass = $final.FailureClass
            Attempts = @($attempts)
            Stdout = $final.Stdout
            Stderr = $final.Stderr
        }
    } finally {
        if ($tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ChezmoiPackageSourcePolicy {
    $raw = @(& chezmoi data --format json 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'could not read chezmoi package-source policy' }
    $data = ($raw -join "`n") | ConvertFrom-Json
    [pscustomobject]@{
        ManagedMachine = [bool] $data.managedMachine
        AllowPublicFallback = [bool] $data.allowPublicPackageFallback
    }
}
