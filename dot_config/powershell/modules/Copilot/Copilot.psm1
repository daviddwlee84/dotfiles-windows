#Requires -Version 7.4
#Requires -PSEdition Core
# Copilot.psm1 — GitHub Copilot agent gateway for Claude Code and Codex, native
# PowerShell port of the POSIX 43_copilot_proxy.sh / 44_copilot_embed.sh.
#
# Runs the maintained copilot-api fork (npm @jeffreycao/copilot-api) from a pinned
# local install so a GitHub Copilot subscription can back Claude Code and Codex.
# The optional Bun throttle shim (copilot-throttle-shim.js) is reused verbatim from
# the unix side.
#
# Public commands (exported with their original hyphenated names for muscle
# memory — PSUseApprovedVerbs is intentionally waived):
#   copilot-proxy [start|stop|restart|status|doctor [--live]|logs [shim|N]|shim [on|off|status]|whoami|auth|reinstall]
#   copilot-run <cmd...>            run a command with the proxy env injected
#   claude-copilot [--fast] [args...] one-off Claude Code session on the proxy
#   claude-copilot-once [args...]   pinned one-shot session, auto-reverted
#   codex-copilot [args...]         one-off Codex session on Responses proxy
#   codex-copilot-once [args...]    identical zero-persistence alias
# (claude-copilot / -once run claude with --dangerously-skip-permissions — the
#  proxy flow is the trusted, hands-off path; plain `claude` is unaffected.)
#   copilot-here [on|off|status]    per-project pin via ./.claude/settings.local.json
#   copilot-model [<id>|-l|-c|--auto]  switch the pinned model
#   copilot-embed [--model M] [--json] [TEXT|-] | -l
#   semsearch index [PATH...] | semsearch <QUERY> [-k N] [--corpus PATH]
#
# Contract preserved from the unix version: token at
# ~/.local/share/copilot-api/github_token, ports 4141 (proxy) / 4142 (shim),
# state under $XDG_STATE_HOME/copilot-proxy, per-project ./.claude/settings.local.json
# pin, default model gpt-5.6-sol[1m], and the ANTHROPIC_* env block.
#
# The pinned package is INSTALLED ONCE into $XDG_DATA_HOME/copilot-api/pkg and the
# proxy runs that binary directly. It deliberately does NOT use `bunx` at launch:
# bunx re-resolves the package on every start, and bun stalls forever resolving
# through a socks proxy — which wedged `start` at "Resolving dependencies" AND kept
# bun's global cache lock, so every retry hung too. Force a re-install with
# `copilot-proxy reinstall`.
#
# Env knobs:
#   COPILOT_PROXY_PORT   default 4141    - port the proxy listens on
#   COPILOT_PROXY_START_TIMEOUT default 45 - seconds allowed for model refresh
#   COPILOT_SHIM_PORT    default 4142    - throttle shim port
#   COPILOT_SHIM_MAX     default 4       - concurrent in-flight upstream POSTs
#   COPILOT_SHIM_RETRIES default 3       - same-model transient retry attempts
#   COPILOT_SHIM_BACKOFF_MS default 500  - base retry backoff (doubles per try)
#   COPILOT_SHIM_PING_MS default 15000   - SSE ping interval; 0 disables pings
#                                          without disabling the stall watchdog
#   COPILOT_SHIM_PING_AFTER_MS default 10000 - grace before the slow SSE path
#   COPILOT_SHIM_STALL_MS default 240000 - pre-header and mid-stream watchdog;
#                                          0 disables
#   COPILOT_API_PKG      default persisted selection, then @jeffreycao/copilot-api@2.3.4
#                          (name or @scope/name + optional version/tag/range;
#                           aliases/local/git/URL specs are rejected before cleanup)
#   COPILOT_CLAUDE_MODEL                 - override the pinned model
#   COPILOT_PROXY_QUIET  1               - add the telemetry-suppressing env keys
#   COPILOT_INSTALL_NOPROXY 1            - skip straight to the no-proxy install try
#   COPILOT_HTTP_PROXY   default auto    - Node->GitHub /models egress:
#                          auto   = use the Windows System Proxy (WinINET registry)
#                                   or HTTPS_PROXY when either is set; Node ignores
#                                   the system setting unless it is passed the env.
#                          always = same, but warn when no proxy is found
#                          never  = never pass --proxy-env
#                          http://127.0.0.1:PORT = force that URL

Set-StrictMode -Off

# ------------------------------------------------------------------ helpers ---
$script:CopilotDefaultPkg = '@jeffreycao/copilot-api@2.3.4'
$script:CopilotVerifiedIntegrities = @{
    '2.3.4' = 'sha512-yRMH3wQAH74a0K/3Gl0S3itSL7Dza/7qOGG32PXV3tKRd4feG3utpuIQf42HhnhIdcBwMz3qhmeWBPQrPxZQMQ=='
    '2.3.0' = 'sha512-4h7ysNAO8N9zJkIcOnNPio9asGTMsRkvQ70deSRBSwkBJFOZXYeoKmiHU06VSP712gVNaTrRA7abLAPkTuINqA=='
    '2.1.0' = 'sha512-9/Ro1UzrYT/erB7eR/rf61XHFyc5TOwQ94B6ij/Wu91TD1hnmbuqYu/PavKGUQ7YDBVCXFENRRvQSpTkS0X3eA=='
}
function script:Get-CopilotPort { if ($env:COPILOT_PROXY_PORT) { $env:COPILOT_PROXY_PORT } else { '4141' } }
function script:Get-CopilotPkgSelectionState { Join-Path (Get-XdgState) 'copilot-proxy/package.json' }
function script:Get-CopilotPkgSelection {
    $path = Get-CopilotPkgSelectionState
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}
function script:Get-CopilotPkg {
    if ($env:COPILOT_API_PKG) { return $env:COPILOT_API_PKG }
    $selection = Get-CopilotPkgSelection
    if ($selection -and -not [string]::IsNullOrWhiteSpace([string]$selection.spec)) { return [string]$selection.spec }
    $script:CopilotDefaultPkg
}
function script:Get-CopilotVerifiedIntegrity {
    param([Parameter(Mandatory)] [string] $Version)
    [string]$script:CopilotVerifiedIntegrities[$Version]
}
function script:Write-CopilotPkgSelection {
    param([Parameter(Mandatory)] [string] $Spec, [Parameter(Mandatory)] [string] $Integrity, [string] $Registry = 'https://registry.npmjs.org')
    $path = Get-CopilotPkgSelectionState
    $dir = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = "$path.tmp-$([guid]::NewGuid())"
    try {
        [ordered]@{ spec = $Spec; integrity = $Integrity; registry = $Registry; selected_at = [DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function script:Get-CopilotPkgFlavor {
    switch -Regex (Get-CopilotPkg) { '^copilot-api(@.*)?$' { 'original' } default { 'fork' } }
}
function script:Get-CopilotBase    { "http://localhost:$(Get-CopilotPort)" }
function script:Get-CopilotTmp     { if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() } }
function script:Get-CopilotLogFile { Join-Path (Get-CopilotTmp) "copilot-api-$(Get-CopilotPort).log" }
function script:Rotate-CopilotLog {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not [System.IO.File]::Exists($Path)) { return }
    Remove-Item "$Path.3" -Force -ErrorAction SilentlyContinue
    if ([System.IO.File]::Exists("$Path.2")) { Move-Item -LiteralPath "$Path.2" -Destination "$Path.3" -Force }
    if ([System.IO.File]::Exists("$Path.1")) { Move-Item -LiteralPath "$Path.1" -Destination "$Path.2" -Force }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
}
function script:Get-CopilotPidFile { Join-Path (Get-CopilotTmp) "copilot-api-$(Get-CopilotPort).pid" }
function script:Get-CopilotToken   { Join-Path $HOME '.local/share/copilot-api/github_token' }

function script:Get-XdgState { if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $HOME '.local/state' } }
function script:Get-XdgConfig { if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' } }
function script:Get-XdgData { if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' } }

# --- pinned package install (run the binary, never `bunx` at launch) -----------
#
# Why an install prefix instead of `bunx <pkg> start`: bunx re-resolves the
# package on EVERY launch, and bun hangs indefinitely resolving through a socks
# proxy (a browser/curl through the same proxy is fine, which is what makes it so
# confusing). The wedged installer then keeps bun's global install-cache lock, so
# every retry hangs identically and stacks another zombie. Installing once and
# running the resulting binary removes the per-start resolve entirely — a warm
# start does zero network before it binds the port.

# Parse only registry package specs: name or @scope/name, optionally followed by
# a version/tag/range. npm aliases and local/git/URL selectors are rejected before
# their text can reach any filesystem path or destructive cleanup.
function script:Get-CopilotPkgSpecInfo {
    $spec = Get-CopilotPkg
    $match = [regex]::Match(
        $spec,
        '^(?<name>@[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*|[A-Za-z0-9][A-Za-z0-9._-]*)(?:@(?<selector>.+))?$'
    )
    if (-not $match.Success) { return $null }
    $selector = [string]$match.Groups['selector'].Value
    if ($selector -and (
        $selector -match '^(?:npm:|file:|link:|https?:|git(?:\+[^:]*)?:|github:|gitlab:|bitbucket:)' -or
        $selector -match '[\\/]'
    )) { return $null }
    [pscustomobject]@{
        Name     = [string]$match.Groups['name'].Value
        Selector = $selector
    }
}

function script:Get-CopilotPkgName {
    $info = Get-CopilotPkgSpecInfo
    if ($info) { $info.Name } else { $null }
}

function script:Get-CopilotPkgPrefix { Join-Path (Get-XdgData) 'copilot-api/pkg' }
# Records verified installed metadata, so bumping COPILOT_API_PKG (or the pinned
# default) re-installs instead of silently running an old or partial tree.
function script:Get-CopilotPkgStamp { Join-Path (Get-CopilotPkgPrefix) '.installed-spec' }

# Exact registry selectors can be verified against installed package metadata.
function script:Get-CopilotPkgExactVersion {
    $info = Get-CopilotPkgSpecInfo
    if ($info -and $info.Selector -match '^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$') {
        return $Matches[1]
    }
    $null
}

function script:Get-CopilotDependencyRegistry {
    try {
        $raw = @(& chezmoi data --format json 2>$null)
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $data = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
            if ([bool]$data.managedMachine) { return 'https://packagefeedproxy.microsoft.io/npm/' }
            if ([bool]$data.useChineseMirror) { return 'https://registry.npmmirror.com' }
        }
    } catch { $null }
    if ($env:npm_config_registry) { return $env:npm_config_registry }
    'https://registry.npmjs.org/'
}

function script:Get-CopilotPkgMetadata {
    $name = Get-CopilotPkgName
    if (-not $name) { return $null }
    $path = Join-Path (Get-CopilotPkgPrefix) "node_modules/$name/package.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$json.name) -or
            [string]::IsNullOrWhiteSpace([string]$json.version)) { return $null }
        [pscustomobject]@{
            Name    = [string]$json.name
            Version = [string]$json.version
            Path    = $path
        }
    } catch { $null }
}

function script:Get-CopilotPkgStampMetadata {
    $path = Get-CopilotPkgStamp
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$json.requestedSpec) -or
            [string]::IsNullOrWhiteSpace([string]$json.name) -or
            [string]::IsNullOrWhiteSpace([string]$json.version)) { return $null }
        [pscustomobject]@{
            RequestedSpec = [string]$json.requestedSpec
            Name          = [string]$json.name
            Version       = [string]$json.version
        }
    } catch { $null }
}

function script:Get-CopilotPkgLegacyStamp {
    $path = Get-CopilotPkgStamp
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $raw = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()
        if ($raw -and -not $raw.StartsWith('{')) { return $raw }
    } catch { $null }
    $null
}

function script:Write-CopilotPkgStamp {
    param([Parameter(Mandatory)] $Metadata)
    [ordered]@{
        requestedSpec = Get-CopilotPkg
        name          = [string]$Metadata.Name
        version       = [string]$Metadata.Version
    } | ConvertTo-Json -Compress | Set-Content -Path (Get-CopilotPkgStamp) -Encoding utf8
}

function script:Initialize-CopilotPkgSelection {
    if ($env:COPILOT_API_PKG -or (Test-Path -LiteralPath (Get-CopilotPkgSelectionState))) { return }
    $metadata = Get-CopilotPkgMetadata
    if (-not $metadata -or $metadata.Name -cne '@jeffreycao/copilot-api') { return }
    $stamp = Get-CopilotPkgStampMetadata
    $spec = if ($stamp -and $stamp.Name -ceq $metadata.Name -and $stamp.Version -ceq $metadata.Version) {
        $stamp.RequestedSpec
    } else { Get-CopilotPkgLegacyStamp }
    if ($spec -notmatch '^@jeffreycao/copilot-api@(?<version>\d+\.\d+\.\d+)$' -or $Matches.version -cne $metadata.Version) { return }
    $integrity = Get-CopilotVerifiedIntegrity -Version $metadata.Version
    if (-not $integrity -or -not (Test-CopilotPkgDependencies -Metadata $metadata) -or $null -eq (Get-CopilotPkgLaunch)) { return }
    Write-CopilotPkgSelection -Spec $spec -Integrity $integrity
}

# The binlink bun wrote, if any. Bun on Windows writes node_modules/.bin/<name>.exe
# (plus a .bunx sidecar); the other extensions cover an npm/yarn-populated prefix.
# Returns $null when no directly-runnable shim exists — Get-CopilotPkgLaunch then
# falls back to `bun run`, which resolves from the local node_modules offline.
function script:Get-CopilotPkgBin {
    $binDir = Join-Path (Get-CopilotPkgPrefix) 'node_modules/.bin'
    foreach ($ext in '.exe', '.cmd', '.bat', '', '.ps1') {
        $p = Join-Path $binDir "copilot-api$ext"
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $null
}

# How to invoke the installed proxy: @{ Exe; Pre; Cwd }. Cwd is non-null only for
# the `bun run` fallback, which must resolve node_modules/.bin from the prefix.
#
# The prefix is deliberately NOT passed as an argument (`bun run --cwd <path>`):
# Start-Process joins -ArgumentList with spaces and does no quoting, so a prefix
# under a $HOME containing a space ("C:\Users\Da-Wei Lee\...") would arrive split
# across two argv entries. -WorkingDirectory takes the path as a real parameter.
function script:Get-CopilotPkgLaunch {
    $bin = Get-CopilotPkgBin
    # .ps1 can't be Start-Process'd directly, and a bare extensionless shim is a
    # shell script — route both through `bun run`, which finds node_modules/.bin.
    if ($bin -and [System.IO.Path]::GetExtension($bin) -in '.exe', '.cmd', '.bat') {
        return @{ Exe = $bin; Pre = @(); Cwd = $null }
    }
    if ($bin -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        return @{ Exe = 'bun'; Pre = @('run', 'copilot-api'); Cwd = (Get-CopilotPkgPrefix) }
    }
    # The hash-pinned CDN fallback carries the published dist files but no npm
    # binlink. Run its declared entry point directly with Bun.
    $metadata = Get-CopilotPkgMetadata
    $main = if ($metadata) { Join-Path (Split-Path -Parent $metadata.Path) 'dist/main.js' } else { $null }
    if ($main -and (Test-Path -LiteralPath $main -PathType Leaf) -and (Get-Command bun -ErrorAction SilentlyContinue)) {
        return @{ Exe = 'bun'; Pre = @($main); Cwd = (Get-CopilotPkgPrefix) }
    }
    $null
}

function script:Test-CopilotPkgDependencies {
    param($Metadata = (Get-CopilotPkgMetadata))
    if (-not $Metadata) { return $false }
    try {
        $package = Get-Content -LiteralPath $Metadata.Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $names = if ($package.dependencies) { @($package.dependencies.PSObject.Properties.Name) } else { @() }
        $packageDir = Split-Path -Parent $Metadata.Path
        $prefix = Get-CopilotPkgPrefix
        foreach ($dependency in $names) {
            $local = Join-Path $packageDir "node_modules/$dependency/package.json"
            $hoisted = Join-Path $prefix "node_modules/$dependency/package.json"
            if (-not (Test-Path -LiteralPath $local -PathType Leaf) -and
                -not (Test-Path -LiteralPath $hoisted -PathType Leaf)) { return $false }
        }
        return $true
    } catch { return $false }
}

# Did the requested package actually land in the prefix and remain runnable?
# Metadata is authoritative: a stale directory or binlink alone never satisfies
# this postcondition. Exact selectors must also match the installed version.
function script:Test-CopilotPkgInstalled {
    param($Metadata = (Get-CopilotPkgMetadata))
    if (-not $Metadata) { return $false }
    if ($Metadata.Name -cne (Get-CopilotPkgName)) { return $false }
    $exactVersion = Get-CopilotPkgExactVersion
    if ($exactVersion -and $Metadata.Version -cne $exactVersion) { return $false }
    (Test-CopilotPkgDependencies -Metadata $Metadata) -and $null -ne (Get-CopilotPkgLaunch)
}

# Is the CURRENT selector installed, stamped with verified metadata and runnable?
function script:Test-CopilotPkgReady {
    $metadata = Get-CopilotPkgMetadata
    if (-not (Test-CopilotPkgInstalled -Metadata $metadata)) { return $false }
    $stamp = Get-CopilotPkgStampMetadata
    if (-not $stamp) { return $false }
    ($stamp.RequestedSpec -ceq (Get-CopilotPkg)) -and
        ($stamp.Name -ceq $metadata.Name) -and
        ($stamp.Version -ceq $metadata.Version)
}

# Remove only the requested package and its dedicated launch shims. Resolve and
# verify containment before deletion, then require cleanup to be complete: retained
# matching files could otherwise certify a failed installer attempt.
function script:Clear-CopilotPkgInstallTarget {
    $name = Get-CopilotPkgName
    if (-not $name) {
        Write-Error "copilot-proxy: unsupported COPILOT_API_PKG registry spec '$(Get-CopilotPkg)'"
        return $false
    }

    $nodeModules = [System.IO.Path]::GetFullPath((Join-Path (Get-CopilotPkgPrefix) 'node_modules'))
    $packageDir = [System.IO.Path]::GetFullPath((Join-Path $nodeModules $name))
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $nodeModulesRoot = $nodeModules.TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $packageDir.StartsWith($nodeModulesRoot, $comparison)) {
        Write-Error "copilot-proxy: refusing package cleanup outside $nodeModulesRoot"
        return $false
    }

    $binDir = Join-Path $nodeModules '.bin'
    try {
        if ([System.IO.Directory]::Exists($packageDir)) {
            [System.IO.Directory]::Delete($packageDir, $true)
        }
        if ([System.IO.Directory]::Exists($binDir)) {
            foreach ($binPath in [System.IO.Directory]::GetFiles($binDir, 'copilot-api*')) {
                [System.IO.File]::Delete($binPath)
            }
        }
    } catch {
        Write-Error "copilot-proxy: could not clear the previous package target ($_)"
        return $false
    }

    $remainingBin = if ([System.IO.Directory]::Exists($binDir)) {
        @([System.IO.Directory]::GetFiles($binDir, 'copilot-api*'))
    } else { @() }
    if ([System.IO.Directory]::Exists($packageDir) -or $remainingBin.Count -gt 0) {
        Write-Error 'copilot-proxy: previous package target is still present after cleanup; refusing to run the installer'
        return $false
    }
    $true
}

