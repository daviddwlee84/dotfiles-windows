#Requires -Version 7

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $RepoRoot 'scripts/package-source-runner.ps1')

    function New-FakeNpmCommand {
        param([Parameter(Mandatory)] [string] $Path)
        $body = @'
@echo off
echo %*>>"%FAKE_ARGUMENT_LOG%"
echo %NPM_CONFIG_USERCONFIG%>>"%FAKE_CONFIG_LOG%"
echo %NPM_CONFIG_GLOBALCONFIG%>>"%FAKE_CONFIG_LOG%"
type "%NPM_CONFIG_USERCONFIG%">>"%FAKE_CONFIG_CONTENT_LOG%"
if /I "%FAKE_MODE%"=="success" exit /b 0
if /I "%FAKE_MODE%"=="503" (
  echo %* | %SystemRoot%\System32\findstr.exe /c:"https://registry.npmjs.org/" >nul
  if not errorlevel 1 exit /b 0
  echo request to https://packagefeedproxy.microsoft.io/npm/ failed: HTTP status server error 503 Service Unavailable 1>&2
  exit /b 1
)
if /I "%FAKE_MODE%"=="403" (
  echo HTTP status client error 403 Forbidden 1>&2
  exit /b 1
)
if /I "%FAKE_MODE%"=="tls" (
  echo certificate verify failed; connection reset 1>&2
  exit /b 1
)
if /I "%FAKE_MODE%"=="404" (
  echo npm ERR! E404 package not in this registry 1>&2
  exit /b 1
)
if /I "%FAKE_MODE%"=="solver" (
  echo npm ERR! ERESOLVE unable to resolve dependency tree 1>&2
  exit /b 1
)
if /I "%FAKE_MODE%"=="credential" (
  echo request to https://user:secret@example.test failed with HTTP status 503 1>&2
  exit /b 1
)
if /I "%FAKE_MODE%"=="timeout" (
  echo request to https://packagefeedproxy.microsoft.io/npm/ is still pending 1>&2
  %SystemRoot%\System32\ping.exe 127.0.0.1 -n 6 >nul
)
exit /b 1
'@
        [IO.File]::WriteAllText($Path, $body, [Text.Encoding]::ASCII)
    }

    function Invoke-FakeNpm {
        param(
            [Parameter(Mandatory)] [string] $Mode,
            [bool] $Managed = $true,
            [bool] $AllowFallback = $true,
            [int] $TimeoutSeconds = 10,
            [string] $Package = '@openai/codex'
        )
        Invoke-PackageSourceCommand -Manager npm -Executable $env:ComSpec `
            -Arguments @('/d', '/c', $script:FakeNpm, 'install', '-g', $Package) `
            -Operation $Package -PackageSpec $Package -NpmPrefix $TestDrive -NpmCache (Join-Path $TestDrive 'cache') `
            -NpmConfigValues @{ 'strict-ssl' = 'false'; cafile = 'C:\ca.pem' } -ManagedMachine $Managed -AllowPublicFallback $AllowFallback `
            -AdditionalEnvironment @{
                FAKE_MODE = $Mode
                FAKE_ARGUMENT_LOG = $script:ArgumentLog
                FAKE_CONFIG_LOG = $script:ConfigLog
                FAKE_CONFIG_CONTENT_LOG = $script:ConfigContentLog
            } -OutputMode Capture -TimeoutSeconds $TimeoutSeconds
    }
}

