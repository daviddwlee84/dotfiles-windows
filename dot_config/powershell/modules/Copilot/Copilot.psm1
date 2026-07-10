# Copilot.psm1 — GitHub Copilot -> Anthropic proxy for Claude Code, native
# PowerShell port of the POSIX 43_copilot_proxy.sh / 44_copilot_embed.sh.
#
# Runs the maintained copilot-api fork (npm @jeffreycao/copilot-api) via `bunx`
# so a GitHub Copilot subscription can back Claude Code. The optional Bun
# throttle shim (copilot-throttle-shim.js) is reused verbatim from the unix side.
#
# Public commands (exported with their original hyphenated names for muscle
# memory — PSUseApprovedVerbs is intentionally waived):
#   copilot-proxy [start|stop|restart|status|doctor [--live]|logs [shim|N]|shim [on|off|status]|whoami|auth]
#   copilot-run <cmd...>            run a command with the proxy env injected
#   claude-copilot [args...]        one-off Claude Code session on the proxy
#   claude-copilot-once [args...]   pinned one-shot session, auto-reverted
#   copilot-here [on|off|status]    per-project pin via ./.claude/settings.local.json
#   copilot-model [<id>|-l|-c]      switch the pinned model
#   copilot-embed [--model M] [--json] [TEXT|-] | -l
#   semsearch index [PATH...] | semsearch <QUERY> [-k N] [--corpus PATH]
#
# Contract preserved from the unix version: token at
# ~/.local/share/copilot-api/github_token, ports 4141 (proxy) / 4142 (shim),
# state under $XDG_STATE_HOME/copilot-proxy, per-project ./.claude/settings.local.json
# pin, default model claude-opus-4-8[1m], and the ANTHROPIC_* env block.

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

# --- shim paths ---
function script:Get-CopilotShimPort   { if ($env:COPILOT_SHIM_PORT) { $env:COPILOT_SHIM_PORT } else { '4142' } }
function script:Get-CopilotShimBase   { "http://localhost:$(Get-CopilotShimPort)" }
function script:Get-CopilotShimScript { Join-Path (Get-XdgConfig) 'powershell/copilot-throttle-shim.js' }
function script:Get-CopilotShimLog    { Join-Path (Get-CopilotTmp) "copilot-shim-$(Get-CopilotShimPort).log" }
function script:Get-CopilotShimPid    { Join-Path (Get-CopilotTmp) "copilot-shim-$(Get-CopilotShimPort).pid" }
function script:Get-CopilotShimState  { Join-Path (Get-XdgState) 'copilot-proxy/shim' }
function script:Get-CopilotModelState { Join-Path (Get-XdgState) 'copilot-proxy/model' }