# One package-install attempt in -Dir, bounded by -BudgetSeconds. npm is preferred
# because it supports Azure Artifacts' credential-provider token in ~/.npmrc;
# Bun does not. -NoProxy strips the proxy env for the child. Returns $true only
# when matching metadata and a runnable launch path exist afterwards.
#
# Success is judged from the FILESYSTEM, not $p.ExitCode: a Start-Process -PassThru
# object reports ExitCode 0 even for a child that exited non-zero (verified — the
# .Handle-caching workaround does not help either), so trusting it would let a
# failed install write the .installed-spec stamp and silently pin a broken prefix.
#
# The kill on expiry is the load-bearing part: a stalled `bun add` left running
# keeps bun's global install-cache lock, and THAT is what made every subsequent
# start hang too. Never let one escape.
function script:Invoke-CopilotPkgInstallTry {
    param([string] $Dir, [switch] $NoProxy, [int] $BudgetSeconds)

    if (-not (Clear-CopilotPkgInstallTarget)) { return $false }
    $proxyVars = 'ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy'
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    $installer = if ($npm) {
        @{ File = $npm.Source; Args = @('install', '--no-save', '--no-audit', '--no-fund', (Get-CopilotPkg)) }
    } else {
        Write-Warning 'copilot-proxy: npm.cmd not found; falling back to Bun (authenticated Azure Artifacts feeds require npm).'
        @{ File = 'bun'; Args = @('add', (Get-CopilotPkg), '--no-summary') }
    }
    $saved = @{}
    if ($NoProxy) {
        foreach ($v in $proxyVars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    }
    try {
        $p = Start-Process -FilePath $installer.File -ArgumentList $installer.Args `
            -WorkingDirectory $Dir -PassThru -NoNewWindow -ErrorAction Stop
        if ($p.WaitForExit($BudgetSeconds * 1000)) { return (Test-CopilotPkgInstalled) }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        # The subshell's child is the one actually holding the install lock.
        $name = [regex]::Escape((Get-CopilotPkgName))
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in 'bun.exe', 'node.exe' -and $_.CommandLine -match '\b(add|install)\b' -and $_.CommandLine -match $name } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        return $false
    } catch {
        Write-Error "copilot-proxy: could not launch package installer ($_)"; return $false
    } finally {
        if ($NoProxy) {
            foreach ($v in $proxyVars) {
                if ($null -eq $saved[$v]) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
                else { Set-Item "env:$v" $saved[$v] }
            }
        }
    }
}

# Runtime files from the exact public npm package, mirrored by jsDelivr. Hashes
# are SHA-256/base64 from data.jsdelivr.com and are pinned here so a CDN response
# cannot silently replace the reviewed 2.3.4 gateway. This fallback is deliberately
# unavailable for arbitrary COPILOT_API_PKG overrides.
function script:Get-CopilotPkgCdnManifest {
    if ((Get-CopilotPkg) -cne $script:CopilotDefaultPkg) { return $null }
    [pscustomobject]@{
        BaseUrl = 'https://cdn.jsdelivr.net/npm/@jeffreycao/copilot-api@2.3.4/'
        Files   = [ordered]@{
            'dist/auth-B-ry4rJx.js'          = 'oWtI7Il1Ycm7QGGAVNkDB/YSNVIqNeANzxn4ySMq2DA='
            'dist/auth-OxiT7vCr.js'           = 'SJB5e46Bw/j2v+/71rmSMCKiD/HtKDlTnBwDCbZNBw0='
            'dist/config-CEGVuc_4.js'         = 'NajCmIfzBpUIXfPVKO7Yhnqv6qLDJg450xuKGus/OFs='
            'dist/debug-Db0SCVSP.js'          = 'PYQ0ZQkhSIKzjmSQNVuod7UX7hL7rmk74/hn+jbx6dg='
            'dist/electron-fetch-BRX-ug5E.js' = 'oBa4GH1/3n4w5AT0m9tn47ir3PqqWvVeQBp2cTmsni8='
            'dist/fast-path-BoMnZCVC.js'      = 'Po6L2Mh+yjlCby1RJlE5EZN9xt4oNsetIP2VdyOqhxo='
            'dist/main.js'                    = 'vaVfZjZeDbPTprzN05FdWTFOrXvpzTGBma4gJ7/wTrA='
            'dist/mcp-fpSlKZxK.js'            = 'PTwf6tu6Bq2ekPOlVLl+y8qwWBZZgzwIDjEtEZsPGVc='
            'dist/mcp-server-BeNu_Edl.js'     = 'ruQkaC7svMl8bgEQIJC8j9mMoevqnePPQeXuYDrewrQ='
            'dist/mcp-server-DQ4r-fAy.js'      = 'Sl3DpTS6mFf+wfNAd/sT+9fNs3BTy1RIDXwwZkwG30A='
            'dist/models-Bd9M8jdy.js'          = 'jaq8btjRfvcBN7vv3KVMdXNUDdE56ZMk0XT+OaErNzE='
            'dist/server-CKVtJPpg.js'          = '5XtIj3RhHIpm17Vzxi0RRlSUqEBuzJWtjEvvN7OAUGY='
            'dist/start-DqfeTNPH.js'           = 'o8WBjEUhzDLiGwJjf8mEFO7Z+x6AGili583In+lOIi8='
            'dist/tls-Aq1Dd8E2.js'             = 'jeyg/nuW+psGNRPqRbmCUgHCuceRjrsofuHL4qTR9iM='
            'dist/token-C3cN0vNj.js'           = 'J2B+JhDRQon5iegPMhNUg7IwrO6EW8eHBq6Td9Qbkyk='
            'dist/tool-search-Ds1vbmGG.js'     = 'nayapOul67JQ5MZlG6VHjbOOmtFWkdp57Ix1QBR6XjE='
            'LICENSE'                          = 'heZrUUWQ2XF0DN2cwkTHVOuqFpAhW/xs6boMUHgC+zk='
            'package.json'                     = 'E4yUXnzcYYCBL714huIHrmTTBz/9Im4/4BvIEJLxsTY='
            'pages/index.html'                 = 'rOF8krw8Kq+LPqy6n6N+Zy9YhO5lzJ9cmyxoz5DYuts='
        }
    }
}

function script:Get-CopilotSha256Base64 {
    param([Parameter(Mandatory)] [string] $Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToBase64String($sha.ComputeHash($stream)) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
}

function script:Install-CopilotPkgDependencies {
    param([Parameter(Mandatory)] [string] $PackageDir, [int] $BudgetSeconds = 120)
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) {
        Write-Error 'copilot-proxy: npm.cmd is required to install CDN package dependencies through the configured registry'
        return $false
    }
    $emptyUserConfig = Join-Path $PackageDir '.copilot-empty-user.npmrc'
    $emptyGlobalConfig = Join-Path $PackageDir '.copilot-empty-global.npmrc'
    $packageJson = Join-Path $PackageDir 'package.json'
    $originalPackageJson = $null
    try {
        $originalPackageJson = [System.IO.File]::ReadAllText($packageJson)
        $package = $originalPackageJson | ConvertFrom-Json -ErrorAction Stop
        $minimal = [ordered]@{ name = $package.name; version = $package.version; private = $true; dependencies = $package.dependencies } | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($packageJson, $minimal, [System.Text.UTF8Encoding]::new($false))
        $npmArgs = @(
            'install', '--omit=dev', '--ignore-scripts', '--no-save', '--package-lock=false', '--no-audit', '--no-fund',
            "--userconfig=$emptyUserConfig", "--globalconfig=$emptyGlobalConfig"
        )
        $npmArgs += "--registry=$(Get-CopilotDependencyRegistry)"
        $p = Start-Process -FilePath $npm.Source -ArgumentList $npmArgs -WorkingDirectory $PackageDir -PassThru -NoNewWindow -ErrorAction Stop
        if (-not $p.WaitForExit($BudgetSeconds * 1000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return $false
        }
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-CopilotPkgDependencies) { return $true }
            Start-Sleep -Milliseconds 250
        }
        return $false
    } catch {
        Write-Error "copilot-proxy: could not install CDN package dependencies ($_)"
        return $false
    } finally {
        if ($null -ne $originalPackageJson) {
            [System.IO.File]::WriteAllText($packageJson, $originalPackageJson, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

function script:Install-CopilotPkgFromCdn {
    $manifest = Get-CopilotPkgCdnManifest
    if (-not $manifest) { return $false }
    if (-not (Clear-CopilotPkgInstallTarget)) { return $false }

    $packageDir = Join-Path (Get-CopilotPkgPrefix) 'node_modules/@jeffreycao/copilot-api'
    $downloadDir = Join-Path (Get-CopilotPkgPrefix) ".cdn-$([guid]::NewGuid())"
    try {
        New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
        $baseUrls = @($manifest.BaseUrl, ($manifest.BaseUrl -replace '^https://cdn\.jsdelivr\.net/', 'https://fastly.jsdelivr.net/')) | Select-Object -Unique
        foreach ($relativePath in $manifest.Files.Keys) {
            $downloadPath = Join-Path $downloadDir ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $downloadPath) | Out-Null
            $downloaded = $false
            $lastError = $null
            foreach ($baseUrl in $baseUrls) {
                foreach ($attempt in 1..2) {
                    try {
                        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
                        Invoke-WebRequest -Uri ($baseUrl + $relativePath) -OutFile $downloadPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                        $actualHash = Get-CopilotSha256Base64 -Path $downloadPath
                        if ($actualHash -cne $manifest.Files[$relativePath]) { throw "hash mismatch for $relativePath" }
                        $downloaded = $true
                        break
                    } catch { $lastError = $_ }
                }
                if ($downloaded) { break }
            }
            if (-not $downloaded) { throw "could not download verified $relativePath ($lastError)" }
        }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $packageDir) | Out-Null
        Move-Item -LiteralPath $downloadDir -Destination $packageDir -ErrorAction Stop
        $metadata = Get-CopilotPkgMetadata
        $expectedVersion = Get-CopilotPkgExactVersion
        if (-not $metadata -or $metadata.Name -cne '@jeffreycao/copilot-api' -or $metadata.Version -cne $expectedVersion) {
            throw "downloaded package metadata does not identify @jeffreycao/copilot-api@$expectedVersion"
        }
        if (-not (Install-CopilotPkgDependencies -PackageDir $packageDir)) {
            throw 'dependency installation through the configured registry failed'
        }
        return (Test-CopilotPkgInstalled)
    } catch {
        Write-Warning "copilot-proxy: pinned CDN fallback failed ($_)"
        $null = Clear-CopilotPkgInstallTarget
        return $false
    } finally {
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Ensure the pinned spec is installed. No-op (and no network) once it is.
function script:Install-CopilotPkg {
    Initialize-CopilotPkgSelection
    if (-not (Get-CopilotPkgSpecInfo)) {
        Write-Error "copilot-proxy: COPILOT_API_PKG must be a registry package spec (name or @scope/name with an optional version/tag/range); aliases and local/git/URL specs are unsupported: $(Get-CopilotPkg)"
        return $false
    }
    if (Test-CopilotPkgReady) { return $true }

    # Migrate the old one-line stamp without a network call only when an exact
    # selector, the legacy stamp, live package metadata and launch path all agree.
    $metadata = Get-CopilotPkgMetadata
    if ((Get-CopilotPkgExactVersion) -and
        (Get-CopilotPkgLegacyStamp) -ceq (Get-CopilotPkg) -and
        (Test-CopilotPkgInstalled -Metadata $metadata)) {
        Write-CopilotPkgStamp -Metadata $metadata
        return $true
    }

    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        Write-Error "copilot-proxy: bun not found (scoop install bun)"; return $false
    }
    $spec = Get-CopilotPkg; $prefix = Get-CopilotPkgPrefix
    New-Item -ItemType Directory -Force -Path $prefix | Out-Null
    # A private package.json keeps `bun add` from walking up and polluting $HOME.
    $pkgJson = Join-Path $prefix 'package.json'
    if (-not (Test-Path -LiteralPath $pkgJson)) {
        '{"name":"copilot-api-runner","private":true,"version":"0.0.0"}' | Set-Content -Path $pkgJson -Encoding utf8
    }

    Write-Host "copilot-proxy: installing $spec (one-time — later starts skip this) ..."
    # Attempt 1 honours the ambient env: on a host where the npm registry is only
    # reachable THROUGH the proxy, stripping it would break the install. Attempt 2
    # strips it, which is what rescues the socks stall. COPILOT_INSTALL_NOPROXY=1
    # skips straight to attempt 2 (saves the 45s stall on a known-bad host).
    $skipFirst = ($env:COPILOT_INSTALL_NOPROXY -eq '1')
    if ($skipFirst -or -not (Invoke-CopilotPkgInstallTry -Dir $prefix -BudgetSeconds 45)) {
        if (-not $skipFirst) {
            Write-Warning "copilot-proxy: install failed or stalled with the proxy env — retrying without it ..."
            # Drop bun's cache lock dir before retrying; the killed attempt may have
            # left it behind, and a stale lock hangs the retry for the same reason.
            $bunHome = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $HOME '.bun' }
            Remove-Item -Recurse -Force (Join-Path $bunHome 'install/cache/.tmp') -ErrorAction SilentlyContinue
        }
        if (-not (Invoke-CopilotPkgInstallTry -Dir $prefix -NoProxy -BudgetSeconds 90)) {
            Write-Warning 'copilot-proxy: configured npm registry did not provide the pin — trying the hash-pinned jsDelivr package copy; dependencies still use the configured registry ...'
            if (-not (Install-CopilotPkgFromCdn)) {
                Write-Error "copilot-proxy: could not install $spec from the configured registry or pinned CDN fallback — run 'copilot-proxy doctor'."; return $false
            }
        }
    }

    $metadata = Get-CopilotPkgMetadata
    if (-not (Test-CopilotPkgInstalled -Metadata $metadata)) {
        $actual = if ($metadata) { "$($metadata.Name)@$($metadata.Version)" } else { 'no readable package metadata' }
        Write-Error "copilot-proxy: install finished but $actual does not satisfy $spec with a runnable launch path under $prefix."
        return $false
    }
    Write-CopilotPkgStamp -Metadata $metadata
    $true
}

function script:Test-CopilotPkgHelp {
    $launch = Get-CopilotPkgLaunch
    if (-not $launch) { return $false }
    if ($launch.Cwd) { Push-Location $launch.Cwd }
    try {
        & $launch.Exe @($launch.Pre + '--help') *> $null
        return $LASTEXITCODE -eq 0
    } catch { return $false }
    finally { if ($launch.Cwd) { Pop-Location } }
}

function script:Invoke-CopilotPkgUpdate {
    param([Parameter(Mandatory)] [string] $Version)
    if ($env:COPILOT_API_PKG) {
        Write-Error 'copilot-proxy: COPILOT_API_PKG is active; refusing to mutate persisted selection.'
        return $false
    }
    $integrity = Get-CopilotVerifiedIntegrity -Version $Version
    if (-not $integrity) {
        Write-Error 'copilot-proxy: update requires a verified exact version: 2.3.4, 2.3.0, or 2.1.0.'
        return $false
    }

    Initialize-CopilotPkgSelection
    $spec = "@jeffreycao/copilot-api@$Version"
    $livePrefix = Get-CopilotPkgPrefix
    $previousPrefix = "$livePrefix.previous"
    $state = Get-CopilotPkgSelectionState
    $previousState = "$state.previous"
    $stageData = Join-Path (Split-Path -Parent (Get-XdgData)) ".copilot-update-$([guid]::NewGuid())"
    $savedData = $env:XDG_DATA_HOME
    $savedPkg = $env:COPILOT_API_PKG
    $stagePrefix = Join-Path $stageData 'copilot-api/pkg'
    $staged = $false
    try {
        $env:XDG_DATA_HOME = $stageData
        $env:COPILOT_API_PKG = $spec
        $staged = (Install-CopilotPkg) -and (Test-CopilotPkgHelp)
    } finally {
        if ($null -eq $savedData) { Remove-Item env:XDG_DATA_HOME -ErrorAction SilentlyContinue } else { $env:XDG_DATA_HOME = $savedData }
        if ($null -eq $savedPkg) { Remove-Item env:COPILOT_API_PKG -ErrorAction SilentlyContinue } else { $env:COPILOT_API_PKG = $savedPkg }
    }
    if (-not $staged) {
        Remove-Item -LiteralPath $stageData -Recurse -Force -ErrorAction SilentlyContinue
        Write-Error "copilot-proxy: staged $spec failed installation or --help verification."
        return $false
    }

    $swapBackup = "$livePrefix.swap-$([guid]::NewGuid())"
    try {
        Remove-Item -LiteralPath $previousPrefix -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $livePrefix) { Move-Item -LiteralPath $livePrefix -Destination $swapBackup }
        Move-Item -LiteralPath $stagePrefix -Destination $livePrefix
        if (Test-Path -LiteralPath $swapBackup) { Move-Item -LiteralPath $swapBackup -Destination $previousPrefix }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state) | Out-Null
        if (Test-Path -LiteralPath $state) { Copy-Item -LiteralPath $state -Destination $previousState -Force }
        Write-CopilotPkgSelection -Spec $spec -Integrity $integrity
        Write-Host "copilot-proxy: staged and selected $spec; restart explicitly when ready."
        return $true
    } catch {
        Remove-Item -LiteralPath $livePrefix -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $swapBackup) { Move-Item -LiteralPath $swapBackup -Destination $livePrefix -ErrorAction SilentlyContinue }
        Write-Error "copilot-proxy: package swap failed; previous prefix restored ($_)"
        return $false
    } finally {
        Remove-Item -LiteralPath $stageData -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $swapBackup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function script:Invoke-CopilotPkgRollback {
    $livePrefix = Get-CopilotPkgPrefix
    $previousPrefix = "$livePrefix.previous"
    $state = Get-CopilotPkgSelectionState
    $previousState = "$state.previous"
    if (-not (Test-Path -LiteralPath $previousPrefix -PathType Container) -or
        -not (Test-Path -LiteralPath $previousState -PathType Leaf)) {
        Write-Error 'copilot-proxy: no offline package rollback is available.'
        return $false
    }
    $swapPrefix = "$livePrefix.rollback-$([guid]::NewGuid())"
    $swapState = "$state.rollback-$([guid]::NewGuid())"
    try {
        Move-Item -LiteralPath $livePrefix -Destination $swapPrefix
        Move-Item -LiteralPath $previousPrefix -Destination $livePrefix
        Move-Item -LiteralPath $swapPrefix -Destination $previousPrefix
        Move-Item -LiteralPath $state -Destination $swapState
        Move-Item -LiteralPath $previousState -Destination $state
        Move-Item -LiteralPath $swapState -Destination $previousState
        $selected = Get-CopilotPkgSelection
        Write-Host "copilot-proxy: rolled back to $($selected.spec); restart explicitly when ready."
        return $true
    } catch {
        Write-Error "copilot-proxy: rollback swap failed ($_)"
        return $false
    }
}

# Run a copilot-api subcommand (auth / check-usage / debug) in the foreground.
# Honours $launch.Cwd so the `bun run` fallback resolves node_modules/.bin.
function script:Invoke-CopilotPkgCommand {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)
    if (-not (Install-CopilotPkg)) {
        $global:LASTEXITCODE = 1
        throw 'copilot-proxy: package installation or verification failed'
    }
    $launch = Get-CopilotPkgLaunch
    if (-not $launch) {
        $global:LASTEXITCODE = 1
        throw "copilot-proxy: no runnable copilot-api — try 'copilot-proxy reinstall'"
    }
    if ($launch.Cwd) { Push-Location $launch.Cwd }
    try {
        & $launch.Exe @($launch.Pre + $Argument)
        $commandExitCode = $LASTEXITCODE
        $global:LASTEXITCODE = $commandExitCode
        if ($commandExitCode -ne 0) {
            throw "copilot-proxy: copilot-api $($Argument -join ' ') failed with exit code $commandExitCode"
        }
    } finally { if ($launch.Cwd) { Pop-Location } }
}

# Live `bun add … copilot-api` processes. Install is a one-shot, so a match at
# rest is a clean stale-installer signal: a stalled one keeps bun's global
# install-cache lock, which wedges every later install too. Invoke-CopilotPkgInstallTry
# bounds and kills its own attempts, so this should stay empty — it remains as a
# safety net for a stall we didn't spawn (e.g. a hand-run `bunx @jeffreycao/copilot-api`).
function script:Get-CopilotStaleInstaller {
    Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '\badd\b' -and $_.CommandLine -match 'copilot-api' }
}


# --- shim paths ---
function script:Get-CopilotShimPort   { if ($env:COPILOT_SHIM_PORT) { $env:COPILOT_SHIM_PORT } else { '4142' } }
function script:Get-CopilotShimBase   { "http://localhost:$(Get-CopilotShimPort)" }
function script:Get-CopilotShimScript { Join-Path (Get-XdgConfig) 'powershell/copilot-throttle-shim.js' }
function script:Get-CopilotShimLog    { Join-Path (Get-CopilotTmp) "copilot-shim-$(Get-CopilotShimPort).log" }
function script:Get-CopilotShimPid    { Join-Path (Get-CopilotTmp) "copilot-shim-$(Get-CopilotShimPort).pid" }
function script:Get-CopilotShimState  { Join-Path (Get-XdgState) 'copilot-proxy/shim' }
function script:Get-CopilotShimMetricsDb { Join-Path (Get-XdgState) 'copilot-proxy/metrics.sqlite' }
function script:Get-CopilotTokenUsageDb { Join-Path (Get-XdgData) 'copilot-api/copilot-api.sqlite' }
function script:Get-CopilotLifecycleLog { Join-Path (Get-XdgState) 'copilot-proxy/lifecycle.jsonl' }
function script:Get-CopilotProcessWatchScript { Join-Path (Get-XdgConfig) 'powershell/copilot-process-watch.ps1' }
function script:Get-CopilotStopIntent {
    param([Parameter(Mandatory)] [string] $Component, [Parameter(Mandatory)] [int] $ProcessId)
    Join-Path (Get-XdgState) "copilot-proxy/stop-$Component-$ProcessId.intent"
}
function script:Get-CopilotReadyMarker {
    param([Parameter(Mandatory)] [string] $Component, [Parameter(Mandatory)] [int] $ProcessId)
    Join-Path (Get-XdgState) "copilot-proxy/ready-$Component-$ProcessId.marker"
}
function script:Get-CopilotModuleManifest { Join-Path $PSScriptRoot 'Copilot.psd1' }
function script:Get-CopilotModelState { Join-Path (Get-XdgState) 'copilot-proxy/model' }

# --- egress: which proxy should Node use for the GitHub /models fetch? --------
#
# copilot-api fetches /models at startup and refreshes its cache periodically;
# restart forces an immediate refresh. GitHub geo-filters the Claude catalog on
# some egress paths. Node does NOT honour the Windows System Proxy on its own — it
# only sees HTTP(S)_PROXY — so a host whose browser reaches the unfiltered catalog
# could still have the proxy cache a Claude-less list, which then looks exactly
# like an entitlement problem. Resolve the URL here and hand it to the child.
#
# COPILOT_HTTP_PROXY: auto|always|never|<url>. Returns a URL or $null.
function script:Resolve-CopilotHttpProxy {
    $mode = if ($env:COPILOT_HTTP_PROXY) { $env:COPILOT_HTTP_PROXY } else { 'auto' }
    switch -Regex ($mode) {
        '^(never|off|0|false|no)$' { return $null }
        '^(http|https|socks5h?)://' { return $mode }
        '^(always|auto|on|1|true|yes)$' { break }
        default {
            Write-Warning "copilot-proxy: unknown COPILOT_HTTP_PROXY='$mode' (use auto|always|never|http://...)"
            return $null
        }
    }

    # The Windows System Proxy (WinINET). This is what Clash Verge / mihomo /
    # v2rayN write when their "System Proxy" toggle is on, so reading it covers
    # the same ground the unix side gets from its Clash detector.
    try {
        $key = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($key.ProxyEnable -eq 1 -and $key.ProxyServer) {
            # ProxyServer is either "host:port" or "http=host:port;https=host:port".
            $server = $key.ProxyServer
            if ($server -match '(?:^|;)\s*https?=([^;]+)') { $server = $Matches[1] }
            elseif ($server -match ';') { $server = ($server -split ';')[0] }
            if ($server) { return "http://$($server -replace '^https?://', '')" }
        }
    } catch { $null = $_ }

    # Fallback: an explicit env proxy in this shell.
    foreach ($v in $env:HTTPS_PROXY, $env:https_proxy, $env:HTTP_PROXY, $env:http_proxy) {
        if ($v) { return $v }
    }
    $null
}

# Model ids GitHub serves for this account RIGHT NOW, for the direct-vs-proxied
# A/B in doctor. -Via: 'direct' forces no proxy, a URL forces that proxy, absent
# uses .NET defaults. Returns sorted-unique ids, or $null on any failure.
#
# Secrets: the ghu_/bearer tokens only ever travel in request headers — never in
# a command line, never echoed.
function script:Get-CopilotUpstreamModel {
    param([string] $Via)

    $tokFile = Get-CopilotToken
    if (-not (Test-Path -LiteralPath $tokFile)) { return $null }
    $ghu = Get-Content -First 1 $tokFile -ErrorAction SilentlyContinue
    if (-not $ghu) { return $null }

    $transport = @{}
    if ($Via -eq 'direct') { $transport['NoProxy'] = $true }
    elseif ($Via) { $transport['Proxy'] = $Via }

    try {
        $ex = Invoke-RestMethod -Uri 'https://api.github.com/copilot_internal/v2/token' -TimeoutSec 10 `
            -Headers @{ 'Authorization' = "token $ghu"; 'user-agent' = 'GitHubCopilotChat/0.26.7' } `
            @transport -ErrorAction Stop
    } catch { return $null }

    $api = if ($ex.endpoints.api) { $ex.endpoints.api } else { 'https://api.githubcopilot.com' }
    if (-not $ex.token) { return $null }

    try {
        $up = Invoke-RestMethod -Uri "$api/models" -TimeoutSec 12 `
            -Headers @{
                'Authorization'            = "Bearer $($ex.token)"
                'user-agent'               = 'GitHubCopilotChat/0.26.7'
                'copilot-integration-id'   = 'vscode-chat'
            } @transport -ErrorAction Stop
    } catch { return $null }

    @($up.data.id | Where-Object { $_ } | Sort-Object -Unique)
}

# Optional ChatGPT Apps reachability. This is deliberately separate from the
# Copilot inference probes: codex_apps is a remote MCP served by chatgpt.com,
# not a localhost bridge to Codex.app and not part of GitHub Copilot.
function script:Get-CopilotProbeFailureKind {
    param($ErrorRecord)

    $message = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception.ToString()
    } else { [string]$ErrorRecord }

    if ($message -match '(?i)timed?\s*out|timeout|operation.*canceled|deadline') { return 'timeout' }
    if ($message -match '(?i)certificate|authenticationexception|ssl|tls|secure channel') { return 'tls' }
    'network'
}

