# Copilot.psm1 — GitHub Copilot -> Anthropic proxy for Claude Code, native
# PowerShell port of the POSIX 43_copilot_proxy.sh / 44_copilot_embed.sh.
#
# Runs the maintained copilot-api fork (npm @jeffreycao/copilot-api) via `bunx`
# so a GitHub Copilot subscription can back Claude Code. The optional Bun
# throttle shim (copilot-throttle-shim.js) is reused verbatim from the unix side.
#
# Public commands (exported with their original hyphenated names for muscle
# memory — PSUseApprovedVerbs is intentionally waived):
#   copilot-proxy [start|stop|restart|status|doctor [--live]|logs [shim|N]|shim [on|off|status]|whoami|auth|reinstall]
#   copilot-run <cmd...>            run a command with the proxy env injected
#   claude-copilot [args...]        one-off Claude Code session on the proxy
#   claude-copilot-once [args...]   pinned one-shot session, auto-reverted
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
# pin, default model claude-opus-5[1m], and the ANTHROPIC_* env block.
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
#   COPILOT_SHIM_PORT    default 4142    - throttle shim port
#   COPILOT_API_PKG      default @jeffreycao/copilot-api@1.13.14 - spec to install
#                                          (changing it re-installs via the stamp)
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
function script:Get-CopilotPort { if ($env:COPILOT_PROXY_PORT) { $env:COPILOT_PROXY_PORT } else { '4141' } }
function script:Get-CopilotPkg  { if ($env:COPILOT_API_PKG)   { $env:COPILOT_API_PKG }   else { '@jeffreycao/copilot-api@1.13.14' } }
function script:Get-CopilotPkgFlavor {
    switch -Regex (Get-CopilotPkg) { '^copilot-api(@.*)?$' { 'original' } default { 'fork' } }
}
function script:Get-CopilotBase    { "http://localhost:$(Get-CopilotPort)" }
function script:Get-CopilotTmp     { if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() } }
function script:Get-CopilotLogFile { Join-Path (Get-CopilotTmp) "copilot-api-$(Get-CopilotPort).log" }
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

# Package NAME without the trailing @version, keeping any @scope/ prefix.
# The naive "split on @" eats the whole string on a scoped spec with no version
# (@jeffreycao/copilot-api -> ""), so test on the scope-stripped copy.
function script:Get-CopilotPkgName {
    $spec = Get-CopilotPkg
    if ($spec.TrimStart('@') -match '@') { $spec -replace '@[^@]*$', '' } else { $spec }
}

function script:Get-CopilotPkgPrefix { Join-Path (Get-XdgData) 'copilot-api/pkg' }
# Records the spec the prefix currently holds, so bumping COPILOT_API_PKG (or the
# pinned default) re-installs instead of silently running the old version.
function script:Get-CopilotPkgStamp { Join-Path (Get-CopilotPkgPrefix) '.installed-spec' }

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
    if (Get-Command bun -ErrorAction SilentlyContinue) {
        return @{ Exe = 'bun'; Pre = @('run', 'copilot-api'); Cwd = (Get-CopilotPkgPrefix) }
    }
    $null
}

# Did the package actually land in the prefix? This is the postcondition every
# install path is checked against — see Invoke-CopilotPkgInstallTry for why the
# process exit code is not trusted.
function script:Test-CopilotPkgPresent {
    if (Get-CopilotPkgBin) { return $true }
    Test-Path -LiteralPath (Join-Path (Get-CopilotPkgPrefix) "node_modules/$(Get-CopilotPkgName)")
}

# Is the CURRENTLY pinned spec installed and runnable?
function script:Test-CopilotPkgReady {
    $stamp = Get-CopilotPkgStamp
    if (-not (Test-Path -LiteralPath $stamp)) { return $false }
    if ((Get-Content -First 1 $stamp -ErrorAction SilentlyContinue) -ne (Get-CopilotPkg)) { return $false }
    Test-CopilotPkgPresent
}