Describe 'package source runner' {
    BeforeEach {
        $script:FakeNpm = Join-Path $TestDrive 'fake-npm.cmd'
        $script:ArgumentLog = Join-Path $TestDrive 'arguments.log'
        $script:ConfigLog = Join-Path $TestDrive 'configs.log'
        $script:ConfigContentLog = Join-Path $TestDrive 'config-content.log'
        Remove-Item $script:ArgumentLog, $script:ConfigLog, $script:ConfigContentLog -Force -ErrorAction SilentlyContinue
        New-FakeNpmCommand -Path $script:FakeNpm
    }

Describe 'package failure classification' {
    It 'allows only approved transient classes' {
        $cases = @(
            @{ Text = 'https://packagefeedproxy.microsoft.io/npm/ HTTP status server error (503 Service Unavailable)'; Class = 'http-5xx'; Eligible = $true }
            @{ Text = 'https://packagefeedproxy.microsoft.io/npm/ npm ERR! code ECONNRESET'; Class = 'transient-network'; Eligible = $true }
            @{ Text = 'request to https://packagefeedproxy.microsoft.io/npm/ failed: request timeout ERR_SOCKET_TIMEOUT'; Class = 'timeout'; Eligible = $true }
            @{ Text = 'request to https://packagefeedproxy.microsoft.io/npm/ failed: No such host is known'; Class = 'transient-network'; Eligible = $true }
            @{ Text = 'postinstall server returned error 503'; Class = 'package-or-local'; Eligible = $false }
            @{ Text = "successful request to https://packagefeedproxy.microsoft.io/npm/`nunrelated HTTP status 503"; Class = 'other'; Eligible = $false }
            @{ Text = "successful request to https://packagefeedproxy.microsoft.io/npm/`npostinstall HTTP 503"; Class = 'package-or-local'; Eligible = $false }
            @{ Text = 'request to https://packagefeedproxy.microsoft.io.evil.example failed: HTTP 503'; Class = 'other'; Eligible = $false }
            @{ Text = 'request to https://feed.pkgs.visualstudio.com.evil.example failed: HTTP 503'; Class = 'other'; Eligible = $false }
            @{ Text = 'request to https://packagefeedproxy.microsoft.io/npm/ failed after server processed 500 packages'; Class = 'other'; Eligible = $false }
            @{ Text = 'HTTP status client error (403 Forbidden) ECONNRESET'; Class = 'auth-policy'; Eligible = $false }
            @{ Text = 'certificate verify failed; timed out'; Class = 'tls-certificate'; Eligible = $false }
            @{ Text = 'npm ERR! E404 package not in this registry'; Class = 'package-absence'; Eligible = $false }
            @{ Text = 'npm ERR! ETARGET no matching version found'; Class = 'package-absence'; Eligible = $false }
            @{ Text = 'npm ERR! ERESOLVE unable to resolve'; Class = 'package-or-local'; Eligible = $false }
            @{ Text = 'HTTP 429 too many requests'; Class = 'rate-limit'; Eligible = $false }
        )
        foreach ($case in $cases) {
            $class = Get-PackageFailureClass -Output $case.Text -TimedOut $false -LaunchFailed $false
            $class | Should -BeExactly $case.Class
            (Test-PackageFallbackEligible $class) | Should -Be $case.Eligible
        }
    }
}

Describe 'corporate-first package runner' {
    It 'stops after one successful corporate attempt' {
        $result = Invoke-FakeNpm -Mode success
        $result.Succeeded | Should -BeTrue
        $result.FallbackUsed | Should -BeFalse
        @($result.Attempts).Count | Should -Be 1
        $result.Attempts[0].Source | Should -BeExactly 'corporate'
    }

    It 'retries public exactly once after an eligible corporate 503' {
        $result = Invoke-FakeNpm -Mode 503
        $result.Succeeded | Should -BeTrue
        $result.FallbackUsed | Should -BeTrue
        @($result.Attempts).Count | Should -Be 2
        $result.Attempts[0].FailureClass | Should -BeExactly 'http-5xx'
        $result.Attempts[1].Source | Should -BeExactly 'public'

        $arguments = @(Get-Content -LiteralPath $script:ArgumentLog)
        $arguments.Count | Should -Be 2
        $arguments[0] | Should -Match 'packagefeedproxy\.microsoft\.io/npm/'
        $arguments[0] | Should -Match '--@openai:registry=https://packagefeedproxy\.microsoft\.io/npm/'
        $arguments[1] | Should -Match 'registry\.npmjs\.org/'
        $arguments[1] | Should -Match '--@openai:registry=https://registry\.npmjs\.org/'
    }

    It 'does not retry when fallback is disabled' {
        $result = Invoke-FakeNpm -Mode 503 -AllowFallback $false
        $result.Succeeded | Should -BeFalse
        @($result.Attempts).Count | Should -Be 1
    }

    It 'does not retry denied failures' {
        foreach ($mode in '403', 'tls', '404', 'solver') {
            Remove-Item -LiteralPath $script:ArgumentLog -Force -ErrorAction SilentlyContinue
            $result = Invoke-FakeNpm -Mode $mode
            $result.Succeeded | Should -BeFalse
            @($result.Attempts).Count | Should -Be 1 -Because "$mode must not bypass corporate policy"
        }
    }

    It 'keeps fallback inert on unmanaged machines' {
        $result = Invoke-FakeNpm -Mode 503 -Managed $false
        $result.Succeeded | Should -BeFalse
        @($result.Attempts).Count | Should -Be 1
        $result.Attempts[0].Source | Should -BeExactly 'ambient'
    }

    It 'classifies a runner-enforced timeout and retries at most once' {
        $result = Invoke-FakeNpm -Mode timeout -TimeoutSeconds 1
        $result.Succeeded | Should -BeFalse
        @($result.Attempts).Count | Should -Be 2
        $result.Attempts[0].FailureClass | Should -BeExactly 'timeout'
        $result.Attempts[1].FailureClass | Should -BeExactly 'timeout'
    }

    It 'restores parent registry state and removes temporary npm configs' {
        $previous = $env:npm_config_registry
        try {
            $env:npm_config_registry = 'https://parent.example.test/'
            $null = Invoke-FakeNpm -Mode 503
            $env:npm_config_registry | Should -BeExactly 'https://parent.example.test/'
            $configPaths = @(Get-Content -LiteralPath $script:ConfigLog | Where-Object { $_ })
            $configPaths.Count | Should -BeGreaterThan 0
            foreach ($path in $configPaths) { $path | Should -Not -Exist }
            $configContent = Get-Content -Raw -LiteralPath $script:ConfigContentLog
            $configContent | Should -Match 'strict-ssl=false'
            $configContent | Should -Match 'cafile=C:\\ca\.pem'
            $configContent | Should -Not -Match '(?i)registry|auth|token|password|otp'
        } finally {
            if ($null -eq $previous) { Remove-Item Env:npm_config_registry -ErrorAction SilentlyContinue }
            else { $env:npm_config_registry = $previous }
        }
    }

    It 'redacts credentials from captured child output' {
        $result = Invoke-FakeNpm -Mode credential -AllowFallback $false
        $result.Stderr | Should -Not -Match 'user:secret'
        $result.Stderr | Should -Match '\*\*\*:\*\*\*@example\.test'
    }
}

Describe 'source argument isolation' {
    It 'places uv source flags at supported subcommand levels' {
        $run = Add-UvSourceArguments -Arguments @('run', '--no-project', 'python') -SourceUrl 'https://index.example/simple'
        ($run -join ' ') | Should -BeExactly '--no-config run --default-index https://index.example/simple --index-strategy first-index --no-project python'
        $tool = Add-UvSourceArguments -Arguments @('tool', 'install', 'demo') -SourceUrl 'https://index.example/simple'
        ($tool -join ' ') | Should -BeExactly '--no-config tool install --default-index https://index.example/simple --index-strategy first-index demo'
    }

    It 'removes extra uv and pip indexes only from the child environment' {
        $previous = $env:UV_EXTRA_INDEX_URL
        try {
            $env:UV_EXTRA_INDEX_URL = 'https://extra.example.test/'
            $child = New-PackageAttemptEnvironment -Manager uv
            $child.UV_EXTRA_INDEX_URL | Should -BeNullOrEmpty
            $child.PIP_EXTRA_INDEX_URL | Should -BeNullOrEmpty
            $env:UV_EXTRA_INDEX_URL | Should -BeExactly 'https://extra.example.test/'
        } finally {
            if ($null -eq $previous) { Remove-Item Env:UV_EXTRA_INDEX_URL -ErrorAction SilentlyContinue }
            else { $env:UV_EXTRA_INDEX_URL = $previous }
        }
    }

    It 'removes npm registry and authentication variables only from the child' {
        $previousToken = $env:NPM_TOKEN
        $previousAuthToken = $env:NPM_AUTH_TOKEN
        $previousOtp = $env:npm_config_otp
        $scopedName = 'npm_config_//registry.npmjs.org/:_authToken'
        $previousAuth = [Environment]::GetEnvironmentVariable($scopedName, 'Process')
        try {
            $env:NPM_TOKEN = 'parent-secret'
            $env:NPM_AUTH_TOKEN = 'parent-auth-secret'
            $env:npm_config_otp = '123456'
            [Environment]::SetEnvironmentVariable($scopedName, 'scoped-secret', 'Process')
            $child = New-PackageAttemptEnvironment -Manager npm
            $child.NPM_TOKEN | Should -BeNullOrEmpty
            $child.NPM_AUTH_TOKEN | Should -BeNullOrEmpty
            $child.npm_config_otp | Should -BeNullOrEmpty
            $child[$scopedName] | Should -BeNullOrEmpty
            $env:NPM_TOKEN | Should -BeExactly 'parent-secret'
            [Environment]::GetEnvironmentVariable($scopedName, 'Process') | Should -BeExactly 'scoped-secret'
        } finally {
            if ($null -eq $previousToken) { Remove-Item Env:NPM_TOKEN -ErrorAction SilentlyContinue }
            else { $env:NPM_TOKEN = $previousToken }
            if ($null -eq $previousAuthToken) { Remove-Item Env:NPM_AUTH_TOKEN -ErrorAction SilentlyContinue }
            else { $env:NPM_AUTH_TOKEN = $previousAuthToken }
            if ($null -eq $previousOtp) { Remove-Item Env:npm_config_otp -ErrorAction SilentlyContinue }
            else { $env:npm_config_otp = $previousOtp }
            [Environment]::SetEnvironmentVariable($scopedName, $previousAuth, 'Process')
        }
    }
}
}