function script:Invoke-CopilotOptionalHttpProbe {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Via = 'direct'
    )

    $transport = @{}
    if ($Via -eq 'direct') { $transport['NoProxy'] = $true }
    elseif ($Via) { $transport['Proxy'] = $Via }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 12 `
            -SkipHttpErrorCheck -Headers @{ 'user-agent' = 'codex-copilot-doctor/1.0' } `
            @transport -ErrorAction Stop
        $sw.Stop()
        [pscustomobject]@{
            Reached = $true
            Code    = [int]$response.StatusCode
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            Kind    = $null
            Error   = $null
        }
    } catch {
        $sw.Stop()
        [pscustomobject]@{
            Reached = $false
            Code    = 0
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            Kind    = Get-CopilotProbeFailureKind $_
            Error   = ($_.Exception.Message -replace '\s+', ' ').Trim()
        }
    }
}


function script:Test-CopilotAlive {
    try { $null = Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/models" -TimeoutSec 2 -ErrorAction Stop; $true }
    catch { $false }
}
function script:Test-CopilotShimAlive {
    try {
        $health = Invoke-RestMethod -Uri "$(Get-CopilotShimBase)/_shim/health" -TimeoutSec 2 -ErrorAction Stop
        $health.ok -eq $true
    } catch { $false }
}

# The Bun shim derives standard -> fast siblings from the proxy's live catalog.
# Keep the mapping in the shim so Codex service_tier requests and this PowerShell
# wrapper use one entitlement-aware source of truth.
function script:Get-CopilotFastRouting {
    param([switch] $Refresh)
    if (-not (Get-CopilotShimEnabled) -or -not (Test-CopilotShimAlive)) { return $null }
    $suffix = if ($Refresh) { '?refresh=1' } else { '' }
    try {
        Invoke-RestMethod -Uri "$(Get-CopilotShimBase)/_shim/fast-routing$suffix" `
            -TimeoutSec 3 -ErrorAction Stop
    } catch { $null }
}

function script:Resolve-CopilotFastModel {
    param([Parameter(Mandatory)] [string] $Model, $Routing)
    if (-not $PSBoundParameters.ContainsKey('Routing')) { $Routing = Get-CopilotFastRouting }
    if (-not $Routing -or -not $Routing.mappings) { return $null }
    if ($Routing.mappings -is [System.Collections.IDictionary]) {
        if ($Routing.mappings.Contains($Model)) { return [string]$Routing.mappings[$Model] }
        if (@($Routing.mappings.Values) -contains $Model) { return $Model }
        return $null
    }
    $property = $Routing.mappings.PSObject.Properties[$Model]
    if ($property) { return [string]$property.Value }
    if (@($Routing.mappings.PSObject.Properties.Value) -contains $Model) { return $Model }
    $null
}
function script:Get-CopilotShimEnabled {
    switch ($env:COPILOT_PROXY_SHIM) {
        { $_ -in '1', 'on', 'true', 'yes' } { return $true }
        { $_ -in '0', 'off', 'false', 'no' } { return $false }
    }
    $sf = Get-CopilotShimState
    if (Test-Path $sf) { return (Get-Content -First 1 $sf -ErrorAction SilentlyContinue) -ne 'off' }
    $true
}
# Base URL managed clients should use. An enabled-but-down shim is a HARD FAULT,
# never a silent fallback to the bare proxy: bypassing the shim quietly drops the
# SSE keepalive + stall watchdog AND the Responses tool-description normalization
# that is the whole fix for
# pitfalls/codex-copilot-empty-mcp-tool-description-400.md — so a down shim would
# reintroduce a documented 400 with no message anywhere. Callers gate on
# Assert-CopilotShim first; this only picks the URL.
#
# Deliberately identical in body to Get-CopilotPinnedBase but kept separate (as
# on Unix): they answer different questions and only one of them is allowed to
# start depending on liveness later. Do not collapse them.
function script:Get-CopilotClientBase {
    if (Get-CopilotShimEnabled) { Get-CopilotShimBase } else { Get-CopilotBase }
}
# Base URL for PERSISTENT pins (copilot-here settings.local.json). Not gated on
# currently-alive since the file outlives this session.
function script:Get-CopilotPinnedBase {
    if (Get-CopilotShimEnabled) { Get-CopilotShimBase } else { Get-CopilotBase }
}

# What is holding $Port right now:
#   'free'     nothing is listening
#   'ours'     every listener is a copilot-throttle-shim.js process
#   'foreign'  something else is listening
#   'unknown'  the port could not be inspected — callers MUST NOT infer 'free'
#
# 'unknown' (no Get-NetTCPConnection, e.g. pwsh on a non-Windows host) degrades
# to the pre-check behaviour rather than falsely accusing a squatter.
function script:Get-CopilotPortOwner {
    param([Parameter(Mandatory)] [int] $Port)
    $free = [pscustomobject]@{ Owner = 'free'; Pids = @(); Labels = @() }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Owner = 'unknown'; Pids = @(); Labels = @() }
    }
    $listenPids = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ }
    )
    if (-not $listenPids) { return $free }
    $labels = @()
    foreach ($procId in $listenPids) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine -like '*copilot-throttle-shim.js*') { continue }
        $name = if ($proc) { $proc.Name } else { 'unknown' }
        $labels += "$procId($name)"
    }
    [pscustomobject]@{
        Owner  = if ($labels.Count -gt 0) { 'foreign' } else { 'ours' }
        Pids   = $listenPids
        Labels = $labels
    }
}

# Managed clients must not silently bypass an enabled shim. Mirrors the Unix
# `_copilot_require_shim`.
#
# Test-CopilotShimAlive accepts only this shim's /_shim/health identity endpoint.
# Start-CopilotShim additionally owns the process/port check and is idempotent.
function script:Assert-CopilotShim {
    if (-not (Get-CopilotShimEnabled)) { return $true }
    if (Start-CopilotShim) { return $true }
    Write-Error 'copilot-proxy: managed client refused to bypass the enabled metrics shim.'
    Write-Error "  use 'copilot-proxy shim off' only for an intentional direct-mode escape."
    $false
}

# Resolve the model: $COPILOT_CLAUDE_MODEL > state file > default.
#
#   - HYPHENATED ids (claude-opus-4-8), not dotted (claude-opus-4.8): Claude Code
#     only recognizes hyphenated family names — dotted ids fall back to a legacy
#     "[Opus 4] retired" label AND a 200k context assumption.
#   - "[1m]" suffix: Claude Code uses it to size HUD/compaction for a 1M context
#     window. ConvertTo-CopilotClaudeModel derives it from live /v1/models metadata
#     for every provider. Claude Code-only: raw API clients use the plain id.
function script:Get-CopilotDefaultModel {
    if ($env:COPILOT_CLAUDE_MODEL) { return $env:COPILOT_CLAUDE_MODEL }
    $sf = Get-CopilotModelState
    if (Test-Path $sf) { return (Get-Content -First 1 $sf) }
    'gpt-5.6-sol[1m]'
}

# Every model id the proxy accepts: .id plus the .claude_model_id alias. Callers
# with several catalog views pass one snapshot so all decisions share one response.
function script:Get-CopilotServedModels {
    param($Catalog)
    if (-not $PSBoundParameters.ContainsKey('Catalog')) { $Catalog = Get-CopilotModelCatalog }
    if (-not $Catalog) { return @() }
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $Catalog.data) {
        if ($m.id) { $ids.Add([string]$m.id) }
        if ($m.claude_model_id) { $ids.Add([string]$m.claude_model_id) }
    }
    $ids | Sort-Object -Unique
}

# The full live catalog is the source of truth for raw ids, Claude aliases and
# context limits. Callers that need several views fetch it once and pass it on.
function script:Get-CopilotModelCatalog {
    try { Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/models" -TimeoutSec 5 -ErrorAction Stop }
    catch { $null }
}

function script:Get-CopilotCatalogIds {
    param($Catalog)
    if (-not $Catalog) { return @() }
    @($Catalog.data | ForEach-Object { $_.id } | Where-Object { $_ } | Sort-Object -Unique)
}

# Automatic selection must respect Copilot's catalog policy without hiding raw ids
# from diagnostics or explicit/manual selection. Missing policy metadata is allowed,
# matching the gateway and the previous Codex-only filter.
function script:Get-CopilotSelectableModelIds {
    param($Catalog)
    if (-not $Catalog) { return @() }
    @($Catalog.data | Where-Object {
        $_ -and ($_.policy.state -ne 'disabled') -and
        ($_.model_picker_enabled -ne $false) -and
        ($_.capabilities.type -ne 'embeddings')
    } | ForEach-Object { $_.id } | Where-Object { $_ } | Sort-Object -Unique)
}

function script:Remove-CopilotContextHint {
    param([string] $Model)
    $Model -replace '\[1m\]$', ''
}

# Claude Code uses [1m] only for its full-context/HUD classification. Its
# process-wide auto-compact capacity must instead follow the provider's real
# prompt ceiling, otherwise the default ~95% trigger can occur after Copilot's
# input limit. Returns $null when metadata is unavailable; throws when the known
# ceiling is below Claude Code's configurable 100k minimum.
function script:Get-CopilotClaudeCompactWindow {
    param([Parameter(Mandatory)] [string] $Model, $Catalog)
    if (-not $PSBoundParameters.ContainsKey('Catalog')) { $Catalog = Get-CopilotModelCatalog }
    if (-not $Catalog) { return $null }
    $raw = Remove-CopilotContextHint $Model
    $entry = $Catalog.data | Where-Object { $_.id -eq $raw } | Select-Object -First 1
    if (-not $entry) { return $null }

    $prompt = 0L
    $context = 0L
    $output = 0L
    $hasPrompt = [long]::TryParse([string]$entry.capabilities.limits.max_prompt_tokens, [ref]$prompt)
    $hasContext = [long]::TryParse([string]$entry.capabilities.limits.max_context_window_tokens, [ref]$context)
    $hasOutput = [long]::TryParse([string]$entry.capabilities.limits.max_output_tokens, [ref]$output)
    $window = if ($hasPrompt -and $prompt -gt 0) { $prompt }
              elseif ($hasContext -and $hasOutput -and $context -gt $output) { $context - $output }
              else { 0L }
    if ($window -le 0) { return $null }
    if ($window -lt 100000) {
        throw "$raw has a prompt ceiling below Claude Code's 100000-token minimum"
    }
    if ($window -gt 1000000) { return 1000000L }
    $window
}

# Pick exactly one live inference target. The configured main wins when its raw id
# is advertised; only the automatic catalog fallback is eligibility-filtered.
function script:Resolve-CopilotDoctorTarget {
    param([string] $ConfiguredMain, [string[]] $RawModel, [string[]] $SelectableModel)
    $RawModel = @($RawModel | Where-Object { $_ -and $_ -notmatch 'embedding' } | Sort-Object -Unique)
    if (-not $PSBoundParameters.ContainsKey('SelectableModel')) { $SelectableModel = $RawModel }
    $SelectableModel = @($SelectableModel | Where-Object { $_ -and $_ -notmatch 'embedding' } | Sort-Object -Unique)
    $rawConfigured = Remove-CopilotContextHint $ConfiguredMain
    if (-not $rawConfigured) {
        return [pscustomobject]@{
            Model  = $null
            Label  = 'MissingConfiguredMain'
            Reason = 'the active project proxy pin has no ANTHROPIC_MODEL'
        }
    }
    if ($RawModel -contains $rawConfigured) {
        return [pscustomobject]@{
            Model  = $rawConfigured
            Label  = 'ConfiguredMain'
            Reason = 'configured main is advertised by the live catalog'
        }
    }

    $fallback = Select-CopilotBestModel -Model $SelectableModel
    [pscustomobject]@{
        Model  = $fallback
        Label  = 'CatalogFallback'
        Reason = "configured main '$rawConfigured' is not advertised by the live catalog"
    }
}

function script:ConvertTo-CopilotCompactText {
    param($Value, [int] $MaxLength = 320)
    $text = if ($Value -is [string]) { $Value } else {
        try { $Value | ConvertTo-Json -Depth 12 -Compress -ErrorAction Stop } catch { [string]$Value }
    }
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $MaxLength) { return $text.Substring(0, $MaxLength - 3) + '...' }
    $text
}

# Error bodies appear as direct code/message pairs, error.code/error.message, or
# another JSON error encoded inside error.message. Normalize all three shapes.
function script:Get-CopilotApiError {
    param($Body, [int] $Depth = 0)
    $raw = ConvertTo-CopilotCompactText $Body
    if ($Depth -gt 4) {
        return [pscustomobject]@{ Code = $null; Message = $null; Raw = $raw }
    }

    $object = $Body
    if ($Body -is [string]) {
        try { $object = $Body | ConvertFrom-Json -ErrorAction Stop }
        catch { return [pscustomobject]@{ Code = $null; Message = $null; Raw = $raw } }
    }
    if (-not $object) { return [pscustomobject]@{ Code = $null; Message = $null; Raw = $raw } }

    $container = $object
    if ($object.PSObject.Properties['error']) {
        $container = $object.error
        if ($container -is [string]) {
            $nestedError = Get-CopilotApiError -Body $container -Depth ($Depth + 1)
            if ($nestedError.Code -or $nestedError.Message) { return $nestedError }
        }
    }

    $code = if ($container.PSObject.Properties['code']) { [string]$container.code } else { $null }
    $message = if ($container.PSObject.Properties['message']) { [string]$container.message } else { $null }
    if ($message -and $message.TrimStart().StartsWith('{')) {
        $nestedMessage = Get-CopilotApiError -Body $message -Depth ($Depth + 1)
        if ($nestedMessage.Code -or $nestedMessage.Message) {
            return [pscustomobject]@{
                Code    = if ($nestedMessage.Code) { $nestedMessage.Code } else { $code }
                Message = if ($nestedMessage.Message) { $nestedMessage.Message } else { $message }
                Raw     = $raw
            }
        }
    }
    [pscustomobject]@{ Code = $code; Message = $message; Raw = $raw }
}

function script:Classify-CopilotInferenceError {
    param([int] $StatusCode, $Body)
    $errorInfo = Get-CopilotApiError -Body $Body
    $code = ([string]$errorInfo.Code).ToLowerInvariant()
    $detailParts = @($errorInfo.Code, $errorInfo.Message) | Where-Object { $_ }
    $detail = $detailParts -join ': '
    if (-not $detail) { $detail = $errorInfo.Raw }

    if ($StatusCode -eq 402 -and $code -eq 'billing_not_configured') {
        return [pscustomobject]@{
            Kind        = 'BillingNotConfigured'
            Code        = $errorInfo.Code
            Message     = $errorInfo.Message
            Summary     = "account-wide GitHub Copilot billing is not configured: $detail"
            Retryable   = $false
            AccountWide = $true
            Action      = 'https://github.com/settings/copilot/features'
            Guidance    = 'Select an organization or enterprise in GitHub''s "Usage billed to" setting. Changing the model, using --auto, or enabling the shim cannot fix this account-wide failure.'
        }
    }

    if ($code -match '^(model_not_supported|model_unsupported|unsupported_model)$') {
        return [pscustomobject]@{
            Kind        = 'ModelUnsupported'
            Code        = $errorInfo.Code
            Message     = $errorInfo.Message
            Summary     = $detail
            Retryable   = $false
            AccountWide = $false
            Action      = 'Run copilot-model --auto, or copilot-model -l and select a model advertised by the live catalog.'
            Guidance    = $null
        }
    }

    [pscustomobject]@{
        Kind        = 'HttpError'
        Code        = $errorInfo.Code
        Message     = $errorInfo.Message
        Summary     = $detail
        Retryable   = ($StatusCode -eq 429 -or $StatusCode -ge 500)
        AccountWide = $false
        Action      = $null
        Guidance    = $null
    }
}

# Convert a raw proxy id to the spelling Claude Code should receive. A live
# max_context_window_tokens >= 1M earns [1m]. Offline, preserve an explicitly
# stored suffix but do not invent one.
function script:ConvertTo-CopilotClaudeModel {
    param([Parameter(Mandatory)] [string] $Model, $Catalog)
    $hadHint = $Model -match '\[1m\]$'
    $raw = Remove-CopilotContextHint $Model
    if (-not $PSBoundParameters.ContainsKey('Catalog')) { $Catalog = Get-CopilotModelCatalog }
    if ($Catalog) {
        $entry = $Catalog.data | Where-Object { $_.id -eq $raw } | Select-Object -First 1
        $context = $entry.capabilities.limits.max_context_window_tokens
        if ($context -and [long]$context -ge 1000000) { return "$raw[1m]" }
        return $raw
    }
    if ($hadHint) { return "$raw[1m]" }
    $raw
}

function script:Select-CopilotFirstServed {
    param([string[]] $Model, [string[]] $Candidate)
    foreach ($c in $Candidate) { if ($Model -contains $c) { return $c } }
    $null
}

# Build the complete Claude Code role profile for a selected main model. Native
# Claude profiles use the strongest served model in each family. OpenAI profiles
# map quality/balanced/fast work to the selected main, Terra and Luna.
function script:Get-CopilotModelProfile {
    param([string] $Model = (Get-CopilotDefaultModel), $Catalog)
    if (-not $PSBoundParameters.ContainsKey('Catalog')) { $Catalog = Get-CopilotModelCatalog }
    # The selected main may be an explicit override; only automatically derived
    # alternative roles are constrained by the selectable catalog policy.
    $models = Get-CopilotSelectableModelIds $Catalog
    $raw = Remove-CopilotContextHint $Model
    $main = ConvertTo-CopilotClaudeModel -Model $Model -Catalog $Catalog

    $fableRaw = $raw; $opusRaw = $raw; $sonnetRaw = $raw; $haikuRaw = $raw
    if ($raw -like 'claude-*') {
        $fableRaw = Select-CopilotFirstServed -Model $models -Candidate @('claude-fable-5')
        if (-not $fableRaw) { $fableRaw = @($models | Where-Object { $_ -like 'claude-fable-*' } | Sort-Object)[-1] }
        if (-not $fableRaw) { $fableRaw = $raw }

        $opusRaw = Select-CopilotFirstServed -Model $models -Candidate @(
            'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6', 'claude-opus-4-5'
        )
        if (-not $opusRaw) { $opusRaw = @($models | Where-Object { $_ -like 'claude-opus-*' } | Sort-Object)[-1] }
        if (-not $opusRaw) { $opusRaw = $raw }

        $sonnetRaw = Select-CopilotFirstServed -Model $models -Candidate @(
            'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5'
        )
        if (-not $sonnetRaw) { $sonnetRaw = @($models | Where-Object { $_ -like 'claude-sonnet-*' } | Sort-Object)[-1] }
        if (-not $sonnetRaw) { $sonnetRaw = $raw }

        $haikuRaw = Select-CopilotFirstServed -Model $models -Candidate @('claude-haiku-4-5')
        if (-not $haikuRaw) { $haikuRaw = @($models | Where-Object { $_ -like 'claude-haiku-*' } | Sort-Object)[-1] }
        if (-not $haikuRaw) { $haikuRaw = $raw }
    }
    elseif ($raw -like 'gpt-*' -or $raw -match 'codex') {
        $sonnetRaw = Select-CopilotFirstServed -Model $models -Candidate @('gpt-5.6-terra')
        if (-not $sonnetRaw) { $sonnetRaw = $raw }
        $haikuRaw = Select-CopilotFirstServed -Model $models -Candidate @('gpt-5.6-luna', 'gpt-5.4-mini', 'gpt-5-mini')
        if (-not $haikuRaw) { $haikuRaw = $raw }
    }

    [ordered]@{
        main   = $main
        fable  = ConvertTo-CopilotClaudeModel -Model $fableRaw -Catalog $Catalog
        opus   = ConvertTo-CopilotClaudeModel -Model $opusRaw -Catalog $Catalog
        sonnet = ConvertTo-CopilotClaudeModel -Model $sonnetRaw -Catalog $Catalog
        haiku  = ConvertTo-CopilotClaudeModel -Model $haikuRaw -Catalog $Catalog
    }
}

function script:Write-CopilotModelProfile {
    param([System.Collections.IDictionary] $ModelProfile)
    Write-Host ("  main   : {0}" -f $ModelProfile.main)
    Write-Host ("  fable  : {0}" -f $ModelProfile.fable)
    Write-Host ("  opus   : {0}" -f $ModelProfile.opus)
    Write-Host ("  sonnet : {0}" -f $ModelProfile.sonnet)
    Write-Host ("  haiku  : {0}" -f $ModelProfile.haiku)
}

# "<model>|<source>" — the model Claude Code would send from this directory.
function script:Get-CopilotEffectiveModel {
    param([string] $Settings = '.claude/settings.local.json')
    $settings = $Settings
    if (Test-Path $settings) {
        try {
            $j = Get-Content -Raw $settings | ConvertFrom-Json
            if ($j.env.ANTHROPIC_BASE_URL) {
                $m = $j.env.ANTHROPIC_MODEL
                if ($m) { return "$m|project pin: $settings" }
                return "|project pin missing ANTHROPIC_MODEL: $settings"
            }
        } catch { $null = $_ }
    }
    if ($env:COPILOT_CLAUDE_MODEL) { return "$($env:COPILOT_CLAUDE_MODEL)|`$COPILOT_CLAUDE_MODEL" }
    $sf = Get-CopilotModelState
    if (Test-Path $sf) { return "$(Get-Content -First 1 $sf)|state file: $sf" }
    "$(Get-CopilotDefaultModel)|built-in default"
}

# The EXACT env block `copilot-here on` / `copilot-run` would apply right now.
#
# SINGLE SOURCE OF TRUTH for three callers: copilot-run (process env),
# `copilot-here on` (what it merges into settings.local.json) and
# Get-CopilotHereDrift (what it compares against). These used to be hand-maintained
# copies and they diverged — the drift check compared 4 of the 8 keys `on` writes,
# so a pin missing ANTHROPIC_DEFAULT_HAIKU_MODEL / ANTHROPIC_SMALL_FAST_MODEL /
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC reported "no drift" while `on` would
# still have changed it. Add a key here and all three follow.
#
# -Pinned uses the shim base when the shim is enabled but not yet up (what a
# written-to-disk pin should say); copilot-run wants the live base instead.
function script:Get-CopilotEnvBlock {
    param([switch] $Pinned, [string] $Model = (Get-CopilotDefaultModel), $Catalog)
    if (-not $PSBoundParameters.ContainsKey('Catalog')) { $Catalog = Get-CopilotModelCatalog }
    $modelProfile = Get-CopilotModelProfile -Model $Model -Catalog $Catalog
    $compactWindow = Get-CopilotClaudeCompactWindow -Model $Model -Catalog $Catalog
    $block = [ordered]@{
        ANTHROPIC_BASE_URL             = if ($Pinned) { Get-CopilotPinnedBase } else { Get-CopilotClientBase }
        ANTHROPIC_AUTH_TOKEN           = 'dummy'
        ANTHROPIC_MODEL                = $modelProfile.main
        ANTHROPIC_DEFAULT_FABLE_MODEL  = $modelProfile.fable
        ANTHROPIC_DEFAULT_OPUS_MODEL   = $modelProfile.opus
        ANTHROPIC_DEFAULT_SONNET_MODEL = $modelProfile.sonnet
        ANTHROPIC_DEFAULT_HAIKU_MODEL  = $modelProfile.haiku
        ANTHROPIC_SMALL_FAST_MODEL     = $modelProfile.haiku
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    }
    if ($null -ne $compactWindow) {
        $block.CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string]$compactWindow
    } else {
        Write-Warning "copilot-proxy: compact ceiling unavailable for $(Remove-CopilotContextHint $Model); Claude Code will use its built-in assumption"
    }
    if ($env:COPILOT_PROXY_QUIET -eq '1') {
        $block.CLAUDE_CODE_ATTRIBUTION_HEADER = '0'
        $block.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'
        $block.CLAUDE_CODE_ENABLE_AWAY_SUMMARY = '0'
        $block.DISABLE_NON_ESSENTIAL_MODEL_CALLS = '1'
    }
    $block
}

function script:Write-CopilotLifecycleEvent {
    param(
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [string] $EventName,
        [int] $ProcessId,
        [int] $Port,
        [string] $Detail
    )
    $metadata = Get-CopilotPkgMetadata
    $row = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString('o')
        component = $Component
        event = $EventName
        pid = if ($ProcessId) { $ProcessId } else { $null }
        port = if ($Port) { $Port } else { $null }
        package = if ($metadata) { [string]$metadata.Name } else { [string](Get-CopilotPkgName) }
        version = if ($metadata) { [string]$metadata.Version } else { $null }
        detail = $Detail
    }
    $path = Get-CopilotLifecycleLog
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [System.IO.File]::AppendAllText($path, (($row | ConvertTo-Json -Compress) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function script:Start-CopilotProcessWatcher {
    param(
        [Parameter(Mandatory)] $Process,
        [Parameter(Mandatory)] [ValidateSet('proxy', 'shim')] [string] $Component,
        [Parameter(Mandatory)] [int] $Port,
        [int] $RecoveryAttempt = 0,
        [DateTime] $StartedAt = [DateTime]::UtcNow
    )
    $watchScript = Get-CopilotProcessWatchScript
    if (-not (Test-Path -LiteralPath $watchScript -PathType Leaf)) {
        Write-CopilotLifecycleEvent -Component $Component -EventName 'watch_unavailable' -ProcessId $Process.Id -Port $Port -Detail $watchScript
        return
    }
    $metadata = Get-CopilotPkgMetadata
    $watchEnv = @{
        COPILOT_WATCH_SCRIPT = $watchScript
        COPILOT_WATCH_PID = [string]$Process.Id
        COPILOT_WATCH_COMPONENT = $Component
        COPILOT_WATCH_LOG = Get-CopilotLifecycleLog
        COPILOT_WATCH_INTENT = Get-CopilotStopIntent -Component $Component -ProcessId $Process.Id
        COPILOT_WATCH_READY = Get-CopilotReadyMarker -Component $Component -ProcessId $Process.Id
        COPILOT_WATCH_PACKAGE = if ($metadata) { [string]$metadata.Name } else { '' }
        COPILOT_WATCH_VERSION = if ($metadata) { [string]$metadata.Version } else { '' }
        COPILOT_WATCH_PORT = [string]$Port
        COPILOT_WATCH_MODULE = Get-CopilotModuleManifest
        COPILOT_WATCH_PROXY_HEALTH = "$(Get-CopilotBase)/v1/models"
        COPILOT_WATCH_SHIM_HEALTH = "$(Get-CopilotShimBase)/_shim/health"
        COPILOT_WATCH_SHIM_STATE = Get-CopilotShimState
        COPILOT_WATCH_STARTED = $StartedAt.ToUniversalTime().ToString('o')
        COPILOT_WATCH_RECOVERY = [string]$RecoveryAttempt
    }
    Remove-Item -LiteralPath $watchEnv.COPILOT_WATCH_INTENT, $watchEnv.COPILOT_WATCH_READY -Force -ErrorAction SilentlyContinue
    $saved = @{}
    foreach ($key in $watchEnv.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
    $command = '& $env:COPILOT_WATCH_SCRIPT -ProcessId ([int]$env:COPILOT_WATCH_PID) -Component $env:COPILOT_WATCH_COMPONENT -LogPath $env:COPILOT_WATCH_LOG -IntentPath $env:COPILOT_WATCH_INTENT -ReadyPath $env:COPILOT_WATCH_READY -Package $env:COPILOT_WATCH_PACKAGE -Version $env:COPILOT_WATCH_VERSION -Port ([int]$env:COPILOT_WATCH_PORT) -ModulePath $env:COPILOT_WATCH_MODULE -ProxyHealthUri $env:COPILOT_WATCH_PROXY_HEALTH -ShimHealthUri $env:COPILOT_WATCH_SHIM_HEALTH -ShimStatePath $env:COPILOT_WATCH_SHIM_STATE -StartedAt $env:COPILOT_WATCH_STARTED -RecoveryAttempt ([int]$env:COPILOT_WATCH_RECOVERY)'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    try {
        foreach ($key in $watchEnv.Keys) { Set-Item "env:$key" $watchEnv[$key] }
        Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WindowStyle Hidden | Out-Null
    } finally {
        foreach ($key in $watchEnv.Keys) {
            if ($null -eq $saved[$key]) { Remove-Item "env:$key" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$key" $saved[$key] }
        }
    }
}

function script:Set-CopilotStopIntent {
    param([Parameter(Mandatory)] [string] $Component, [Parameter(Mandatory)] [int] $ProcessId)
    $path = Get-CopilotStopIntent -Component $Component -ProcessId $ProcessId
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [System.IO.File]::WriteAllText($path, [DateTime]::UtcNow.ToString('o'), [System.Text.UTF8Encoding]::new($false))
}

function script:Set-CopilotProcessReady {
    param([Parameter(Mandatory)] [string] $Component, [Parameter(Mandatory)] [int] $ProcessId)
    $path = Get-CopilotReadyMarker -Component $Component -ProcessId $ProcessId
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [System.IO.File]::WriteAllText($path, [DateTime]::UtcNow.ToString('o'), [System.Text.UTF8Encoding]::new($false))
}

# --- shim start/stop ---
# Start the shim (idempotent). Points it at the proxy; scopes COPILOT_SHIM_* to
# the child.
#
# The port inspection remains load-bearing even though /_shim/health proves
# protocol identity: it names foreign listeners and lets us reclaim only a stale
# process whose command line is copilot-throttle-shim.js.
#
#   * a FOREIGN listener would otherwise pass as a healthy shim and silently
#     become the gateway every managed client talks to;
#   * one of OUR shims that is stale or too old to answer would otherwise be
#     read as "port free", and the spawn below dies instantly with EADDRINUSE —
#     leaving every managed client failing closed against a shim that is in fact
#     running. That wedge is unrecoverable by retrying.
#
# See pitfalls/copilot-proxy-shim-port-held-by-another-process.md
function script:Invoke-CopilotShimStart {
    param([int] $RecoveryAttempt = 0)
    $port = [int] (Get-CopilotShimPort)
    $holder = Get-CopilotPortOwner -Port $port
    if ($holder.Owner -eq 'foreign') {
        Write-Error "copilot-proxy: port $port is held by another process: $($holder.Labels -join ' ')"
        Write-Error '  free it, or pick a different port with COPILOT_SHIM_PORT.'
        return $false
    }
    if (Test-CopilotShimAlive) { return $true }
    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        Write-Error "copilot-proxy: shim needs 'bun' (scoop install bun)"; return $false
    }
    $script = Get-CopilotShimScript
    if (-not (Test-Path $script)) { Write-Error "copilot-proxy: shim script not found at $script"; return $false }
    if ($holder.Owner -eq 'ours') {
        foreach ($procId in $holder.Pids) {
            Set-CopilotStopIntent -Component shim -ProcessId $procId
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
        # Give the reclaimed listener a moment to release the socket.
        for ($w = 0; $w -lt 5; $w++) {
            if ((Get-CopilotPortOwner -Port $port).Owner -eq 'free') { break }
            Start-Sleep 1
        }
    }
    Rotate-CopilotLog -Path (Get-CopilotShimLog)
    Rotate-CopilotLog -Path "$(Get-CopilotShimLog).err"
    # `$env:X = ...` is PROCESS-wide in PowerShell, not scoped to the function,
    # so assigning these used to leak into the caller's session for good — and
    # every later `bun copilot-throttle-shim.js` inherited them. Set, spawn,
    # restore (the same idiom copilot-run uses for the ANTHROPIC_* block).
    $shimEnv = @{
        COPILOT_SHIM_PORT = "$port"
        COPILOT_SHIM_UPSTREAM = Get-CopilotBase
        COPILOT_SHIM_METRICS_DB = Get-CopilotShimMetricsDb
        COPILOT_API_SQLITE_DB_PATH = Get-CopilotTokenUsageDb
    }
    $saved = @{}
    foreach ($k in $shimEnv.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    $startedAt = [DateTime]::UtcNow
    try {
        foreach ($k in $shimEnv.Keys) { Set-Item "env:$k" $shimEnv[$k] }
        # Start-Process flattens ArgumentList into one command line. Windows paths
        # cannot contain quotes, so wrapping is sufficient to preserve spaces.
        $scriptArgument = if ($script -match '\s') { "`"$script`"" } else { $script }
        $p = Start-Process -FilePath 'bun' -ArgumentList @($scriptArgument) -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Get-CopilotShimLog) -RedirectStandardError "$(Get-CopilotShimLog).err"
    } finally {
        foreach ($k in $shimEnv.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$k" $saved[$k] }
        }
    }
    $p.Id | Set-Content -Path (Get-CopilotShimPid)
    Write-CopilotLifecycleEvent -Component shim -EventName spawned -ProcessId $p.Id -Port $port
    Start-CopilotProcessWatcher -Process $p -Component shim -Port $port -RecoveryAttempt $RecoveryAttempt -StartedAt $startedAt
    for ($i = 0; $i -lt 10; $i++) {
        if (Test-CopilotShimAlive) {
            Set-CopilotProcessReady -Component shim -ProcessId $p.Id
            Write-CopilotLifecycleEvent -Component shim -EventName ready -ProcessId $p.Id -Port $port
            return $true
        }
        Start-Sleep 1
    }
    Write-CopilotLifecycleEvent -Component shim -EventName start_failed -ProcessId $p.Id -Port $port -Detail 'health timeout'
    Write-Error "copilot-proxy: shim did not come up — check $(Get-CopilotShimLog)"
    # Surface the reason inline; Start-Process detaches, so EADDRINUSE and friends
    # otherwise land only in a file nobody opens.
    foreach ($logPath in @((Get-CopilotShimLog), "$(Get-CopilotShimLog).err")) {
        if (Test-Path $logPath) { Get-Content -Tail 5 $logPath | ForEach-Object { Write-Host "  $_" } }
    }
    if ($p -and -not $p.HasExited) {
        Set-CopilotStopIntent -Component shim -ProcessId $p.Id
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Get-CopilotShimPid) -Force -ErrorAction SilentlyContinue
    $false
}

function script:Start-CopilotShim {
    param([int] $RecoveryAttempt = 0)
    $port = [int](Get-CopilotShimPort)
    $mutex = [System.Threading.Mutex]::new($false, "Local\copilot-proxy-shim-$port")
    $locked = $false
    try {
        $timeout = if ($env:COPILOT_SHIM_LOCK_TIMEOUT_MS) { [int]$env:COPILOT_SHIM_LOCK_TIMEOUT_MS } else { 30000 }
        try { $locked = $mutex.WaitOne([Math]::Max(0, $timeout)) }
        catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) {
            Write-Error "copilot-proxy: timed out waiting for the port $port shim start lock"
            return $false
        }
        return Invoke-CopilotShimStart -RecoveryAttempt $RecoveryAttempt
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { $null = $_ } }
        $mutex.Dispose()
    }
}

function script:Stop-CopilotShim {
    $port = [int](Get-CopilotShimPort)
    $pidf = Get-CopilotShimPid
    $targets = [System.Collections.Generic.HashSet[int]]::new()
    if (Test-Path $pidf) {
        $pid_ = Get-Content -First 1 $pidf -ErrorAction SilentlyContinue
        if ($pid_) { $null = $targets.Add([int]$pid_) }
        Remove-Item $pidf -ErrorAction SilentlyContinue
    }
    $holder = Get-CopilotPortOwner -Port $port
    if ($holder.Owner -eq 'ours') {
        foreach ($procId in $holder.Pids) { $null = $targets.Add([int]$procId) }
    }
    foreach ($procId in $targets) {
        Set-CopilotStopIntent -Component shim -ProcessId $procId
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}

function script:Invoke-CopilotShimCli {
    param([Parameter(Mandatory)] [ValidateSet('stats', 'events', 'bench')] [string] $Command,
          [string[]] $Argument = @())
    $scriptPath = Get-CopilotShimScript
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Error "copilot-proxy: shim script not found at $scriptPath"
        return
    }
    $shimEnv = @{
        COPILOT_SHIM_PORT = Get-CopilotShimPort
        COPILOT_SHIM_METRICS_DB = Get-CopilotShimMetricsDb
        COPILOT_API_SQLITE_DB_PATH = Get-CopilotTokenUsageDb
    }
    $saved = @{}
    foreach ($key in $shimEnv.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
    try {
        foreach ($key in $shimEnv.Keys) { Set-Item "env:$key" $shimEnv[$key] }
        & bun $scriptPath $Command @Argument
        if ($LASTEXITCODE -ne 0) { Write-Error "copilot-proxy: shim $Command failed with exit code $LASTEXITCODE" }
    } finally {
        foreach ($key in $shimEnv.Keys) {
            if ($null -eq $saved[$key]) { Remove-Item "env:$key" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$key" $saved[$key] }
        }
    }
}

function script:Invoke-CopilotLimiter {
    param([string[]] $Argument = @())
    if (-not (Test-CopilotShimAlive)) {
        Write-Error "copilot-proxy: limiter requires the running shim; try 'copilot-proxy shim on'."
        return
    }
    $action = if ($Argument.Count -gt 0) { $Argument[0] } else { 'status' }
    $request = @{ Uri = "$(Get-CopilotShimBase)/_shim/config"; TimeoutSec = 3; ErrorAction = 'Stop' }
    switch ($action) {
        'status' { $request.Method = 'Get' }
        'reset' {
            $request.Method = 'Patch'
            $request.Headers = @{ 'x-copilot-shim-admin' = '1' }
            $request.ContentType = 'application/json'
            $request.Body = @{ reset = $true } | ConvertTo-Json -Compress
        }
        'set' {
            $patch = [ordered]@{}
            for ($i = 1; $i -lt $Argument.Count; $i += 2) {
                $name = $Argument[$i]
                if ($name -notin '--min', '--max', '--limit' -or $i + 1 -ge $Argument.Count) {
                    Write-Error "usage: copilot-proxy limiter set [--min N] [--max N] [--limit N]"
                    return
                }
                $value = 0
                if (-not [int]::TryParse($Argument[$i + 1], [ref]$value) -or $value -lt 1 -or $value -gt 32) {
                    Write-Error "copilot-proxy: limiter $name must be an integer from 1 to 32"
                    return
                }
                $patch[$name.Substring(2)] = $value
            }
            if ($patch.Count -eq 0) { Write-Error 'copilot-proxy: limiter set needs --min, --max, or --limit'; return }
            $request.Method = 'Patch'
            $request.Headers = @{ 'x-copilot-shim-admin' = '1' }
            $request.ContentType = 'application/json'
            $request.Body = $patch | ConvertTo-Json -Compress
        }
        default { Write-Error 'usage: copilot-proxy limiter [status|set --min N --max N --limit N|reset]'; return }
    }
    try {
        $result = Invoke-RestMethod @request
        $result | Select-Object limit, min, max, active, queued, adaptive, cooldown_ms_remaining, successes_to_increase, throttle_events, last_throttle_status, startup
        if ($action -ne 'status') {
            Write-Host 'copilot-proxy: live limiter updated for this shim process only; set COPILOT_SHIM_MIN/MAX before restart to persist.'
        }
    } catch { Write-Error "copilot-proxy: limiter request failed: $($_.Exception.Message)" }
}

# ============================================================ copilot-proxy ===
function copilot-proxy {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)

    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        Write-Error "copilot-proxy: bun not found (scoop install bun)"; return
    }

    $port = Get-CopilotPort; $pkg = Get-CopilotPkg
    $logf = Get-CopilotLogFile; $pidf = Get-CopilotPidFile
    $action = if ($Argv -and $Argv.Count -ge 1) { $Argv[0] } else { 'status' }

    switch ($action) {
        'start' {
            if (Test-CopilotAlive) { Write-Host "copilot-proxy: already running on port $port"; return }
            if (-not (Test-Path (Get-CopilotToken))) {
                Write-Error "copilot-proxy: not authenticated yet — run 'copilot-proxy auth' first."; return
            }
            # Rotate stdout and stderr independently (keep the last 3 sessions).
            Rotate-CopilotLog -Path $logf
            Rotate-CopilotLog -Path "$logf.err"
            # Install the pinned package BEFORE launching anything. Resolving it at
            # launch (the old `bunx <pkg> start`) is what used to hang forever behind
            # a socks proxy, with nothing but "Resolving dependencies" in the log.
            if (-not (Install-CopilotPkg)) { return }
            $launch = Get-CopilotPkgLaunch
            if (-not $launch) { Write-Error "copilot-proxy: no runnable copilot-api after install"; return }

            # Node ignores the Windows System Proxy — it only honours HTTP(S)_PROXY,
            # and the fork additionally needs --proxy-env before its fetch uses them.
            $httpProxy = Resolve-CopilotHttpProxy
            if ($httpProxy) {
                Write-Host "copilot-proxy: Node will fetch /models via $httpProxy (--proxy-env; COPILOT_HTTP_PROXY=$(if ($env:COPILOT_HTTP_PROXY) { $env:COPILOT_HTTP_PROXY } else { 'auto' }))"
            } elseif ($env:COPILOT_HTTP_PROXY -in 'always', 'on', '1', 'true', 'yes') {
                Write-Warning "copilot-proxy: COPILOT_HTTP_PROXY=always but no proxy detected — starting DIRECT (the Claude catalog may be geo-filtered)."
                Write-Host "  hint: enable the Clash/Verge System Proxy, or set COPILOT_HTTP_PROXY=http://127.0.0.1:7897"
            }

            $argList = @($launch.Pre + @('start', '--port', $port))
            if ((Get-CopilotPkgFlavor) -eq 'original') {
                $rate = if ($env:COPILOT_PROXY_RATE) { $env:COPILOT_PROXY_RATE } else { '15' }
                # Original package: HTTPS_PROXY alone is enough (it has no --proxy-env).
                $argList += @('--rate-limit', $rate, '--wait')
                Write-Host "copilot-proxy: starting ($pkg) on port $port (rate-limit ${rate}s) ..."
            } else {
                if ($httpProxy) { $argList += '--proxy-env' }
                Write-Host "copilot-proxy: starting ($pkg) on port $port ..."
            }

            # Scope the proxy env to the child: set, spawn, restore.
            $proxyVars = 'HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy'
            $saved = @{}
            if ($httpProxy) {
                foreach ($v in $proxyVars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); Set-Item "env:$v" $httpProxy }
            }
            $startedAt = [DateTime]::UtcNow
            try {
                $spArgs = @{
                    FilePath                = $launch.Exe
                    ArgumentList            = $argList
                    PassThru                = $true
                    WindowStyle             = 'Hidden'
                    RedirectStandardOutput  = $logf
                    RedirectStandardError   = "$logf.err"
                }
                if ($launch.Cwd) { $spArgs.WorkingDirectory = $launch.Cwd }
                $p = Start-Process @spArgs
            } finally {
                if ($httpProxy) {
                    foreach ($v in $proxyVars) {
                        if ($null -eq $saved[$v]) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
                        else { Set-Item "env:$v" $saved[$v] }
                    }
                }
            }
            $p.Id | Set-Content -Path $pidf
            Write-CopilotLifecycleEvent -Component proxy -EventName spawned -ProcessId $p.Id -Port ([int]$port)
            Start-CopilotProcessWatcher -Process $p -Component proxy -Port ([int]$port) -StartedAt $startedAt
            $startTimeout = if ($env:COPILOT_PROXY_START_TIMEOUT) { [int]$env:COPILOT_PROXY_START_TIMEOUT } else { 45 }
            for ($i = 0; $i -lt $startTimeout; $i++) {
                if (Test-CopilotAlive) {
                    if (Get-CopilotShimEnabled) {
                        if (Start-CopilotShim) { Write-Host "copilot-proxy: throttle shim up -> $(Get-CopilotShimBase) (-> $(Get-CopilotBase))" }
                    }
                    Set-CopilotProcessReady -Component proxy -ProcessId $p.Id
                    Write-CopilotLifecycleEvent -Component proxy -EventName ready -ProcessId $p.Id -Port ([int]$port)
                    Write-Host "copilot-proxy: up -> $(Get-CopilotClientBase)  (logs: copilot-proxy logs)"
                    return
                }
                # Crashed on its own (bad flag, port taken, auth) — don't sit out the
                # remaining seconds pretending we're still waiting.
                if ($p.HasExited) {
                    Remove-Item $pidf -ErrorAction SilentlyContinue
                    Write-CopilotLifecycleEvent -Component proxy -EventName start_failed -ProcessId $p.Id -Port ([int]$port) -Detail "exit code $($p.ExitCode)"
                    Write-Error "copilot-proxy: server exited during startup — check 'copilot-proxy logs'."; return
                }
                Start-Sleep 1
            }
            # Timed out. REAP what we spawned: the old code returned and left it
            # running, so each retry stacked another orphan and none ever bound the port.
            Write-CopilotLifecycleEvent -Component proxy -EventName start_failed -ProcessId $p.Id -Port ([int]$port) -Detail 'health timeout'
            Set-CopilotStopIntent -Component proxy -ProcessId $p.Id
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Remove-Item $pidf -ErrorAction SilentlyContinue
            Write-Error "copilot-proxy: did not come up in time — check 'copilot-proxy logs'."
        }
        'stop' {
            Stop-CopilotShim
            if (Test-Path $pidf) {
                $pid_ = Get-Content -First 1 $pidf -ErrorAction SilentlyContinue
                if ($pid_) {
                    Set-CopilotStopIntent -Component proxy -ProcessId ([int]$pid_)
                    Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
                }
                Remove-Item $pidf -ErrorAction SilentlyContinue
            }
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*copilot-api*--port $port*" } |
                ForEach-Object {
                    Set-CopilotStopIntent -Component proxy -ProcessId $_.ProcessId
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
            Start-Sleep 1
            if (Test-CopilotAlive) { Write-Error "copilot-proxy: still answering on $port (another instance?)"; return }
            Write-Host "copilot-proxy: stopped (port $port free)"
        }
        'restart' { copilot-proxy stop; copilot-proxy start }
        'status' {
            if (Test-CopilotAlive) {
                $catalog = Get-CopilotModelCatalog
                $rawIds = Get-CopilotCatalogIds $catalog
                $claude = @($rawIds | Where-Object { $_ -like 'claude-*' })
                $claudeText = if ($claude.Count -gt 0) { $claude -join ' ' } else { 'none' }
                Write-Host "copilot-proxy: RUNNING on $(Get-CopilotBase)"
                Write-Host "  models: $($rawIds.Count) served; Claude: $claudeText"
                if (Get-CopilotShimEnabled) {
                    if (Test-CopilotShimAlive) {
                        Write-Host "  shim:   ON, up on $(Get-CopilotShimBase)  -> clients use this"
                        $routing = Get-CopilotFastRouting
                        if ($routing) {
                            $mappingCount = @($routing.mappings.PSObject.Properties).Count
                            Write-Host "  fast:   $($routing.state), $mappingCount route(s) from the live catalog"
                        } else { Write-Host '  fast:   unavailable (restart the shim to refresh its routing endpoint)' }
                    }
                    else { Write-Host "  shim:   ON but DOWN (managed clients fail closed; break glass: copilot-proxy shim off)" }
                } else { Write-Host "  shim:   off  (enable: copilot-proxy shim on)" }
            } else {
                Write-Host "copilot-proxy: not running on port $port  (start: copilot-proxy start)"
            }
        }
        { $_ -in 'doctor', 'test' } { Invoke-CopilotDoctor -Live:($Argv -contains '--live') }
        'logs' {
            if ($Argv.Count -ge 2 -and $Argv[1] -eq 'lifecycle') {
                $lf = Get-CopilotLifecycleLog; $n = if ($Argv.Count -ge 3) { [int]$Argv[2] } else { 40 }
            } elseif ($Argv.Count -ge 2 -and $Argv[1] -eq 'shim') {
                if ($Argv.Count -ge 3 -and $Argv[2] -eq 'err') {
                    $lf = "$(Get-CopilotShimLog).err"; $n = if ($Argv.Count -ge 4) { [int]$Argv[3] } else { 40 }
                } else {
                    $lf = Get-CopilotShimLog; $n = if ($Argv.Count -ge 3) { [int]$Argv[2] } else { 40 }
                }
            } elseif ($Argv.Count -ge 2 -and $Argv[1] -eq 'err') {
                $lf = "$logf.err"; $n = if ($Argv.Count -ge 3) { [int]$Argv[2] } else { 40 }
            } else {
                $lf = $logf; $n = if ($Argv.Count -ge 2) { [int]$Argv[1] } else { 40 }
                if ($Argv.Count -ge 3 -and $Argv[2] -in '1', '2', '3') { $lf = "$logf.$($Argv[2])" }
            }
            if (Test-Path $lf) { Get-Content -Tail $n $lf }
            elseif (Test-Path "$lf.err") { Get-Content -Tail $n "$lf.err" }
            else { Write-Error "copilot-proxy: no log file at $lf" }
        }
        { $_ -in 'stats', 'events' } {
            Invoke-CopilotShimCli -Command $action -Argument @($Argv | Select-Object -Skip 1)
        }
        'limiter' { Invoke-CopilotLimiter -Argument @($Argv | Select-Object -Skip 1) }
        'bench' {
            if (-not (Test-CopilotAlive)) { Write-Error 'copilot-proxy: bench requires the proxy to be running.'; return }
            if (-not (Assert-CopilotShim)) { return }
            Invoke-CopilotShimCli -Command bench -Argument @($Argv | Select-Object -Skip 1)
        }
        'auth' {
            # One-time device login -> stores a ghu_ token copilot-api can exchange.
            Write-Host "copilot-proxy: launching copilot-api device login ..."
            $savedProxy = @{}
            foreach ($name in 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NODE_OPTIONS') {
                $savedProxy[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            try {
                $httpProxy = Resolve-CopilotHttpProxy
                foreach ($name in 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY') {
                    [Environment]::SetEnvironmentVariable($name, $httpProxy, 'Process')
                }
                if ($httpProxy) {
                    # NODE_OPTIONS treats backslashes as escapes inside quotes.
                    # Forward slashes work on Windows and preserve paths with spaces.
                    $preload = (Join-Path $PSScriptRoot 'auth-proxy.cjs').Replace('\', '/')
                    $env:NODE_OPTIONS = ($savedProxy['NODE_OPTIONS'] + ' --require "' + $preload + '"').Trim()
                }
                if ((Get-CopilotPkgFlavor) -eq 'original') { Invoke-CopilotPkgCommand auth }
                else { Invoke-CopilotPkgCommand auth login --provider copilot }
            } finally {
                foreach ($name in $savedProxy.Keys) {
                    if ($null -eq $savedProxy[$name]) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
                    else { [Environment]::SetEnvironmentVariable($name, $savedProxy[$name], 'Process') }
                }
            }
        }
        'update' {
            if ($Argv.Count -lt 2) { Write-Error 'usage: copilot-proxy update VERSION'; return }
            $null = Invoke-CopilotPkgUpdate -Version ([string]$Argv[1])
        }
        'rollback' { $null = Invoke-CopilotPkgRollback }
        'reinstall' {
            # Force a clean re-install of the pinned spec (normally only needed if the
            # prefix got corrupted — a version bump re-installs on its own via the stamp).
            Write-Host "copilot-proxy: removing $(Get-CopilotPkgPrefix) ..."
            Remove-Item -Recurse -Force (Get-CopilotPkgPrefix) -ErrorAction SilentlyContinue
            if (-not (Install-CopilotPkg)) { return }
            $installed = Get-CopilotPkgMetadata
            Write-Host "copilot-proxy: installed $($installed.Name)@$($installed.Version) (requested $(Get-CopilotPkg)) -> $(Get-CopilotPkgPrefix)"
        }
        { $_ -in 'whoami', 'usage', 'quota' } {
            if (-not (Test-Path (Get-CopilotToken))) { Write-Error "copilot-proxy: not authenticated — run 'copilot-proxy auth'."; return }
            if ((Get-CopilotPkgFlavor) -eq 'original') {
                Invoke-CopilotPkgCommand check-usage
            }
            elseif (Test-CopilotAlive) {
                try {
                    $u = Invoke-RestMethod -Uri "$(Get-CopilotBase)/usage" -TimeoutSec 5 -ErrorAction Stop
                    [pscustomobject]@{
                        plan        = if ($u.copilot_plan) { $u.copilot_plan } elseif ($u.access_type_sku) { $u.access_type_sku } else { 'unknown' }
                        quota_reset = $u.quota_reset_date
                        quotas      = $u.quota_snapshots
                    } | ConvertTo-Json -Depth 6
                } catch { Write-Error "copilot-proxy: /usage query failed: $_" }
            } else {
                Write-Host "copilot-proxy: not running — showing auth/debug info instead of quota."
                Invoke-CopilotPkgCommand debug
            }
        }
        'shim' {
            $sf = Get-CopilotShimState
            $sub = if ($Argv.Count -ge 2) { $Argv[1] } else { 'status' }
            switch ($sub) {
                'on' {
                    New-Item -ItemType Directory -Force -Path (Split-Path $sf) | Out-Null
                    'on' | Set-Content $sf
                    if (Test-CopilotAlive) { if (Start-CopilotShim) { Write-Host "copilot-proxy: shim ON -> $(Get-CopilotShimBase) (-> $(Get-CopilotBase))" } }
                    else { Write-Host "copilot-proxy: shim enabled; will start with the proxy." }
                    Write-Host "  NOTE: restart Claude Code so it picks up ANTHROPIC_BASE_URL=$(Get-CopilotShimBase)"
                }
                'off' {
                    'off' | Set-Content $sf; Stop-CopilotShim
                    Write-Host "copilot-proxy: shim OFF (clients use $(Get-CopilotBase) directly)"
                }
                'recover' {
                    $attempt = if ($Argv.Count -eq 4 -and $Argv[2] -eq '--attempt' -and $Argv[3] -match '^[1-3]$') { [int]$Argv[3] } else { 0 }
                    if ($attempt -eq 0) { Write-Error 'copilot-proxy: internal shim recovery requires --attempt 1, 2, or 3'; return }
                    if (-not (Get-CopilotShimEnabled)) { Write-Error 'copilot-proxy: shim recovery suppressed because the shim is off'; return }
                    if (-not (Test-CopilotAlive)) { Write-Error 'copilot-proxy: shim recovery suppressed because the proxy is down'; return }
                    if (-not (Start-CopilotShim -RecoveryAttempt $attempt)) { Write-Error "copilot-proxy: shim recovery attempt $attempt failed" }
                }
                default {
                    if (Get-CopilotShimEnabled) {
                        $st = if (Test-CopilotShimAlive) { 'up' } else { 'down' }
                        Write-Host "copilot-proxy: shim ON ($st) on $(Get-CopilotShimBase)"
                    } else { Write-Host "copilot-proxy: shim off" }
                }
            }
        }
        { $_ -in '-h', '--help', 'help' } {
            Write-Host "Usage: copilot-proxy [start|stop|restart|status|doctor [--live]|logs [err|shim [err]|lifecycle|N [gen]]|shim [on|off|status]|limiter [status|set|reset]|stats|events|quota|bench|update VERSION|rollback|whoami|auth|reinstall]"
            Write-Host "  doctor (alias: test)  diagnose prereqs, package, auth, proxy, Claude catalog, Codex Apps"
            Write-Host "                        (direct vs via proxy), upstream. --live costs 1 quota unit."
            Write-Host "  COPILOT_HTTP_PROXY    auto|always|never|http://127.0.0.1:PORT  (default auto)"
            Write-Host "                        auto attaches --proxy-env when a System/env proxy is found."
            Write-Host "  reinstall             wipe + re-install the pinned package (a version bump"
            Write-Host "                        re-installs on its own; this is for a corrupted prefix)."
        }
        default { Write-Error "copilot-proxy: unknown action '$action' (try --help)" }
    }
}

# ------------------------------------------------------------------ doctor ----
function script:Invoke-CopilotDoctor {
    param([switch] $Live)
    $port = Get-CopilotPort; $pkg = Get-CopilotPkg
    $fail = 0; $warn = 0
    function OK   ($n, $m) { Write-Host ("  " + [char]0x2713 + " {0,-16} {1}" -f $n, $m) -ForegroundColor Green }
    function BAD  ($n, $m) { Write-Host ("  " + [char]0x2717 + " {0,-16} {1}" -f $n, $m) -ForegroundColor Red; $script:fail++ }
    function NOTE ($n, $m) { Write-Host ("  ! {0,-16} {1}" -f $n, $m) -ForegroundColor Yellow; $script:warn++ }
    function SKIP ($n, $m) { Write-Host ("  " + [char]0x00B7 + " {0,-16} {1}" -f $n, $m) }
    function HINT ($m)     { Write-Host ("    {0,-16} -> {1}" -f '', $m) }
    $script:fail = 0; $script:warn = 0

    Write-Host "`ncopilot-proxy doctor   port $port   pkg $pkg`n"

    # This is the doctor's only /v1/models fetch. The same snapshot determines
    # liveness, raw ids, aliases, role checks and the optional live target.
    $catalog = Get-CopilotModelCatalog
    $proxyAlive = $null -ne $catalog

    Write-Host 'Prerequisites'
    foreach ($t in 'bun', 'node', 'uv') {
        $c = Get-Command $t -ErrorAction SilentlyContinue
        if ($c) { OK $t $c.Source } elseif ($t -eq 'uv') { NOTE $t 'not found — semsearch needs it' } else { BAD $t 'not found' }
    }

    Write-Host "`nPackage"
    # The proxy runs an INSTALLED binary, not `bunx <pkg>` — so a warm start does no
    # network at all. Report live metadata even when it disagrees with the selector.
    $installedMetadata = Get-CopilotPkgMetadata
    $installedStamp = Get-CopilotPkgStampMetadata
    $launch = Get-CopilotPkgLaunch
    if (Test-CopilotPkgReady) {
        OK 'installed' "$($installedMetadata.Name)@$($installedMetadata.Version) (requested $pkg)"
        $how = "$($launch.Exe) $($launch.Pre -join ' ')".Trim()
        if ($launch.Cwd) { $how += "   (cwd: $($launch.Cwd))" }
        SKIP 'runs via' $how
    } elseif ($installedMetadata) {
        NOTE 'installed' "$($installedMetadata.Name)@$($installedMetadata.Version) does not verify requested $pkg"
        $exactVersion = Get-CopilotPkgExactVersion
        if ($installedMetadata.Name -cne (Get-CopilotPkgName)) {
            HINT "metadata name mismatch: wanted $(Get-CopilotPkgName), found $($installedMetadata.Name)"
        } elseif ($exactVersion -and $installedMetadata.Version -cne $exactVersion) {
            HINT "metadata version mismatch: wanted $exactVersion, found $($installedMetadata.Version)"
        } elseif (-not $launch) {
            HINT 'metadata exists but no runnable launch path is available'
        } elseif (-not $installedStamp) {
            HINT 'verified JSON stamp is absent or corrupt'
        } else {
            HINT "stamp mismatch: requested=$($installedStamp.RequestedSpec), name=$($installedStamp.Name), version=$($installedStamp.Version)"
        }
        HINT 'copilot-proxy reinstall'
    } else {
        NOTE 'not installed' "$pkg — no readable installed package metadata; the next start installs it"
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($npm) {
            try {
                $registry = (& $npm.Source config get registry 2>$null | Select-Object -First 1).Trim()
                if ($registry) { SKIP 'npm registry' $registry }
            } catch { $null = $_ }
        }
        if (Get-CopilotPkgCdnManifest) { SKIP 'fallback' 'hash-pinned jsDelivr runtime files; dependencies use the npm registry above' }
        HINT 'copilot-proxy reinstall   # or force it now'
    }

    Write-Host "`nAuthentication"
    if (Test-Path (Get-CopilotToken)) { OK 'token file' (Get-CopilotToken) } else { BAD 'token file' 'absent'; HINT 'copilot-proxy auth' }

    Write-Host "`nProxy"
    if ($proxyAlive) { OK 'listening' (Get-CopilotBase) } else { BAD 'listening' "nothing on port $port"; HINT 'copilot-proxy start' }
    # A wedged package installer is the non-obvious reason a proxy never binds the
    # port: `start` just says "did not come up in time" and the log shows only
    # "Resolving dependencies". Hard failure when nothing is listening (that IS the
    # fault), softer when the proxy is up (a leftover still holding bun's cache lock,
    # which will hang the next restart).
    $stale = @(Get-CopilotStaleInstaller)
    if ($stale.Count -gt 0) {
        if ($proxyAlive) { NOTE 'stale installer' "$($stale.Count) leftover 'bun add … copilot-api' proc(s) — they hold bun's cache lock (a restart will hang)" }
        else { BAD 'stale installer' "$($stale.Count) wedged 'bun add … copilot-api' proc(s) — start is blocked at `"Resolving dependencies`", never binds port $port" }
        HINT "kill just those: Stop-Process -Id $($stale.ProcessId -join ',') -Force"
        HINT 'then: copilot-proxy reinstall'
        HINT 're-hangs? bun is stalling on the proxy — $env:COPILOT_INSTALL_NOPROXY=1; copilot-proxy reinstall'
    } else {
        SKIP 'installer' "no wedged 'bun add' process"
    }
    if (Get-CopilotShimEnabled) {
        if (Test-CopilotShimAlive) {
            OK 'throttle shim' "up on $(Get-CopilotShimBase)"
            $fastRouting = Get-CopilotFastRouting
            if ($fastRouting) {
                $mappingCount = @($fastRouting.mappings.PSObject.Properties).Count
                if ($fastRouting.state -in 'ready', 'stale' -and $mappingCount -gt 0) {
                    OK 'fast routing' "$($fastRouting.state), $mappingCount live-catalog route(s)"
                    HINT 'Codex: use /fast; Claude Code: claude-copilot --fast'
                } else {
                    NOTE 'fast routing' "$($fastRouting.state), no eligible sibling; Fast requests fall back to standard"
                }
            } else {
                BAD 'fast routing' 'routing endpoint unavailable; the running shim is stale or unhealthy'
                HINT 'copilot-proxy restart'
            }
        } else { BAD 'throttle shim' 'enabled but DOWN'; HINT 'copilot-proxy shim on' }
    } else { SKIP 'throttle shim' 'off' }

    Write-Host "`nModels"
    $httpProxy = Resolve-CopilotHttpProxy
    $proxyMode = if ($env:COPILOT_HTTP_PROXY) { $env:COPILOT_HTTP_PROXY } else { 'auto' }
    if ($httpProxy) { NOTE 'http proxy' "$httpProxy (COPILOT_HTTP_PROXY=$proxyMode) — Node needs --proxy-env to use this" }
    else { SKIP 'http proxy' "none detected (COPILOT_HTTP_PROXY=$proxyMode)" }

    # A/B: true-direct vs via the local proxy. GitHub geo-filters the Claude catalog
    # on some egress, and .NET/curl follow the System Proxy by default — so a single
    # "upstream" probe used to mis-label that as an entitlement problem.
    $dirClaude = 0; $viaClaude = 0; $anyUpstream = $false
    $upDirect = Get-CopilotUpstreamModel -Via 'direct'
    if ($upDirect) {
        $anyUpstream = $true
        $dirClaude = @($upDirect | Where-Object { $_ -match '^claude' }).Count
        OK 'upstream direct' "$($upDirect.Count) ids, $dirClaude claude (no proxy)"
    } else {
        SKIP 'upstream direct' 'could not query GitHub direct (need a token, or blocked)'
    }
    if ($httpProxy) {
        $upVia = Get-CopilotUpstreamModel -Via $httpProxy
        if ($upVia) {
            $anyUpstream = $true
            $viaClaude = @($upVia | Where-Object { $_ -match '^claude' }).Count
            OK 'upstream via proxy' "$($upVia.Count) ids, $viaClaude claude ($httpProxy)"
        } else {
            BAD 'upstream via proxy' "no response through $httpProxy"
            HINT 'the Clash/mihomo node may be down — try another selection'
        }
    }

    # The one local catalog snapshot drives raw ids, aliases, role checks and the
    # live target. Do not mix decisions from several /v1/models responses.
    $rawIds = Get-CopilotCatalogIds $catalog
    $selectableIds = Get-CopilotSelectableModelIds $catalog
    $served = @(Get-CopilotServedModels -Catalog $catalog)
    if ($served.Count -gt 0) {
        $claude = @($rawIds | Where-Object { $_ -match '^claude' })
        OK 'served catalog' "$($rawIds.Count) raw ids, $($served.Count) ids including Claude Code aliases"
        if ($claude.Count -gt 0) { OK 'claude catalog' "$($claude.Count) raw Claude ids advertised (inference not yet tested)" }
        else { NOTE 'claude catalog' "0 of $($rawIds.Count) raw ids — select an advertised non-Claude model explicitly" }

        if ($viaClaude -gt 0 -and $dirClaude -eq 0) {
            NOTE 'egress geo' 'Claude appears ONLY via the local proxy — GitHub filters Anthropic on direct egress'
            if ($claude.Count -eq 0) {
                BAD 'MISSING --proxy-env' 'copilot-api started without HTTPS_PROXY, so it cached the direct (no-Claude) catalog'
                HINT 'copilot-proxy restart   # auto attaches --proxy-env when a proxy is detected'
                HINT '$env:COPILOT_HTTP_PROXY = "http://127.0.0.1:7897"; copilot-proxy restart'
            }
        } elseif ($viaClaude -eq 0 -and $dirClaude -eq 0 -and $anyUpstream) {
            NOTE 'entitlement' 'neither direct nor via-proxy catalogs include Claude'
            HINT 'org Copilot policy may disable Anthropic — a restart will NOT help'
        } elseif ($claude.Count -eq 0 -and $viaClaude -gt 0) {
            BAD 'STALE CACHE' 'via-proxy upstream has Claude but the running process does not'
            HINT 'copilot-proxy restart'
        } elseif ($claude.Count -gt 0) {
            OK 'cache' 'the served Claude list looks healthy'
        }

        $pin = (Get-CopilotEffectiveModel) -split '\|', 2
        $model = $pin[0]; $src = $pin[1]
        if ($served -contains $model) { OK 'pinned model' "$model  ($src)" }
        else {
            BAD 'pinned model' "$model  ($src)"
            HINT 'not served -> requests return 400 model_not_supported'
            HINT 'copilot-model --auto   # Claude; else capability-ranked OpenAI, then Gemini'
            HINT 'copilot-model -l       # list served ids'
        }

        # Validate every alias Claude Code may select for background/subagent
        # work. A stale Sonnet/Haiku id can fail with 400 while main chat works.
        $settings = '.claude/settings.local.json'
        $modelProfile = $null
        if (Test-Path $settings) {
            try {
                $localEnv = (Get-Content -Raw $settings | ConvertFrom-Json).env
                if ($localEnv.ANTHROPIC_BASE_URL) {
                    $modelProfile = [ordered]@{
                        main   = $localEnv.ANTHROPIC_MODEL
                        fable  = $localEnv.ANTHROPIC_DEFAULT_FABLE_MODEL
                        opus   = $localEnv.ANTHROPIC_DEFAULT_OPUS_MODEL
                        sonnet = $localEnv.ANTHROPIC_DEFAULT_SONNET_MODEL
                        haiku  = $localEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL
                    }
                }
            } catch { $modelProfile = $null }
        }
        if (-not $modelProfile) {
            $modelProfile = Get-CopilotModelProfile -Model $model -Catalog $catalog
        }
        $roleBad = $false
        foreach ($role in 'fable', 'opus', 'sonnet', 'haiku') {
            $roleModel = $modelProfile[$role]
            if (-not $roleModel) {
                BAD "role $role" 'unset — Claude Code may choose its native default and get model_not_supported'
                $roleBad = $true
            }
            elseif ($served -notcontains $roleModel) {
                BAD "role $role" "$roleModel is not served"
                $roleBad = $true
            }
        }
        if (-not $roleBad) {
            OK 'model roles' "fable=$($modelProfile.fable), opus=$($modelProfile.opus), sonnet=$($modelProfile.sonnet), haiku=$($modelProfile.haiku)"
        } else {
            HINT 'copilot-model --auto   # rewrite main + every Claude Code role alias'
        }
    } else {
        BAD 'served' "could not fetch $(Get-CopilotBase)/v1/models"
        if ($viaClaude -gt 0) { HINT 'start with the proxy: copilot-proxy start   # attaches --proxy-env automatically' }
    }

    Write-Host "`nUpstream (GitHub Copilot API)"
    foreach ($h in 'api.enterprise.githubcopilot.com', 'api.githubcopilot.com') {
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-WebRequest -Uri "https://$h/models" -TimeoutSec 12 -SkipHttpErrorCheck -ErrorAction Stop
            $sw.Stop()
            OK $h "HTTP $($r.StatusCode) in $([math]::Round($sw.Elapsed.TotalSeconds,2))s"
        } catch { BAD $h 'no response within 12s'; HINT 'connection blocked or upstream unreachable' }
    }
    SKIP '' 'HTTP 400/401 = reached (an unauthenticated probe is expected to be rejected)'

    Write-Host "`nCodex Apps (ChatGPT MCP)"
    $appsUri = 'https://chatgpt.com/backend-api/wham/apps'
    SKIP 'route' "$appsUri — independent of localhost Copilot inference and Codex.app"
    if (-not $Live) {
        SKIP 'skipped' 'pass --live to compare direct and configured-proxy reachability'
    } else {
        $appsDirect = Invoke-CopilotOptionalHttpProbe -Uri $appsUri -Via 'direct'
        if ($appsDirect.Reached) {
            OK 'direct' "HTTP $($appsDirect.Code) in $($appsDirect.Seconds)s (an auth rejection still proves reachability)"
        } else {
            NOTE 'direct' "$($appsDirect.Kind) failure after $($appsDirect.Seconds)s"
            if ($appsDirect.Kind -eq 'tls') { HINT 'inspect antivirus/corporate TLS interception and the Windows trust store' }
            elseif ($appsDirect.Kind -eq 'timeout') { HINT 'the ChatGPT Apps route is blocked or not entering the expected TUN path' }
        }

        if ($httpProxy) {
            $appsVia = Invoke-CopilotOptionalHttpProbe -Uri $appsUri -Via $httpProxy
            if ($appsVia.Reached) {
                OK 'via proxy' "HTTP $($appsVia.Code) in $($appsVia.Seconds)s ($httpProxy)"
                if (-not $appsDirect.Reached) {
                    HINT "Codex Apps needs this route; launch Codex with HTTPS_PROXY=$httpProxy or repair TUN routing"
                }
            } elseif ($appsDirect.Reached) {
                SKIP 'via proxy' "$($appsVia.Kind) failure — direct already works, so Apps need no explicit proxy"
            } else {
                NOTE 'via proxy' "$($appsVia.Kind) failure after $($appsVia.Seconds)s ($httpProxy)"
                HINT 'this does not invalidate GitHub Copilot inference; it only explains codex_apps startup failures'
            }
        } else {
            SKIP 'via proxy' 'no explicit/system HTTP proxy detected; TUN may still carry direct traffic'
        }
    }

    Write-Host "`nLive probe"
    $effective = (Get-CopilotEffectiveModel) -split '\|', 2
    $probeTarget = Resolve-CopilotDoctorTarget -ConfiguredMain $effective[0] -RawModel $rawIds `
        -SelectableModel $selectableIds
    if (-not $Live) { SKIP 'skipped' 'pass --live to send one real request (consumes 1 quota unit)' }
    elseif (-not $proxyAlive) { SKIP 'skipped' 'proxy is not running' }
    elseif ($probeTarget.Label -eq 'MissingConfiguredMain') { SKIP 'skipped' $probeTarget.Reason }
    elseif (-not $probeTarget.Model) { SKIP 'skipped' 'the catalog has no usable inference model' }
    else {
        $pm = $probeTarget.Model
        SKIP 'target' "$pm [$($probeTarget.Label): $($probeTarget.Reason)]"
        $body = @{ model = $pm; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) } | ConvertTo-Json -Depth 5
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            # Bypass the throttle shim: doctor promises one upstream inference
            # attempt, while the normal client route intentionally retries bursts.
            $r = Invoke-WebRequest -Uri "$(Get-CopilotBase)/v1/messages?beta=true" -Method Post `
                -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
            $sw.Stop()
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
                OK 'round-trip' "$pm -> HTTP $($r.StatusCode) in $([math]::Round($sw.Elapsed.TotalSeconds,2))s"
            } else {
                $classified = Classify-CopilotInferenceError -StatusCode ([int]$r.StatusCode) -Body $r.Content
                BAD 'round-trip' "$pm -> HTTP $($r.StatusCode): $($classified.Summary)"
                if ($classified.Kind -eq 'BillingNotConfigured') {
                    HINT $classified.Action
                    HINT $classified.Guidance
                } elseif ($classified.Kind -eq 'ModelUnsupported') {
                    HINT $classified.Action
                } else {
                    HINT 'copilot-proxy logs 40'
                }
                SKIP 'retry' 'not attempted — doctor sends exactly one inference request'
            }
        } catch {
            BAD 'round-trip' "$pm -> request failed ($_)"
            SKIP 'retry' 'not attempted — doctor sends exactly one inference request'
        }
    }

    Write-Host ''
    if ($script:fail -gt 0) { Write-Host "$($script:fail) failed, $($script:warn) warning(s)`n"; return }
    Write-Host "all checks passed ($($script:warn) warning(s))`n"
}

# ------------------------------------------------------------- copilot-run ----
function copilot-run {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    if (-not $Argv -or $Argv.Count -eq 0) { Write-Error 'Usage: copilot-run <cmd> [args...]'; return }
    if (-not (Test-CopilotAlive)) { copilot-proxy start; if (-not (Test-CopilotAlive)) { return } }
    # Fail CLOSED: an enabled-but-down shim must not be silently bypassed — see
    # Get-CopilotClientBase. This used to be `Start-CopilotShim | Out-Null`,
    # which discarded the failure and then ran against the bare proxy.
    if (-not (Assert-CopilotShim)) { return }

    # Single source of truth — see Get-CopilotEnvBlock. A direct
    # `copilot-run claude --model ...` gets the explicit model's own ceiling;
    # claude-copilot supplies the same choice through COPILOT_CLAUDE_MODEL.
    $selectedModel = Get-CopilotDefaultModel
    if ([System.IO.Path]::GetFileNameWithoutExtension($Argv[0]) -eq 'claude') {
        $explicitModel = Get-CopilotClaudeModelArgument -Argv @($Argv | Select-Object -Skip 1)
        if ($explicitModel) { $selectedModel = Resolve-CopilotClaudeFastBaseModel -ExplicitModel $explicitModel }
    }
    $inject = Get-CopilotEnvBlock -Model $selectedModel
    # Scope env to the child process: set, run, restore (equivalent to `env VAR=..`).
    $saved = @{}
    foreach ($k in $inject.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $inject[$k] }
    $childSucceeded = $true
    $childExitCode = 0
    try {
        $exe = $Argv[0]
        $rest = @($Argv | Select-Object -Skip 1)
        $global:LASTEXITCODE = 0
        & $exe @rest
        $invocationSucceeded = $?
        $childExitCode = $LASTEXITCODE
        $childSucceeded = $invocationSucceeded -and ($childExitCode -eq 0)
    } finally {
        foreach ($k in $inject.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$k" $saved[$k] }
        }
    }
    if (-not $childSucceeded) {
        $global:LASTEXITCODE = $childExitCode
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("copilot-run: '$exe' exited with code $childExitCode"),
            'CopilotChildFailed',
            [System.Management.Automation.ErrorCategory]::OperationStopped,
            $exe
        ))
    }
}

# One OpenAI tier policy for both Claude Code and Codex. Known model roles beat
# lexical guesses about future ids; only then consider unknown flagship/coding/
# lightweight GPT variants.
function script:Select-CopilotBestOpenAIModel {
    param([string[]] $Model)
    if (-not $Model -or $Model.Count -eq 0) { return $null }
    $Model = @($Model | ForEach-Object { Remove-CopilotContextHint $_ } | Sort-Object -Unique)

    foreach ($preferred in 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.5', 'gpt-5.4', 'gpt-5.3-codex',
                           'gpt-5.6-luna', 'gpt-5.4-mini', 'gpt-5-mini') {
        if ($Model -contains $preferred) { return $preferred }
    }
    $pick = { param($re, $exclude)
        $c = @($Model | Where-Object { $_ -match $re -and (-not $exclude -or $_ -notmatch $exclude) } | Sort-Object)
        if ($c.Count -gt 0) { $c[-1] } else { $null }
    }
    $r = & $pick '^gpt-' 'mini|nano|luna'
    if ($r) { return $r }
    $r = & $pick 'codex' $null
    if ($r) { return $r }
    & $pick '^gpt-' $null
}

# Codex prefers a native Responses-capable OpenAI model. Claude/Gemini are
# Responses Lite fallbacks only, unlike Select-CopilotBestModel (Claude Code),
# where native Claude remains the first choice.
function script:Select-CopilotBestCodexModel {
    param([string[]] $Model)
    if (-not $Model -or $Model.Count -eq 0) { return $null }
    $Model = @($Model | ForEach-Object { Remove-CopilotContextHint $_ } | Sort-Object -Unique)

    $r = Select-CopilotBestOpenAIModel -Model $Model
    if ($r) { return $r }
    $pick = { param($re, $exclude)
        $c = @($Model | Where-Object { $_ -match $re -and (-not $exclude -or $_ -notmatch $exclude) } | Sort-Object)
        if ($c.Count -gt 0) { $c[-1] } else { $null }
    }

    foreach ($preferred in 'claude-fable-5',
                           'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6',
                           'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5',
                           'claude-opus-4-5', 'claude-haiku-4-5') {
        if ($Model -contains $preferred) { return $preferred }
    }
    $r = & $pick '^claude-' $null
    if ($r) { return $r }
    $r = & $pick '^gemini-' 'flash'
    if ($r) { return $r }
    $r = & $pick '^gemini-' $null
    if ($r) { return $r }
    @($Model | Sort-Object)[-1]
}

function script:Get-SpecstoryCodexCmd {
    foreach ($f in '.specstory/cli/config.toml', (Join-Path $HOME '.specstory/cli/config.toml')) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*codex_cmd\s*=\s*(?:"([^"]*)"|''([^'']*)'')') {
                $v = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                if ($v) { return $v }
            }
        }
    }
    'codex'
}