# The bun launcher: prefer `bunx`, else `bun x`.
function script:Get-BunLauncher {
    if (Get-Command bunx -ErrorAction SilentlyContinue) { return @{ Exe = 'bunx'; Pre = @() } }
    if (Get-Command bun  -ErrorAction SilentlyContinue) { return @{ Exe = 'bun';  Pre = @('x') } }
    return $null
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
function script:Get-CopilotDefaultModel {
    if ($env:COPILOT_CLAUDE_MODEL) { return $env:COPILOT_CLAUDE_MODEL }
    $sf = Get-CopilotModelState
    if (Test-Path $sf) { return (Get-Content -First 1 $sf) }
    'claude-opus-4-8[1m]'
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

    $bun = Get-BunLauncher
    if (-not $bun) { Write-Error "copilot-proxy: bun/bunx not found (scoop install bun)"; return }

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
            $argList = @($bun.Pre + @($pkg, 'start', '--port', $port))
            if ((Get-CopilotPkgFlavor) -eq 'original') {
                $rate = if ($env:COPILOT_PROXY_RATE) { $env:COPILOT_PROXY_RATE } else { '15' }
                $argList += @('--rate-limit', $rate, '--wait')
                Write-Host "copilot-proxy: starting ($pkg) on port $port (rate-limit ${rate}s) ..."
            } else {
                Write-Host "copilot-proxy: starting ($pkg) on port $port ..."
            }
            $p = Start-Process -FilePath $bun.Exe -ArgumentList $argList -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $logf -RedirectStandardError "$logf.err"
            $p.Id | Set-Content -Path $pidf
            for ($i = 0; $i -lt 20; $i++) {
                if (Test-CopilotAlive) {
                    if (Get-CopilotShimEnabled) {
                        if (Start-CopilotShim) { Write-Host "copilot-proxy: throttle shim up -> $(Get-CopilotShimBase) (-> $(Get-CopilotBase))" }
                    }
                    Write-Host "copilot-proxy: up -> $(Get-CopilotClientBase)  (logs: copilot-proxy logs)"
                    return
                }
                Start-Sleep 1
            }
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
            Write-Host "copilot-proxy: launching copilot-api device login ..."
            & $bun.Exe @($bun.Pre + @($pkg, 'auth'))
        }
        { $_ -in 'whoami', 'usage' } {
            if (-not (Test-Path (Get-CopilotToken))) { Write-Error "copilot-proxy: not authenticated — run 'copilot-proxy auth'."; return }
            if ((Get-CopilotPkgFlavor) -eq 'original') { & $bun.Exe @($bun.Pre + @($pkg, 'check-usage')) }
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
                & $bun.Exe @($bun.Pre + @($pkg, 'debug'))
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
            Write-Host "Usage: copilot-proxy [start|stop|restart|status|doctor [--live]|logs [shim|N [gen]]|shim [on|off|status]|whoami|auth]"
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

    Write-Host "`nAuthentication"
    if (Test-Path (Get-CopilotToken)) { OK 'token file' (Get-CopilotToken) } else { BAD 'token file' 'absent'; HINT 'copilot-proxy auth' }

    Write-Host "`nProxy"
    if (Test-CopilotAlive) { OK 'listening' (Get-CopilotBase) } else { BAD 'listening' "nothing on port $port"; HINT 'copilot-proxy start' }
    if (Get-CopilotShimEnabled) {
        if (Test-CopilotShimAlive) { OK 'throttle shim' "up on $(Get-CopilotShimBase)" } else { BAD 'throttle shim' 'enabled but DOWN'; HINT 'copilot-proxy shim on' }
    } else { SKIP 'throttle shim' 'off' }

    Write-Host "`nModels"
    $served = Get-CopilotServedModels
    if ($served -and $served.Count -gt 0) {
        $claude = @($served | Where-Object { $_ -match '^claude' })
        OK 'served' "$($served.Count) model ids"
        if ($claude.Count -gt 0) { OK 'claude models' "$($claude.Count) ids available" }
        else { BAD 'claude models' "0 of $($served.Count) — the proxy serves no Anthropic models" }

        $pin = (Get-CopilotEffectiveModel) -split '\|', 2
        $model = $pin[0]; $src = $pin[1]
        if ($served -contains $model) { OK 'pinned model' "$model  ($src)" }
        else { BAD 'pinned model' "$model  ($src)"; HINT 'not served -> requests return 400 model_not_supported'; HINT 'copilot-model -l' }
    } else { BAD 'served' "could not fetch $(Get-CopilotBase)/v1/models" }

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

    $model = Get-CopilotDefaultModel
    $inject = [ordered]@{
        ANTHROPIC_BASE_URL             = Get-CopilotClientBase
        ANTHROPIC_AUTH_TOKEN           = 'dummy'
        ANTHROPIC_MODEL                = $model
        ANTHROPIC_DEFAULT_OPUS_MODEL   = $model
        ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5[1m]'
        ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'claude-haiku-4-5'
        ANTHROPIC_SMALL_FAST_MODEL     = 'claude-haiku-4-5'
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    }
    if ($env:COPILOT_PROXY_QUIET -eq '1') {
        $inject.CLAUDE_CODE_ATTRIBUTION_HEADER = '0'
        $inject.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'
        $inject.CLAUDE_CODE_ENABLE_AWAY_SUMMARY = '0'
        $inject.DISABLE_NON_ESSENTIAL_MODEL_CALLS = '1'
    }
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
        return
    }
    if ($ss -eq 'auto' -and (Get-Command specstory -ErrorAction SilentlyContinue)) {
        if ($Argv -and $Argv.Count -gt 0) { copilot-run specstory run claude -c "claude $($Argv -join ' ')" }
        else { copilot-run specstory run claude }
    } else {
        copilot-run claude @Argv
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
    else { Write-Host "claude-copilot-once: copilot-here already ON here — leaving the pin in place on exit." }
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
            $envSet = [ordered]@{
                ANTHROPIC_BASE_URL             = Get-CopilotPinnedBase
                ANTHROPIC_AUTH_TOKEN           = 'dummy'
                ANTHROPIC_MODEL                = $model
                ANTHROPIC_DEFAULT_OPUS_MODEL   = $model
                ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5[1m]'
                ANTHROPIC_DEFAULT_HAIKU_MODEL  = 'claude-haiku-4-5'
                ANTHROPIC_SMALL_FAST_MODEL     = 'claude-haiku-4-5'
                CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
            }
            if ($env:COPILOT_PROXY_QUIET -eq '1') {
                $envSet.CLAUDE_CODE_ATTRIBUTION_HEADER = '0'
                $envSet.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = 'false'
                $envSet.CLAUDE_CODE_ENABLE_AWAY_SUMMARY = '0'
                $envSet.DISABLE_NON_ESSENTIAL_MODEL_CALLS = '1'
            }
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
                    if (-not (Test-CopilotAlive)) { Write-Host "  WARNING proxy not running — start it: copilot-proxy start" }
                    return
                }
            }
            Write-Host "copilot-here: off  (enable: copilot-here on; one-off: claude-copilot)"
        }
        default { Write-Host "Usage: copilot-here [on|off|status]" }
    }
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
            return @('claude-opus-4-8', 'claude-opus-4-7', 'claude-sonnet-5', 'claude-haiku-4-5')
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
        { $_ -in '-h', '--help' } { Write-Host "Usage: copilot-model [<model-id>|-l|-c]"; return }
    }

    $models = _ModelList
    $resolved = ''
    if (-not $arg) {
        if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) { Write-Error "copilot-model: pass a model id (fzf not found). Try: copilot-model -l"; return }
        $want = $models | fzf --prompt='model> ' --height=40% --reverse --header="current: $(_ModelCurrent)"
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