# One `bun add` attempt in -Dir, bounded by -BudgetSeconds. -NoProxy strips the
# proxy env for the child. Returns $true only when the package is actually present
# afterwards.
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

    $proxyVars = 'ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy'
    $saved = @{}
    if ($NoProxy) {
        foreach ($v in $proxyVars) { $saved[$v] = [Environment]::GetEnvironmentVariable($v); Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    }
    try {
        $p = Start-Process -FilePath 'bun' -ArgumentList @('add', (Get-CopilotPkg), '--no-summary') `
            -WorkingDirectory $Dir -PassThru -NoNewWindow -ErrorAction Stop
        if ($p.WaitForExit($BudgetSeconds * 1000)) { return (Test-CopilotPkgPresent) }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        # The subshell's child is the one actually holding the cache lock.
        $name = [regex]::Escape((Get-CopilotPkgName))
        Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match '\badd\b' -and $_.CommandLine -match $name } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        return $false
    } catch {
        Write-Error "copilot-proxy: could not launch 'bun add' ($_)"; return $false
    } finally {
        if ($NoProxy) {
            foreach ($v in $proxyVars) { if ($null -ne $saved[$v]) { Set-Item "env:$v" $saved[$v] } }
        }
    }
}

# Ensure the pinned spec is installed. No-op (and no network) once it is.
function script:Install-CopilotPkg {
    if (Test-CopilotPkgReady) { return $true }
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
            Write-Warning "copilot-proxy: install stalled with the proxy env — retrying without it ..."
            # Drop bun's cache lock dir before retrying; the killed attempt may have
            # left it behind, and a stale lock hangs the retry for the same reason.
            $bunHome = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $HOME '.bun' }
            Remove-Item -Recurse -Force (Join-Path $bunHome 'install/cache/.tmp') -ErrorAction SilentlyContinue
        }
        if (-not (Invoke-CopilotPkgInstallTry -Dir $prefix -NoProxy -BudgetSeconds 90)) {
            Write-Error "copilot-proxy: could not install $spec — run 'copilot-proxy doctor'."; return $false
        }
    }

    if (-not (Test-CopilotPkgPresent) -or -not (Get-CopilotPkgLaunch)) {
        Write-Error "copilot-proxy: install finished but no runnable copilot-api under $prefix."; return $false
    }
    $spec | Set-Content -Path (Get-CopilotPkgStamp) -Encoding utf8
    $true
}

# Run a copilot-api subcommand (auth / check-usage / debug) in the foreground.
# Honours $launch.Cwd so the `bun run` fallback resolves node_modules/.bin.
function script:Invoke-CopilotPkgCommand {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)
    if (-not (Install-CopilotPkg)) { return }
    $launch = Get-CopilotPkgLaunch
    if (-not $launch) { Write-Error "copilot-proxy: no runnable copilot-api — try 'copilot-proxy reinstall'"; return }
    if ($launch.Cwd) { Push-Location $launch.Cwd }
    try { & $launch.Exe @($launch.Pre + $Argument) }
    finally { if ($launch.Cwd) { Pop-Location } }
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
function script:Get-CopilotModelState { Join-Path (Get-XdgState) 'copilot-proxy/model' }

# --- egress: which proxy should Node use for the GitHub /models fetch? --------
#
# copilot-api fetches /models ONCE at startup and caches it for the whole process
# lifetime, and GitHub geo-filters the Claude catalog on some egress paths. Node
# does NOT honour the Windows System Proxy on its own — it only sees HTTP(S)_PROXY
# — so a host whose browser reaches the unfiltered catalog could still have the
# proxy cache a Claude-less list, which then looks exactly like an entitlement
# problem. Resolve the URL here and hand it to the child explicitly.
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


function script:Test-CopilotAlive {
    try { $null = Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/models" -TimeoutSec 2 -ErrorAction Stop; $true }
    catch { $false }
}
function script:Test-CopilotShimAlive {
    try { $null = Invoke-WebRequest -Uri "$(Get-CopilotShimBase)/v1/models" -TimeoutSec 2 -SkipHttpErrorCheck -ErrorAction Stop; $true }
    catch { $false }
}
function script:Get-CopilotShimEnabled {
    switch ($env:COPILOT_PROXY_SHIM) {
        { $_ -in '1', 'on', 'true', 'yes' } { return $true }
        { $_ -in '0', 'off', 'false', 'no' } { return $false }
    }
    $sf = Get-CopilotShimState
    (Test-Path $sf) -and ((Get-Content -First 1 $sf -ErrorAction SilentlyContinue) -eq 'on')
}
function script:Get-CopilotClientBase {
    if ((Get-CopilotShimEnabled) -and (Test-CopilotShimAlive)) { Get-CopilotShimBase } else { Get-CopilotBase }
}
function script:Get-CopilotPinnedBase {
    if (Get-CopilotShimEnabled) { Get-CopilotShimBase } else { Get-CopilotBase }
}

# Resolve the model: $COPILOT_CLAUDE_MODEL > state file > default.
#
#   - HYPHENATED ids (claude-opus-4-8), not dotted (claude-opus-4.8): Claude Code
#     only recognizes hyphenated family names — dotted ids fall back to a legacy
#     "[Opus 4] retired" label AND a 200k context assumption.
#   - "[1m]" suffix: Copilot serves opus-5 / opus-4-8 / sonnet-5 with a 1M context
#     window; the suffix makes Claude Code strip it, send the context-1m beta
#     header, and size HUD/compaction to 1M. Claude Code-only.
function script:Get-CopilotDefaultModel {
    if ($env:COPILOT_CLAUDE_MODEL) { return $env:COPILOT_CLAUDE_MODEL }
    $sf = Get-CopilotModelState
    if (Test-Path $sf) { return (Get-Content -First 1 $sf) }
    'claude-opus-5[1m]'
}

# Every model id the proxy accepts: .id plus the .claude_model_id alias.
function script:Get-CopilotServedModels {
    try { $r = Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/models" -TimeoutSec 5 -ErrorAction Stop } catch { return @() }
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($m in $r.data) {
        if ($m.id) { $ids.Add($m.id) }
        if ($m.claude_model_id) { $ids.Add($m.claude_model_id) }
    }
    $ids | Sort-Object -Unique
}

# "<model>|<source>" — the model Claude Code would send from this directory.
function script:Get-CopilotEffectiveModel {
    $settings = '.claude/settings.local.json'
    if (Test-Path $settings) {
        try {
            $j = Get-Content -Raw $settings | ConvertFrom-Json
            if ($j.env.ANTHROPIC_BASE_URL) {
                $m = $j.env.ANTHROPIC_MODEL
                if ($m) { return "$m|project pin: $settings" }
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
    param([switch] $Pinned)
    $model = Get-CopilotDefaultModel
    $block = [ordered]@{
        ANTHROPIC_BASE_URL             = if ($Pinned) { Get-CopilotPinnedBase } else { Get-CopilotClientBase }
        ANTHROPIC_AUTH_TOKEN           = 'dummy'
        ANTHROPIC_MODEL                = $model
        ANTHROPIC_DEFAULT_OPUS_MODEL   = $model
        ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5[1m]'
        ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'claude-haiku-4-5'
        ANTHROPIC_SMALL_FAST_MODEL     = 'claude-haiku-4-5'
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    }
    if ($env:COPILOT_PROXY_QUIET -eq '1') {
        $block.CLAUDE_CODE_ATTRIBUTION_HEADER = '0'
        $block.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'
        $block.CLAUDE_CODE_ENABLE_AWAY_SUMMARY = '0'
        $block.DISABLE_NON_ESSENTIAL_MODEL_CALLS = '1'
    }
    $block
}

# --- shim start/stop ---
function script:Start-CopilotShim {
    if (Test-CopilotShimAlive) { return $true }
    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
        Write-Error "copilot-proxy: shim needs 'bun' (scoop install bun)"; return $false
    }
    $script = Get-CopilotShimScript
    if (-not (Test-Path $script)) { Write-Error "copilot-proxy: shim script not found at $script"; return $false }
    $env:COPILOT_SHIM_PORT = Get-CopilotShimPort
    $env:COPILOT_SHIM_UPSTREAM = Get-CopilotBase
    $p = Start-Process -FilePath 'bun' -ArgumentList @($script) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Get-CopilotShimLog) -RedirectStandardError "$(Get-CopilotShimLog).err"
    $p.Id | Set-Content -Path (Get-CopilotShimPid)
    for ($i = 0; $i -lt 10; $i++) { if (Test-CopilotShimAlive) { return $true }; Start-Sleep 1 }
    Write-Error "copilot-proxy: shim did not come up — check $(Get-CopilotShimLog)"; $false
}
function script:Stop-CopilotShim {
    $pidf = Get-CopilotShimPid
    if (Test-Path $pidf) {
        $pid_ = Get-Content -First 1 $pidf -ErrorAction SilentlyContinue
        if ($pid_) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
        Remove-Item $pidf -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name = 'bun.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*copilot-throttle-shim.js*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
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
            # Rotate the previous session's log (keep last 3).
            if (Test-Path $logf) {
                Remove-Item "$logf.3" -ErrorAction SilentlyContinue
                if (Test-Path "$logf.2") { Move-Item -Force "$logf.2" "$logf.3" }
                if (Test-Path "$logf.1") { Move-Item -Force "$logf.1" "$logf.2" }
                Move-Item -Force $logf "$logf.1"
            }
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
            for ($i = 0; $i -lt 20; $i++) {
                if (Test-CopilotAlive) {
                    if (Get-CopilotShimEnabled) {
                        if (Start-CopilotShim) { Write-Host "copilot-proxy: throttle shim up -> $(Get-CopilotShimBase) (-> $(Get-CopilotBase))" }
                    }
                    Write-Host "copilot-proxy: up -> $(Get-CopilotClientBase)  (logs: copilot-proxy logs)"
                    return
                }
                # Crashed on its own (bad flag, port taken, auth) — don't sit out the
                # remaining seconds pretending we're still waiting.
                if ($p.HasExited) {
                    Remove-Item $pidf -ErrorAction SilentlyContinue
                    Write-Error "copilot-proxy: server exited during startup — check 'copilot-proxy logs'."; return
                }
                Start-Sleep 1
            }
            # Timed out. REAP what we spawned: the old code returned and left it
            # running, so each retry stacked another orphan and none ever bound the port.
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Remove-Item $pidf -ErrorAction SilentlyContinue
            Write-Error "copilot-proxy: did not come up in time — check 'copilot-proxy logs'."
        }
        'stop' {
            Stop-CopilotShim
            if (Test-Path $pidf) {
                $pid_ = Get-Content -First 1 $pidf -ErrorAction SilentlyContinue
                if ($pid_) { Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue }
                Remove-Item $pidf -ErrorAction SilentlyContinue
            }
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*copilot-api*--port $port*" } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep 1
            if (Test-CopilotAlive) { Write-Error "copilot-proxy: still answering on $port (another instance?)"; return }
            Write-Host "copilot-proxy: stopped (port $port free)"
        }
        'restart' { copilot-proxy stop; copilot-proxy start }
        'status' {
            if (Test-CopilotAlive) {
                Write-Host "copilot-proxy: RUNNING on $(Get-CopilotBase)"
                $claude = (Get-CopilotServedModels) | Where-Object { $_ -match 'claude' }
                Write-Host "  models: $($claude -join ' ')"
                if (Get-CopilotShimEnabled) {
                    if (Test-CopilotShimAlive) { Write-Host "  shim:   ON, up on $(Get-CopilotShimBase)  -> clients use this" }
                    else { Write-Host "  shim:   ON but DOWN (clients fall back to $(Get-CopilotBase))" }
                } else { Write-Host "  shim:   off  (enable: copilot-proxy shim on)" }
            } else {
                Write-Host "copilot-proxy: not running on port $port  (start: copilot-proxy start)"
            }
        }
        { $_ -in 'doctor', 'test' } { Invoke-CopilotDoctor -Live:($Argv -contains '--live') }
        'logs' {
            if ($Argv.Count -ge 2 -and $Argv[1] -eq 'shim') {
                $lf = Get-CopilotShimLog; $n = if ($Argv.Count -ge 3) { [int]$Argv[2] } else { 40 }
            } else {
                $lf = $logf; $n = if ($Argv.Count -ge 2) { [int]$Argv[1] } else { 40 }
                if ($Argv.Count -ge 3 -and $Argv[2] -in '1', '2', '3') { $lf = "$logf.$($Argv[2])" }
            }
            if (Test-Path $lf) { Get-Content -Tail $n $lf }
            elseif (Test-Path "$lf.err") { Get-Content -Tail $n "$lf.err" }
            else { Write-Error "copilot-proxy: no log file at $lf" }
        }
        'auth' {
            # One-time device login -> stores a ghu_ token copilot-api can exchange.
            Write-Host "copilot-proxy: launching copilot-api device login ..."
            Invoke-CopilotPkgCommand auth
        }
        'reinstall' {
            # Force a clean re-install of the pinned spec (normally only needed if the
            # prefix got corrupted — a version bump re-installs on its own via the stamp).
            Write-Host "copilot-proxy: removing $(Get-CopilotPkgPrefix) ..."
            Remove-Item -Recurse -Force (Get-CopilotPkgPrefix) -ErrorAction SilentlyContinue
            if (-not (Install-CopilotPkg)) { return }
            Write-Host "copilot-proxy: installed $(Get-CopilotPkg) -> $(Get-CopilotPkgPrefix)"
        }
        { $_ -in 'whoami', 'usage' } {
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
                default {
                    if (Get-CopilotShimEnabled) {
                        $st = if (Test-CopilotShimAlive) { 'up' } else { 'down' }
                        Write-Host "copilot-proxy: shim ON ($st) on $(Get-CopilotShimBase)"
                    } else { Write-Host "copilot-proxy: shim off" }
                }
            }
        }
        { $_ -in '-h', '--help', 'help' } {
            Write-Host "Usage: copilot-proxy [start|stop|restart|status|doctor [--live]|logs [shim|N [gen]]|shim [on|off|status]|whoami|auth|reinstall]"
            Write-Host "  doctor (alias: test)  diagnose prereqs, package, auth, proxy, Claude catalog"
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

    Write-Host 'Prerequisites'
    foreach ($t in 'bun', 'node', 'uv') {
        $c = Get-Command $t -ErrorAction SilentlyContinue
        if ($c) { OK $t $c.Source } elseif ($t -eq 'uv') { NOTE $t 'not found — semsearch needs it' } else { BAD $t 'not found' }
    }

    Write-Host "`nPackage"
    # The proxy runs an INSTALLED binary, not `bunx <pkg>` — so a warm start does no
    # network at all. An un-installed prefix is not a fault: the next start installs it.
    if (Test-CopilotPkgReady) {
        OK 'installed' $pkg
        $launch = Get-CopilotPkgLaunch
        if ($launch) {
            $how = "$($launch.Exe) $($launch.Pre -join ' ')".Trim()
            if ($launch.Cwd) { $how += "   (cwd: $($launch.Cwd))" }
            SKIP 'runs via' $how
        } else { BAD 'runs via' 'no runnable binary'; HINT 'copilot-proxy reinstall' }
    } else {
        NOTE 'not installed' "$pkg — the next 'copilot-proxy start' installs it (one-time)"
        HINT 'copilot-proxy reinstall   # or force it now'
    }

    Write-Host "`nAuthentication"
    if (Test-Path (Get-CopilotToken)) { OK 'token file' (Get-CopilotToken) } else { BAD 'token file' 'absent'; HINT 'copilot-proxy auth' }

    Write-Host "`nProxy"
    if (Test-CopilotAlive) { OK 'listening' (Get-CopilotBase) } else { BAD 'listening' "nothing on port $port"; HINT 'copilot-proxy start' }
    # A wedged package installer is the non-obvious reason a proxy never binds the
    # port: `start` just says "did not come up in time" and the log shows only
    # "Resolving dependencies". Hard failure when nothing is listening (that IS the
    # fault), softer when the proxy is up (a leftover still holding bun's cache lock,
    # which will hang the next restart).
    $stale = @(Get-CopilotStaleInstaller)
    if ($stale.Count -gt 0) {
        if (Test-CopilotAlive) { NOTE 'stale installer' "$($stale.Count) leftover 'bun add … copilot-api' proc(s) — they hold bun's cache lock (a restart will hang)" }
        else { BAD 'stale installer' "$($stale.Count) wedged 'bun add … copilot-api' proc(s) — start is blocked at `"Resolving dependencies`", never binds port $port" }
        HINT "kill just those: Stop-Process -Id $($stale.ProcessId -join ',') -Force"
        HINT 'then: copilot-proxy reinstall'
        HINT 're-hangs? bun is stalling on the proxy — $env:COPILOT_INSTALL_NOPROXY=1; copilot-proxy reinstall'
    } else {
        SKIP 'installer' "no wedged 'bun add' process"
    }
    if (Get-CopilotShimEnabled) {
        if (Test-CopilotShimAlive) { OK 'throttle shim' "up on $(Get-CopilotShimBase)" } else { BAD 'throttle shim' 'enabled but DOWN'; HINT 'copilot-proxy shim on' }
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

    $served = Get-CopilotServedModels
    if ($served -and $served.Count -gt 0) {
        $claude = @($served | Where-Object { $_ -match '^claude' })
        OK 'served' "$($served.Count) model ids"
        if ($claude.Count -gt 0) { OK 'claude models' "$($claude.Count) ids available" }
        else { BAD 'claude models' "0 of $($served.Count) — the proxy serves no Anthropic models" }

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
            HINT 'copilot-model --auto   # Claude > Codex > GPT > Gemini from the served list'
            HINT 'copilot-model -l       # list served ids'
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

    Write-Host "`nLive probe"
    if (-not $Live) { SKIP 'skipped' 'pass --live to send one real request (consumes 1 quota unit)' }
    elseif (-not (Test-CopilotAlive)) { SKIP 'skipped' 'proxy is not running' }
    elseif (-not $served) { SKIP 'skipped' 'no served model to probe with' }
    else {
        $pm = @($served | Where-Object { $_ -notmatch 'embedding' -and $_ -notmatch '\[1m\]' })[0]
        $body = @{ model = $pm; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) } | ConvertTo-Json -Depth 5
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-WebRequest -Uri "$(Get-CopilotClientBase)/v1/messages?beta=true" -Method Post `
                -ContentType 'application/json' -Body $body -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
            $sw.Stop()
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { OK 'round-trip' "$pm -> HTTP $($r.StatusCode) in $([math]::Round($sw.Elapsed.TotalSeconds,2))s" }
            else { BAD 'round-trip' "$pm -> HTTP $($r.StatusCode)"; HINT 'copilot-proxy logs 40' }
        } catch { BAD 'round-trip' "$pm -> request failed ($_)" }
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
    if ((Get-CopilotShimEnabled) -and -not (Test-CopilotShimAlive)) { Start-CopilotShim | Out-Null }

    # Single source of truth — see Get-CopilotEnvBlock.
    $inject = Get-CopilotEnvBlock
    # Scope env to the child process: set, run, restore (equivalent to `env VAR=..`).
    $saved = @{}
    foreach ($k in $inject.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "env:$k" $inject[$k] }
    try {
        $exe = $Argv[0]; $rest = if ($Argv.Count -gt 1) { $Argv[1..($Argv.Count - 1)] } else { @() }
        & $exe @rest
    } finally {
        foreach ($k in $inject.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$k" $saved[$k] }
        }
    }
}

# --- specstory `-c` passthrough (why the base command must come from config) ---
#
# specstory's `-c/--command` REPLACES the provider's configured command — it does
# NOT append to it. The shipped config says as much: "Use of these is equivalent
# to -c \"custom command\"" — same slot, last write wins. So a hardcoded
# `-c "claude $args"` silently drops every flag in `claude_cmd` the moment
# claude-copilot has args to pass through, which made these two disagree:
#
#   claude-copilot-once             -> bypass-permissions  (no -c branch)
#   claude-copilot-once --resume X  -> ~/.claude defaultMode "auto"
#
# Deriving the base command from the config keeps specstory the single source of
# truth for BOTH branches. `--no-specstory` deliberately does NOT inherit it.

# Effective `claude_cmd`, honouring specstory's own precedence:
#   project ./.specstory/cli/config.toml > user ~/.specstory/cli/config.toml > `claude`
# Matches UNCOMMENTED assignments only — both shipped configs carry a commented
# `# claude_cmd = "claude"` example, and matching that would re-introduce the very
# bug this exists to fix. Handles TOML's double- and single-quoted strings.
function script:Get-SpecstoryClaudeCmd {
    foreach ($f in '.specstory/cli/config.toml', (Join-Path $HOME '.specstory/cli/config.toml')) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*claude_cmd\s*=\s*(?:"([^"]*)"|''([^'']*)'')') {
                $v = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
                if ($v) { return $v }
            }
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

# --------------------------------------------------------- claude-copilot -----
function claude-copilot {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    $ss = 'auto'
    if ($Argv -and $Argv[0] -eq '--no-specstory') { $ss = 'never'; $Argv = $Argv[1..($Argv.Count - 1)] }
    elseif ($Argv -and $Argv[0] -eq '--specstory') { $Argv = $Argv[1..($Argv.Count - 1)] }
    elseif ($Argv -and $Argv[0] -in '-h', '--help') {
        Write-Host "Usage: claude-copilot [--no-specstory] [claude args...]"
        Write-Host "  One-off Claude Code session on the Copilot proxy. Sticky: copilot-here on"
        Write-Host "  Runs claude with --dangerously-skip-permissions (hands-off proxy flow)."
        return
    }
    if ($ss -eq 'auto' -and (Get-Command specstory -ErrorAction SilentlyContinue)) {
        if ($Argv -and $Argv.Count -gt 0) {
            # Rebuild what `-c` clobbers: the configured base command (ITS flags left
            # unquoted so specstory splits them normally) + each of our args quoted.
            $cc = Get-SpecstoryClaudeCmd
            foreach ($a in $Argv) { $cc = "$cc $(ConvertTo-CopilotShQuote $a)" }
            copilot-run specstory run claude -c $cc
        }
        else { copilot-run specstory run claude }
    } else {
        # No specstory on PATH (the Windows default — no native CLI yet): run claude
        # directly, still bypassing permission prompts so behaviour matches the
        # specstory path regardless of whether specstory is installed.
        copilot-run claude --dangerously-skip-permissions @Argv
    }
}

# --------------------------------------------------- claude-copilot-once ------
function claude-copilot-once {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Argv)
    if ($Argv -and $Argv[0] -in '-h', '--help') {
        Write-Host "Usage: claude-copilot-once [--no-specstory] [claude args...]"
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
    if (-not $wasOn) { copilot-here on }
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
    try {
        claude-copilot @Argv
    } finally {
        if (-not $wasOn) { copilot-here off }
        Write-Host "claude-copilot-once: session ended. Proxy still running on $(Get-CopilotBase)."
    }
}

# ------------------------------------------------------------ copilot-here ----
$script:CopilotHereKeys = @(
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
    'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL',
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
            $model = Get-CopilotDefaultModel
            # Single source of truth, shared with copilot-run and the drift check.
            $envSet = Get-CopilotEnvBlock -Pinned
            foreach ($k in $envSet.Keys) {
                if ($obj.env.PSObject.Properties[$k]) { $obj.env.$k = $envSet[$k] }
                else { $obj.env | Add-Member -NotePropertyName $k -NotePropertyValue $envSet[$k] }
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

# Pick the best served model for Claude Code / copilot-run.
# Preference (first match wins): Claude (known ids, else any claude-*) -> *codex*
# -> non-mini gpt-5* -> any gpt-* -> non-flash gemini -> any gemini -> last resort.
# Appends [1m] for the Claude ids known to expose a 1M window to Claude Code.
function script:Select-CopilotBestModel {
    param([string[]] $Model)
    if (-not $Model -or $Model.Count -eq 0) { return $null }

    foreach ($preferred in 'claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6',
                           'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5',
                           'claude-opus-4-5', 'claude-haiku-4-5') {
        if ($Model -contains $preferred) {
            if ($preferred -in 'claude-opus-5', 'claude-opus-4-8', 'claude-sonnet-5') { return "$preferred[1m]" }
            return $preferred
        }
    }
    $pick = { param($re, $exclude)
        $c = @($Model | Where-Object { $_ -match $re -and (-not $exclude -or $_ -notmatch $exclude) } | Sort-Object)
        if ($c.Count -gt 0) { $c[-1] } else { $null }
    }
    foreach ($try in @(@('^claude-', $null), @('codex', $null), @('^gpt-5', 'mini|nano'),
                       @('^gpt-', $null), @('^gemini-', 'flash'), @('^gemini-', $null))) {
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

    function script:_ModelList {
        try {
            $r = Invoke-RestMethod -Uri "$(Get-CopilotBase)/v1/models" -TimeoutSec 3 -ErrorAction Stop
            return ($r.data.id | Sort-Object)
        } catch {
            Write-Host "copilot-model: proxy not reachable — showing fallback list"
            return @('claude-opus-5', 'claude-opus-4-8', 'claude-opus-4-7', 'claude-opus-4-6', 'claude-opus-4-5',
                     'claude-sonnet-5', 'claude-sonnet-4-6', 'claude-sonnet-4-5', 'claude-haiku-4-5')
        }
    }
    function script:_ModelCurrent {
        if ($target -eq 'local') { (Get-Content -Raw $settings | ConvertFrom-Json).env.ANTHROPIC_MODEL }
        else { Get-CopilotDefaultModel }
    }

    switch ($arg) {
        { $_ -in '-l', '--list' } { _ModelList; return }
        { $_ -in '-c', '--current' } {
            if ($target -eq 'local') { Write-Host "$(_ModelCurrent)  (project: $settings)" } else { Write-Host "$(_ModelCurrent)  (global: $statef)" }
            return
        }
        { $_ -in '-h', '--help' } {
            Write-Host "Usage: copilot-model [<model-id>|-l|-c|--auto]"
            Write-Host "  --auto  pick best from the live served list: Claude > Codex > GPT > Gemini"
            return
        }
    }

    $models = _ModelList
    $resolved = ''
    if ($arg -in '--auto', '-a') {
        # Use when a sticky pin (e.g. gemini from a Claude-less geo day) is stale, or
        # when Anthropic is filtered out and you want the best Codex/GPT instead.
        if (-not $models) { Write-Error "copilot-model: --auto needs a reachable proxy"; return }
        $resolved = Select-CopilotBestModel -Model $models
        if (-not $resolved) { Write-Error "copilot-model: --auto could not pick a model"; return }
        $why = switch -Regex ($resolved) {
            '^claude-'  { 'Claude preferred'; break }
            'codex'     { 'no Claude; best Codex'; break }
            '^(gpt-|o\d)' { 'no Claude/Codex; best GPT'; break }
            '^gemini-'  { 'no Claude/Codex/GPT; best Gemini'; break }
            default     { 'best available' }
        }
        Write-Host "copilot-model: --auto -> $resolved  ($why)"
    } elseif (-not $arg) {
        if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { Write-Error "copilot-model: pass a model id (fzf not found). Try: copilot-model -l"; return }
        $want = $models | fzf --prompt='model> ' --height=40% --reverse --header="current: $(_ModelCurrent)  |  tip: copilot-model --auto"
        if (-not $want) { Write-Host 'cancelled'; return }
        $resolved = $want
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
        $resolved = "$resolved$suffix"
    }

    $old = _ModelCurrent
    if ($old -eq $resolved) { Write-Host "copilot-model: already using $resolved (no change)"; return }

    if ($target -eq 'local') {
        $obj = Get-Content -Raw $settings | ConvertFrom-Json
        $obj.env.ANTHROPIC_MODEL = $resolved
        $obj.env.ANTHROPIC_DEFAULT_OPUS_MODEL = $resolved
        $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $settings -Encoding utf8
        Write-Host "copilot-model: $old -> $resolved  (project: $settings)"
        Write-Host "  restart Claude Code to apply (exit, then: claude -c)"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $statef) | Out-Null
        $resolved | Set-Content $statef
        Write-Host "copilot-model: $old -> $resolved  (global: $statef)"
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
    'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch'