function script:Test-CopilotExplicitCodexModel {
    param([string[]] $Argv)
    foreach ($a in $Argv) {
        if ($a -in '-m', '--model' -or $a -match '^(?:-m|--model)=') { return $true }
    }
    $false
}

function script:Get-CodexCopilotProviderArgs {
    param([Parameter(Mandatory)] [string] $Base)
    @(
        '-c', 'model_provider="copilot_api"',
        '-c', 'model_providers.copilot_api.name="OpenAI"',
        '-c', "model_providers.copilot_api.base_url=`"$Base`"",
        '-c', 'model_providers.copilot_api.env_key="GITHUB_COPILOT_API_KEY"',
        '-c', 'model_providers.copilot_api.requires_openai_auth=false',
        '-c', 'model_providers.copilot_api.supports_websockets=false',
        '-c', 'model_providers.copilot_api.wire_api="responses"',
        '-c', 'model_providers.copilot_api.request_max_retries=3',
        '-c', 'model_providers.copilot_api.stream_max_retries=1',
        '-c', 'model_providers.copilot_api.stream_idle_timeout_ms=300000',
        '-c', 'features.remote_compaction_v2=true',
        '-c', 'features.code_mode.excluded_tool_namespaces=["mcp__codex_apps__sites"]'
    )
}

function script:Get-CodexSessionsRoot {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    Join-Path $codexHome 'sessions'
}

function script:Initialize-SpecstoryCodexSessionsRoot {
    [CmdletBinding()]
    param()
    $root = Get-CodexSessionsRoot
    try {
        [System.IO.Directory]::CreateDirectory($root) | Out-Null
        $true
    } catch {
        Write-Error "codex-copilot: could not initialize SpecStory sessions root '$root': $($_.Exception.Message)"
        $false
    }
}

function codex-copilot {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    $ss = 'auto'
    if ($Argv -and $Argv[0] -eq '--no-specstory') { $ss = 'never'; $Argv = @($Argv | Select-Object -Skip 1) }
    elseif ($Argv -and $Argv[0] -eq '--specstory') { $Argv = @($Argv | Select-Object -Skip 1) }
    elseif ($Argv -and $Argv[0] -in '-h', '--help') {
        Write-Host 'Usage: codex-copilot [--no-specstory] [codex args...]'
        Write-Host '  One-off Codex session on the local Copilot Responses gateway.'
        Write-Host '  Auto model: OpenAI/Codex > Claude > Gemini > other served chat models.'
        Write-Host '  Alias: codex-copilot-once'
        return
    }

    if (-not (Test-CopilotAlive)) { copilot-proxy start; if (-not (Test-CopilotAlive)) { return } }
    # Codex always needs the shim's Responses compatibility normalization even
    # when persistent burst throttling is disabled. This does not change state.
    # Unconditional (not gated on Test-CopilotShimAlive): that probe cannot tell
    # our shim from any other HTTP listener on the port, and Start-CopilotShim —
    # which does the ownership check — is idempotent and returns fast when the
    # shim is already up.
    if (-not (Start-CopilotShim)) { return }
    $catalog = Get-CopilotModelCatalog
    if (-not $catalog) { Write-Error 'codex-copilot: could not read the live gateway model catalog'; return }

    $explicitModel = Test-CopilotExplicitCodexModel -Argv $Argv
    $model = $null
    if (-not $explicitModel) {
        $models = Get-CopilotSelectableModelIds $catalog
        $model = Select-CopilotBestCodexModel -Model $models
        if (-not $model) { Write-Error 'codex-copilot: no usable chat model in the live gateway catalog'; return }
        $Argv = @('-m', $model) + @($Argv)
        if ($model -like 'claude-*' -or $model -like 'gemini-*') {
            Write-Warning "codex-copilot: --auto -> $model (Responses Lite; tool_search unavailable)"
        } else { Write-Host "codex-copilot: --auto -> $model" }
    }

    $base = Get-CopilotShimBase
    $providerArgs = @(Get-CodexCopilotProviderArgs -Base $base)
    if ($model) {
        $entry = $catalog.data | Where-Object { $_.id -eq $model } | Select-Object -First 1
        if ($entry.capabilities.limits.max_context_window_tokens) {
            $Argv = @('-c', "model_context_window=$($entry.capabilities.limits.max_context_window_tokens)") + @($Argv)
        }
        if ($entry.capabilities.limits.max_prompt_tokens) {
            $Argv = @('-c', "model_auto_compact_token_limit=$($entry.capabilities.limits.max_prompt_tokens)") + @($Argv)
        }
    }

    $savedKey = $env:GITHUB_COPILOT_API_KEY
    $env:GITHUB_COPILOT_API_KEY = 'dummy'
    $childSucceeded = $true
    $childExitCode = 0
    try {
        $useSpecstory = $ss -eq 'auto' -and (Get-Command specstory -ErrorAction SilentlyContinue)
        if ($useSpecstory -and -not (Initialize-SpecstoryCodexSessionsRoot)) { return }
        $global:LASTEXITCODE = 0
        if ($useSpecstory) {
            $cc = Get-SpecstoryCodexCmd
            foreach ($a in @($providerArgs) + @($Argv)) { $cc = "$cc $(ConvertTo-CopilotShQuote $a)" }
            specstory run codex -c $cc
        } else { codex @providerArgs @Argv }
        $invocationSucceeded = $?
        $childExitCode = $LASTEXITCODE
        $childSucceeded = $invocationSucceeded -and ($childExitCode -eq 0)
    } finally {
        if ($null -eq $savedKey) { Remove-Item env:GITHUB_COPILOT_API_KEY -ErrorAction SilentlyContinue }
        else { $env:GITHUB_COPILOT_API_KEY = $savedKey }
    }
    if (-not $childSucceeded) {
        $global:LASTEXITCODE = $childExitCode
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("codex-copilot: child exited with code $childExitCode"),
            'CodexCopilotChildFailed',
            [System.Management.Automation.ErrorCategory]::OperationStopped,
            'codex'
        ))
    }
}

function codex-copilot-once {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    if ($Argv.Count -gt 0) { codex-copilot @Argv } else { codex-copilot }
}

# --- specstory `-c` passthrough (configured base + wrapper policy) -----------
#
# specstory's `-c/--command` REPLACES the provider's configured command — it does
# NOT append to it. Build the complete command from the effective `claude_cmd`,
# then enforce claude-copilot's own bypass-permissions contract and append each
# user argument with shell-safe quoting. This keeps configured wrapper flags while
# making zero-argument and argument-bearing sessions behave identically.
# `--no-specstory` deliberately does not inherit the configured base command.

# Effective `claude_cmd`, honouring specstory's own precedence:
#   project ./.specstory/cli/config.toml > user ~/.specstory/cli/config.toml > `claude`
# Matches UNCOMMENTED assignments only — both shipped configs carry a commented
# `# claude_cmd = "claude"` example, and matching that would re-introduce the very
# bug this exists to fix. Handles TOML's double- and single-quoted strings.
function script:Get-SpecstoryClaudeCmd {
    foreach ($f in '.specstory/cli/config.toml', (Join-Path $HOME '.specstory/cli/config.toml')) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -notmatch '^\s*claude_cmd\s*=\s*("(?:\\.|[^"\\])*"|''[^'']*'')\s*(?:#.*)?$') { continue }
            $raw = $Matches[1]
            if ($raw[0] -eq '"') {
                try { $value = $raw | ConvertFrom-Json -ErrorAction Stop }
                catch { continue }
            } else {
                $value = $raw.Substring(1, $raw.Length - 2)
            }
            if ($value) { return $value }
        }
    }
    'claude'
}

# Single-quote ONE argument for embedding in specstory's `-c` command STRING.
# specstory shell-splits that string honouring quotes, so quoting is both possible
# and necessary — an unquoted join flattens `-p "two words"` into two arguments.
# POSIX escape for an embedded quote: close, \', reopen.
function script:ConvertTo-CopilotShQuote {
    param([string] $Value)
    "'" + ($Value -replace "'", "'\''") + "'"
}

# Build the complete command string passed to `specstory run claude -c`.
# Recognize the normal unquoted/fully quoted bypass token without pretending to
# parse arbitrary shell syntax. Exact duplicate wrapper arguments are suppressed;
# every other argument keeps its original order and multiplicity.
function script:New-SpecstoryClaudeCommand {
    param([string[]] $Argv)

    $bypass = '--dangerously-skip-permissions'
    $command = (Get-SpecstoryClaudeCmd).Trim()
    $escaped = [regex]::Escape($bypass)
    $hasBypass = $command -cmatch "(?:^|\s)(?:$escaped|'$escaped'|`"$escaped`")(?=\s|$)"
    if (-not $hasBypass) { $command = "$command $bypass" }
    if ($null -ne $Argv) {
        foreach ($argument in $Argv) {
            if ($argument -ceq $bypass) { continue }
            $command = "$command $(ConvertTo-CopilotShQuote $argument)"
        }
    }
    $command
}

function script:Get-CopilotClaudeModelArgument {
    param([string[]] $Argv)
    $model = $null
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        if ($Argv[$i] -ceq '--model' -and $i + 1 -lt $Argv.Count) {
            $model = $Argv[$i + 1]
            $i++
        } elseif ($Argv[$i] -clike '--model=*') {
            $model = $Argv[$i].Substring('--model='.Length)
        }
    }
    $model
}

function script:Resolve-CopilotClaudeFastBaseModel {
    param([string] $ExplicitModel)
    if (-not $ExplicitModel -or $ExplicitModel -eq 'default') {
        return ((Get-CopilotEffectiveModel) -split '\|', 2)[0]
    }
    $role = if ($ExplicitModel -eq 'opusplan') { 'opus' } else { $ExplicitModel }
    if ($role -in 'fable', 'opus', 'sonnet', 'haiku') {
        $effective = ((Get-CopilotEffectiveModel) -split '\|', 2)[0]
        $modelProfile = Get-CopilotModelProfile -Model $effective
        if ($modelProfile[$role]) { return [string]$modelProfile[$role] }
    }
    $ExplicitModel
}

function script:Resolve-CopilotClaudeLaunchModel {
    param([string[]] $Argv)
    $explicitModel = Get-CopilotClaudeModelArgument -Argv $Argv
    Resolve-CopilotClaudeFastBaseModel -ExplicitModel $explicitModel
}

function script:Assert-CopilotPinnedCompactSafe {
    param([Parameter(Mandatory)] [string] $Model)
    $settings = '.claude/settings.local.json'
    if (-not (Test-Path $settings)) { return $true }
    try { $obj = Get-Content -Raw $settings | ConvertFrom-Json } catch { return $true }
    if (-not $obj.env.ANTHROPIC_BASE_URL) { return $true }
    $pinned = 0L
    if (-not [long]::TryParse([string]$obj.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW, [ref]$pinned)) { return $true }
    $catalog = Get-CopilotModelCatalog
    try { $limit = Get-CopilotClaudeCompactWindow -Model $Model -Catalog $catalog } catch { Write-Error $_; return $false }
    if ($null -ne $limit -and $pinned -gt $limit) {
        Write-Error "claude-copilot: active copilot-here pin has compact window $pinned, but $Model allows $limit. Run: copilot-model $(Remove-CopilotContextHint $Model), then restart Claude Code."
        return $false
    }
    $true
}

# --------------------------------------------------------- claude-copilot -----
function claude-copilot {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    $ss = 'auto'
    $fast = $false
    while ($Argv -and $Argv.Count -gt 0) {
        if ($Argv[0] -eq '--fast') {
            $fast = $true; $Argv = @($Argv | Select-Object -Skip 1); continue
        }
        if ($Argv[0] -eq '--no-specstory') {
            $ss = 'never'; $Argv = @($Argv | Select-Object -Skip 1); continue
        }
        if ($Argv[0] -eq '--specstory') {
            $ss = 'auto'; $Argv = @($Argv | Select-Object -Skip 1); continue
        }
        if ($Argv[0] -in '-h', '--help') {
            Write-Host "Usage: claude-copilot [--fast] [--no-specstory] [claude args...]"
            Write-Host "  One-off Claude Code session on the Copilot proxy. Sticky: copilot-here on"
            Write-Host "  --fast selects this session's live-catalog fast sibling; unavailable falls back with a warning."
            Write-Host "  Runs claude with --dangerously-skip-permissions (hands-off proxy flow)."
            return
        }
        break
    }

    if ($fast) {
        if (-not (Test-CopilotAlive)) { copilot-proxy start }
        if ((Test-CopilotAlive) -and (Assert-CopilotShim)) {
            $explicitModel = Get-CopilotClaudeModelArgument -Argv $Argv
            $baseModel = Resolve-CopilotClaudeFastBaseModel -ExplicitModel $explicitModel
            $fastModel = if ($baseModel) { Resolve-CopilotFastModel -Model $baseModel } else { $null }
            if ($fastModel) {
                # Appended last so it overrides an earlier explicit --model while
                # using that value to choose the corresponding fast sibling.
                $Argv = @($Argv) + @('--model', $fastModel)
                Write-Host "claude-copilot: --fast -> $fastModel (session only)"
            } else {
                $label = if ($baseModel) { $baseModel } else { 'the selected model' }
                Write-Warning "claude-copilot: --fast unavailable for $label; using the standard model."
            }
        } else { return }
    }
    $launchModel = Resolve-CopilotClaudeLaunchModel -Argv $Argv
    if (-not (Assert-CopilotPinnedCompactSafe -Model $launchModel)) { return }
    $savedLaunchModel = [Environment]::GetEnvironmentVariable('COPILOT_CLAUDE_MODEL')
    $env:COPILOT_CLAUDE_MODEL = $launchModel
    try {
        if ($ss -eq 'auto' -and (Get-Command specstory -ErrorAction SilentlyContinue)) {
            $command = New-SpecstoryClaudeCommand -Argv $Argv
            copilot-run specstory run claude -c $command
        } else {
            # No specstory on PATH (the Windows default — no native CLI yet): run claude
            # directly, still bypassing permission prompts so behaviour matches the
            # specstory path regardless of whether specstory is installed.
            copilot-run claude --dangerously-skip-permissions @Argv
        }
    } finally {
        if ($null -eq $savedLaunchModel) { Remove-Item env:COPILOT_CLAUDE_MODEL -ErrorAction SilentlyContinue }
        else { $env:COPILOT_CLAUDE_MODEL = $savedLaunchModel }
    }
}

# --------------------------------------------------- claude-copilot-once ------
function claude-copilot-once {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    if ($Argv -and $Argv[0] -in '-h', '--help') {
        Write-Host "Usage: claude-copilot-once [--fast] [--no-specstory] [claude args...]"
        Write-Host "  Pin this project to the proxy, run one session, auto-unpin (even on Ctrl-C)."
        return
    }
    if (-not (Test-CopilotAlive)) {
        Write-Error "claude-copilot-once: proxy not reachable on port $(Get-CopilotPort). Start it: copilot-proxy start"; return
    }
    $wasOn = $false
    if (Test-Path '.claude/settings.local.json') {
        try { if ((Get-Content -Raw '.claude/settings.local.json' | ConvertFrom-Json).env.ANTHROPIC_BASE_URL) { $wasOn = $true } } catch { $null = $_ }
    }
    if (-not $wasOn) {
        $explicitModel = Get-CopilotClaudeModelArgument -Argv $Argv
        $wantsFast = $Argv -contains '--fast'
        if ($explicitModel -or $wantsFast) {
            $pinModel = Resolve-CopilotClaudeFastBaseModel -ExplicitModel $explicitModel
            if ($wantsFast) {
                $fastPinModel = Resolve-CopilotFastModel -Model $pinModel
                if ($fastPinModel) { $pinModel = $fastPinModel }
            }
            copilot-here on $pinModel
        } else {
            copilot-here on
        }
    }
    else {
        # Already pinned here. If the pin drifted from current defaults (model bump,
        # proxy moved, a key added since), offer to refresh it in place; otherwise
        # leave it untouched. Either way it was already ON, so it stays ON on exit.
        $drift = Get-CopilotHereDrift
        if ($drift) {
            Write-Host "claude-copilot-once: this project's copilot-here pin looks stale:"
            $drift | ForEach-Object { Write-Host $_ }
            if (Confirm-CopilotAction '  override with current defaults? (keep = default) [y/N]') { copilot-here on }
            else { Write-Host 'claude-copilot-once: kept the existing pin (stays ON on exit).' }
        } else {
            Write-Host "claude-copilot-once: copilot-here already ON here — leaving the pin in place on exit."
        }
    }
    $sessionSucceeded = $true
    $sessionExitCode = 0
    try {
        $global:LASTEXITCODE = 0
        if ($Argv.Count -gt 0) { claude-copilot @Argv } else { claude-copilot }
        $invocationSucceeded = $?
        $sessionExitCode = $LASTEXITCODE
        $sessionSucceeded = $invocationSucceeded -and ($sessionExitCode -eq 0)
    } finally {
        if (-not $wasOn) { copilot-here off }
        Write-Host "claude-copilot-once: session ended. Proxy still running on $(Get-CopilotBase)."
    }
    if (-not $sessionSucceeded) {
        $global:LASTEXITCODE = $sessionExitCode
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [Exception]::new("claude-copilot-once: session exited with code $sessionExitCode"),
            'ClaudeCopilotSessionFailed',
            [System.Management.Automation.ErrorCategory]::OperationStopped,
            'claude'
        ))
    }
}

# ------------------------------------------------------------ copilot-here ----
$script:CopilotHereKeys = @(
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_FABLE_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW',
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_ATTRIBUTION_HEADER',
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION', 'CLAUDE_CODE_ENABLE_AWAY_SUMMARY', 'DISABLE_NON_ESSENTIAL_MODEL_CALLS'
)

# y/N prompt. Returns $true only on an explicit yes; a non-interactive host
# returns $false — the safe default (keep, don't override). Only called right
# before launching an interactive Claude Code session, so reading input is fine.
function script:Confirm-CopilotAction {
    param([string] $Message = 'Proceed? [y/N]')
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $false }
    $ans = Read-Host -Prompt $Message
    $ans -match '^\s*y(es)?\s*$'
}

# Has THIS project's copilot-here pin drifted from what `copilot-here on` would
# write now (default model bumped, proxy moved, a key added since the pin was
# written)? Returns one "  KEY : old -> new" line per drifted key, or nothing.
#
# Drift is defined as "the set of keys `copilot-here on` would actually CHANGE",
# computed by diffing the live file against Get-CopilotEnvBlock — not a hand-picked
# subset (that is how three keys silently went unchecked). The asymmetry is
# deliberate: keys present in the file but absent from the want-set are NOT drift,
# because `on` merges and never removes them (only `off` does).
function script:Get-CopilotHereDrift {
    $settings = '.claude/settings.local.json'
    if (-not (Test-Path $settings)) { return @() }
    try { $obj = Get-Content -Raw $settings | ConvertFrom-Json } catch { return @() }
    # ANTHROPIC_BASE_URL is only set while the pin is ON — absent -> nothing to do.
    if (-not $obj.env.ANTHROPIC_BASE_URL) { return @() }

    $want = Get-CopilotEnvBlock -Pinned
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $want.Keys) {
        $cur = if ($obj.env.PSObject.Properties[$k]) { $obj.env.$k } else { '(unset)' }
        if ($cur -ne $want[$k]) { $out.Add("  $k : $cur -> $($want[$k])") }
    }
    $out
}

function copilot-here {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    $settings = '.claude/settings.local.json'
    $action = if ($Argv -and $Argv.Count -ge 1) { $Argv[0] } else { 'status' }
    switch ($action) {
        'on' {
            New-Item -ItemType Directory -Force -Path '.claude' | Out-Null
            $obj = if (Test-Path $settings) { try { Get-Content -Raw $settings | ConvertFrom-Json } catch { [pscustomobject]@{} } } else { [pscustomobject]@{} }
            if (-not $obj.PSObject.Properties['env']) { $obj | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
            # Single source of truth, shared with copilot-run and the drift check.
            $oldModel = if ($obj.env.ANTHROPIC_MODEL) { [string]$obj.env.ANTHROPIC_MODEL } else { '' }
            $oldCompact = if ($obj.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) { [string]$obj.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW } else { '' }
            $requestedModel = if ($Argv.Count -ge 2 -and $Argv[1]) { $Argv[1] } else { Get-CopilotDefaultModel }
            $envSet = Get-CopilotEnvBlock -Pinned -Model $requestedModel
            $model = $envSet.ANTHROPIC_MODEL
            foreach ($k in $envSet.Keys) {
                if ($obj.env.PSObject.Properties[$k]) { $obj.env.$k = $envSet[$k] }
                else { $obj.env | Add-Member -NotePropertyName $k -NotePropertyValue $envSet[$k] }
            }
            $hasCompact = $envSet.Contains('CLAUDE_CODE_AUTO_COMPACT_WINDOW')
            if (-not $hasCompact -and (Remove-CopilotContextHint $oldModel) -ne (Remove-CopilotContextHint $model) -and $obj.env.PSObject.Properties['CLAUDE_CODE_AUTO_COMPACT_WINDOW']) {
                $obj.env.PSObject.Properties.Remove('CLAUDE_CODE_AUTO_COMPACT_WINDOW')
            }
            $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settings -Encoding utf8
            # Belt-and-braces gitignore via .git/info/exclude (un-anchored **/ form).
            $gitDir = git rev-parse --git-dir 2>$null
            if ($gitDir) {
                git check-ignore -q $settings 2>$null
                if ($LASTEXITCODE -ne 0) {
                    $exclude = Join-Path $gitDir 'info/exclude'
                    Add-Content -Path $exclude -Value '**/.claude/settings.local.json'
                }
            }
            Write-Host "copilot-here: ON — $settings pins Claude Code to $(Get-CopilotBase) (model: $model)"
            if ($hasCompact) { Write-Host "  compact window: $($envSet.CLAUDE_CODE_AUTO_COMPACT_WINDOW) tokens (live model metadata)" }
            elseif ($oldCompact -and (Remove-CopilotContextHint $oldModel) -eq (Remove-CopilotContextHint $model)) { Write-Host "  WARNING compact window: $oldCompact tokens (last-known; live metadata unavailable)" }
            else { Write-Host "  WARNING compact window not pinned; refresh with 'copilot-here on' when the proxy is available" }
            if (-not (Test-CopilotAlive)) { Write-Host "  WARNING proxy not running — start it: copilot-proxy start" }
        }
        'off' {
            if (-not (Test-Path $settings)) { Write-Host "copilot-here: already off (no $settings)"; return }
            try { $obj = Get-Content -Raw $settings | ConvertFrom-Json } catch { Write-Error "copilot-here: $settings is not valid JSON"; return }
            if ($obj.env) {
                foreach ($k in $script:CopilotHereKeys) { if ($obj.env.PSObject.Properties[$k]) { $obj.env.PSObject.Properties.Remove($k) } }
                if (-not $obj.env.PSObject.Properties) { $obj.PSObject.Properties.Remove('env') }
            }
            if (-not $obj.PSObject.Properties.Name) {
                Remove-Item $settings -ErrorAction SilentlyContinue
                Write-Host "copilot-here: OFF — removed $settings (it held only proxy config)"
            } else {
                $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settings -Encoding utf8
                Write-Host "copilot-here: OFF — proxy env removed from $settings (other content kept)"
            }
        }
        'status' {
            if (Test-Path $settings) {
                try { $obj = Get-Content -Raw $settings | ConvertFrom-Json } catch { $obj = $null }
                if ($obj.env.ANTHROPIC_BASE_URL) {
                    Write-Host "copilot-here: ON  (base: $($obj.env.ANTHROPIC_BASE_URL), model: $($obj.env.ANTHROPIC_MODEL))"
                    $compactLabel = if ($obj.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $obj.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW } else { 'unverified' }
                    Write-Host "  compact window: $compactLabel"
                    $drift = Get-CopilotHereDrift
                    if ($drift) {
                        Write-Host '  ! stale vs current defaults:'
                        $drift | ForEach-Object { Write-Host $_ }
                        Write-Host '  refresh in place: copilot-here on'
                    }
                    if (-not (Test-CopilotAlive)) { Write-Host "  WARNING proxy not running — start it: copilot-proxy start" }
                    return
                }
            }
            Write-Host "copilot-here: off  (enable: copilot-here on; one-off: claude-copilot)"
        }
        default { Write-Host "Usage: copilot-here [on|off|status]" }
    }
}

# Pick the best raw served id for the main Claude Code model. Claude remains the
# first choice when entitled. Without Claude, rank OpenAI by capability tier and
# deliberately place lightweight Luna behind older flagship/coding tiers.
function script:Select-CopilotBestModel {
    param([string[]] $Model)
    if (-not $Model -or $Model.Count -eq 0) { return $null }
    $Model = @($Model | ForEach-Object { Remove-CopilotContextHint $_ } | Sort-Object -Unique)

    foreach ($preferred in 'claude-fable-5',
                           'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6',
                           'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5',
                           'claude-opus-4-5', 'claude-haiku-4-5') {
        if ($Model -contains $preferred) { return $preferred }
    }
    $pick = { param($re, $exclude)
        $c = @($Model | Where-Object { $_ -match $re -and (-not $exclude -or $_ -notmatch $exclude) } | Sort-Object)
        if ($c.Count -gt 0) { $c[-1] } else { $null }
    }
    $r = & $pick '^claude-' $null
    if ($r) { return $r }

    $r = Select-CopilotBestOpenAIModel -Model $Model
    if ($r) { return $r }

    foreach ($try in @(@('^gemini-', 'flash'), @('^gemini-', $null))) {
        $r = & $pick $try[0] $try[1]
        if ($r) { return $r }
    }
    (@($Model | Sort-Object))[-1]
}

# ----------------------------------------------------------- copilot-model ----
function copilot-model {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    $settings = '.claude/settings.local.json'
    $statef = Get-CopilotModelState
    $arg = if ($Argv -and $Argv.Count -ge 1) { $Argv[0] } else { '' }

    $target = 'state'
    if (Test-Path $settings) {
        try { if ((Get-Content -Raw $settings | ConvertFrom-Json).env.ANTHROPIC_BASE_URL) { $target = 'local' } } catch { $null = $_ }
    }

    $fallback = @(
        'claude-fable-5', 'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6', 'claude-opus-4-5',
        'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5', 'claude-haiku-4-5',
        'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.5', 'gpt-5.4', 'gpt-5.3-codex',
        'gpt-5.4-mini', 'gpt-5-mini'
    )
    $currentModel = if ($target -eq 'local') {
        (Get-Content -Raw $settings | ConvertFrom-Json).env.ANTHROPIC_MODEL
    } else { Get-CopilotDefaultModel }

    switch ($arg) {
        { $_ -in '-l', '--list' } {
            $catalog = Get-CopilotModelCatalog
            if ($catalog) { Get-CopilotCatalogIds $catalog }
            else { Write-Host 'copilot-model: proxy not reachable — showing fallback list'; $fallback }
            return
        }
        { $_ -in '-c', '--current' } {
            if ($target -eq 'local') {
                $envBlock = (Get-Content -Raw $settings | ConvertFrom-Json).env
                $modelProfile = [ordered]@{
                    main   = if ($envBlock.ANTHROPIC_MODEL) { $envBlock.ANTHROPIC_MODEL } else { '(unset)' }
                    fable  = if ($envBlock.ANTHROPIC_DEFAULT_FABLE_MODEL) { $envBlock.ANTHROPIC_DEFAULT_FABLE_MODEL } else { $envBlock.ANTHROPIC_MODEL }
                    opus   = if ($envBlock.ANTHROPIC_DEFAULT_OPUS_MODEL) { $envBlock.ANTHROPIC_DEFAULT_OPUS_MODEL } else { $envBlock.ANTHROPIC_MODEL }
                    sonnet = if ($envBlock.ANTHROPIC_DEFAULT_SONNET_MODEL) { $envBlock.ANTHROPIC_DEFAULT_SONNET_MODEL } else { $envBlock.ANTHROPIC_MODEL }
                    haiku  = if ($envBlock.ANTHROPIC_DEFAULT_HAIKU_MODEL) { $envBlock.ANTHROPIC_DEFAULT_HAIKU_MODEL } else { $envBlock.ANTHROPIC_MODEL }
                }
                Write-Host "model profile (project: $settings)"
                $compactLabel = if ($envBlock.CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $envBlock.CLAUDE_CODE_AUTO_COMPACT_WINDOW } else { 'unverified' }
            } else {
                $catalog = Get-CopilotModelCatalog
                $modelProfile = Get-CopilotModelProfile -Model $currentModel -Catalog $catalog
                $compact = Get-CopilotClaudeCompactWindow -Model $currentModel -Catalog $catalog
                $compactLabel = if ($null -ne $compact) { $compact } else { 'unverified' }
                Write-Host "model profile (global main: $statef)"
            }
            Write-CopilotModelProfile $modelProfile
            Write-Host "  compact: $compactLabel"
            return
        }
        { $_ -in '-h', '--help' } {
            Write-Host "Usage: copilot-model [<model-id>|-l|-c|--auto]"
            Write-Host "  --auto  live catalog: Claude; else capability-ranked OpenAI"
            Write-Host "          (Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini)"
            Write-Host "  Writes a complete Main/Fable/Opus/Sonnet/Haiku role profile locally."
            return
        }
    }

    $catalog = Get-CopilotModelCatalog
    $models = if ($catalog) { Get-CopilotCatalogIds $catalog } else { $fallback }
    $resolved = ''
    if ($arg -in '--auto', '-a') {
        # Never silently choose from the static list while the proxy is down: that
        # recreates the stale model_not_supported pin this command is meant to fix.
        if (-not $catalog) {
            Write-Error 'copilot-model: --auto needs a reachable proxy and live /v1/models catalog'; return
        }
        $selectableModels = @(Get-CopilotSelectableModelIds $catalog)
        if ($selectableModels.Count -eq 0) {
            Write-Error 'copilot-model: --auto found no selectable chat model in the live catalog'; return
        }
        $raw = Select-CopilotBestModel -Model $selectableModels
        if (-not $raw) { Write-Error "copilot-model: --auto could not pick a model"; return }
        $resolved = ConvertTo-CopilotClaudeModel -Model $raw -Catalog $catalog
        $why = switch -Regex ($resolved) {
            '^claude-'  { 'Claude preferred'; break }
            '^(gpt-|.*codex|o\d)' { 'no Claude; capability-ranked OpenAI'; break }
            '^gemini-'  { 'no Claude/OpenAI; best Gemini'; break }
            default     { 'best available' }
        }
        Write-Host "copilot-model: --auto -> $resolved  ($why)"
    } elseif (-not $arg) {
        if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { Write-Error "copilot-model: pass a model id (fzf not found). Try: copilot-model -l"; return }
        $want = $models | fzf --prompt='model> ' --height=40% --reverse --header="current: $currentModel  |  tip: copilot-model --auto"
        if (-not $want) { Write-Host 'cancelled'; return }
        $resolved = ConvertTo-CopilotClaudeModel -Model $want -Catalog $catalog
    } else {
        $suffix = ''; $base = $arg
        if ($arg -match '\[1m\]$') { $suffix = '[1m]'; $base = $arg -replace '\[1m\]$', '' }
        $norm = $base -replace '\.', '-'
        foreach ($cand in @($base, "claude-$base", $norm, "claude-$norm")) {
            if ($models -contains $cand) { $resolved = $cand; break }
        }
        if (-not $resolved) {
            $hits = @($models | Where-Object { $_ -like "*$norm*" })
            if ($hits.Count -eq 1) { $resolved = $hits[0] }
            else { Write-Error "copilot-model: '$arg' did not match a unique model. Try: copilot-model -l"; return }
        }
        if ($suffix) { $resolved = "$resolved$suffix" }
        else { $resolved = ConvertTo-CopilotClaudeModel -Model $resolved -Catalog $catalog }
    }

    $old = $currentModel
    if ($old -eq $resolved -and $target -eq 'state') { Write-Host "copilot-model: already using $resolved (no change)"; return }

    if ($target -eq 'local') {
        $obj = Get-Content -Raw $settings | ConvertFrom-Json
        $modelProfile = Get-CopilotModelProfile -Model $resolved -Catalog $catalog
        $compactWindow = Get-CopilotClaudeCompactWindow -Model $resolved -Catalog $catalog
        $roleSet = [ordered]@{
            ANTHROPIC_MODEL                 = $modelProfile.main
            ANTHROPIC_DEFAULT_FABLE_MODEL   = $modelProfile.fable
            ANTHROPIC_DEFAULT_OPUS_MODEL    = $modelProfile.opus
            ANTHROPIC_DEFAULT_SONNET_MODEL  = $modelProfile.sonnet
            ANTHROPIC_DEFAULT_HAIKU_MODEL   = $modelProfile.haiku
            ANTHROPIC_SMALL_FAST_MODEL      = $modelProfile.haiku
        }
        foreach ($k in $roleSet.Keys) {
            if ($obj.env.PSObject.Properties[$k]) { $obj.env.$k = $roleSet[$k] }
            else { $obj.env | Add-Member -NotePropertyName $k -NotePropertyValue $roleSet[$k] }
        }
        if ($null -ne $compactWindow) {
            if ($obj.env.PSObject.Properties['CLAUDE_CODE_AUTO_COMPACT_WINDOW']) { $obj.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string]$compactWindow }
            else { $obj.env | Add-Member -NotePropertyName CLAUDE_CODE_AUTO_COMPACT_WINDOW -NotePropertyValue ([string]$compactWindow) }
        } elseif ((Remove-CopilotContextHint $old) -ne (Remove-CopilotContextHint $resolved) -and $obj.env.PSObject.Properties['CLAUDE_CODE_AUTO_COMPACT_WINDOW']) {
            $obj.env.PSObject.Properties.Remove('CLAUDE_CODE_AUTO_COMPACT_WINDOW')
        }
        $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settings -Encoding utf8
        if ($old -eq $resolved) { Write-Host "copilot-model: refreshed role profile for $resolved  (project: $settings)" }
        else { Write-Host "copilot-model: $old -> $resolved  (project: $settings)" }
        Write-CopilotModelProfile $modelProfile
        if ($null -ne $compactWindow) { Write-Host "  compact: $compactWindow tokens (live max prompt)" }
        else { Write-Host '  WARNING compact: metadata unavailable; existing same-model value was preserved when possible' }
        Write-Host "  restart Claude Code to apply (exit, then: claude -c)"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $statef) | Out-Null
        $resolved | Set-Content $statef
        Write-Host "copilot-model: $old -> $resolved  (global: $statef)"
        Write-CopilotModelProfile (Get-CopilotModelProfile -Model $resolved -Catalog $catalog)
        Write-Host '  applies to the next claude-copilot / copilot-run / copilot-here on'
    }
}

# ----------------------------------------------------------- copilot-embed ----
function copilot-embed {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    $model = if ($env:AICAP_EMBED_MODEL) { $env:AICAP_EMBED_MODEL } else { 'text-embedding-3-small' }
    $wantJson = $false; $doList = $false
    $rest = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        switch -Regex ($Argv[$i]) {
            '^(-m|--model)$' { $model = $Argv[++$i] }
            '^--model=' { $model = $Argv[$i] -replace '^--model=', '' }
            '^--json$' { $wantJson = $true }
            '^(-l|--list)$' { $doList = $true }
            '^(-h|--help)$' { Write-Host "Usage: copilot-embed [--model M] [--json] [TEXT | -]`n       copilot-embed -l"; return }
            default { $rest.Add($Argv[$i]) }
        }
    }
    if (-not (Test-CopilotAlive)) { copilot-proxy start; if (-not (Test-CopilotAlive)) { return } }

    if ($doList) {
        try { (Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/models" -TimeoutSec 3).data.id | Where-Object { $_ -match 'embed' } | Sort-Object } catch { $null = $_ }
        return
    }

    $text = if ($rest.Count -gt 0 -and $rest[0] -ne '-') { $rest -join ' ' } elseif (-not [Console]::IsInputRedirected) { Write-Error "copilot-embed: no text — pass an arg or pipe stdin"; return } else { [Console]::In.ReadToEnd() }
    if (-not $text) { Write-Error "copilot-embed: empty input"; return }

    # input MUST be an array (scalar 400s — fork issue #100).
    $payload = if ($model) { @{ model = $model; input = @($text) } } else { @{ input = @($text) } }
    try {
        $resp = Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/embeddings" -Method Post -ContentType 'application/json' `
            -Body ($payload | ConvertTo-Json -Depth 5) -TimeoutSec 60 -ErrorAction Stop
    } catch { Write-Error "copilot-embed: request failed — is the proxy up? ($_)"; return }

    if ($wantJson) { $resp | ConvertTo-Json -Depth 8; return }
    $vec = $resp.data[0].embedding
    if (-not $vec) { Write-Error "copilot-embed: empty embedding"; return }
    $vec | ConvertTo-Json -Compress
}

# ------------------------------------------------------------- semsearch ------
function semsearch {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    if (-not $Argv -or $Argv[0] -in '-h', '--help') {
        Write-Host "Usage: semsearch index [PATH...]        # build/refresh an index"
        Write-Host "       semsearch <QUERY> [-k N] [--corpus PATH]"
        if (-not $Argv) { return }
        return
    }
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Write-Error "semsearch: uv is required (scoop install uv)"; return }
    $src = chezmoi source-path 2>$null
    if (-not $src) { Write-Error "semsearch: could not resolve chezmoi source-path"; return }
    $script = Join-Path $src 'scripts/semsearch.py'
    if (-not (Test-Path $script)) { Write-Error "semsearch: $script not found (run 'chezmoi apply' after a git pull)"; return }
    if (-not (Test-CopilotAlive)) { copilot-proxy start; if (-not (Test-CopilotAlive)) { return } }
    $env:COPILOT_EMBED_BASE = Get-CopilotBase
    uv run --script $script @Argv
}

Export-ModuleMember -Function 'copilot-proxy', 'copilot-run', 'claude-copilot', 'claude-copilot-once',
    'codex-copilot', 'codex-copilot-once',
    'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch'
