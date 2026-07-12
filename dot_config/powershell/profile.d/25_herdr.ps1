# 25_herdr.ps1 — herdr workspace layout helpers (PowerShell port of the POSIX
# repo's dot_config/shell/24_herdr.sh). herdr's model is Workspace -> Tab -> Pane
# and its CLI (`herdr workspace|tab|pane|session …`) is the scripting surface that
# replaces tmux's new-session/split-window. This fragment gives the same
# muscle-memory commands the parent dotfiles have on Unix:
#
#   herdr-vibe / hvibe  — parametric multi-agent pack in a new workspace
#                         (N agent panes + lazygit tab + nvim tab)
#   herdr-code / hcode  — repo-scoped single-agent layout
#                         (nvim | agent split + monitor tab)
#   herdr-here / hhere  — plain "open a workspace here + attach"
#   herdr-root / hroot  — hhere at the git-root
#   herdr-mark / hmark  — flag a pane "review-pending" (⭐); hunmark clears it
#
# PORTING NOTES (why this isn't a line-for-line translation):
#   * jq -> ConvertFrom-Json (native; no jq dependency).
#   * The Unix helpers emit a *bash* on-exit wrapper (`trap '' INT; …; exec
#     $SHELL -l`). The pane shell here is pwsh (config.toml default_shell=pwsh),
#     so the wrapper is a pwsh script handed to the pane as
#     `pwsh -NoLogo [-NoExit] -EncodedCommand <base64>` — base64 sidesteps all the
#     nested-quote escaping that `herdr pane run "<cmd>"` would otherwise need.
#   * SpecStory has no Windows CLI (see the package script), so the agent-wrap
#     helper degrades to raw passthrough unless `specstory` is actually on PATH.
#   * Session targeting uses the modern $env:HERDR_SESSION lever (the Unix file
#     predates it and juggles HERDR_SOCKET_PATH by hand).
#
# Untestable off-Windows: herdr installs via irm|iex and is opt-in, so this can
# only be exercised on a Windows box with herdr present. The guard below makes it
# a clean no-op everywhere else (same pattern as 35_yazi.ps1).

# Skip entirely if herdr isn't installed (opt-in tool, not on every host).
if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) { return }

# ── Internal helpers ────────────────────────────────────────────────────────

# Parse herdr JSON output; return $null on empty/invalid instead of throwing.
function _herdr_json {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { $Text | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

# git top-level (forward-slash path even on Windows); empty outside a repo.
# $Target, if given, resolves the root as seen from that directory.
function _herdr_git_root {
    param([string]$Target)
    if ($Target) { git -C $Target rev-parse --show-toplevel 2>$null }
    else         { git rev-parse --show-toplevel 2>$null }
}

# Workspace-label sanitizer: herdr/tmux forbid '.' and ':'; whitespace too.
# '/' is kept (labels like vibe/<repo> use it). Mirrors _sesh_sanitize.
function _herdr_sanitize {
    param([string]$Text)
    $Text -replace '[.:\s]', '-'
}

# Compose the command for one agent pane: specstory-wrap (known providers) then
# fall back to raw. $Mode is auto|never (--no-specstory sets never). On Windows
# there is no specstory CLI, so unless it's actually installed we always return
# the raw agent — future-proofed for `just specstory-build`.
function _herdr_wrap_agent {
    param([string]$Agent, [string]$Mode = 'auto')
    if ($Mode -eq 'never' -or -not (Get-Command specstory -ErrorAction SilentlyContinue)) {
        if ($Agent) { return $Agent } else { return 'claude' }
    }
    switch ($Agent) {
        ''          { return 'specstory run' }
        'specstory' { return 'specstory run' }
        { $_ -in 'claude', 'codex', 'cursor', 'droid', 'gemini' } { return "specstory run $Agent" }
        default     { return $Agent }
    }
}

# UTF-16LE base64 for `pwsh -EncodedCommand` (no spaces/quotes to escape).
function _herdr_encode {
    param([string]$Script)
    [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
}

# Wrap an inner command with the post-exit behavior, emitted as a single pane
# command string. shell = run once then drop to an interactive prompt (pane
# stays); restart = respawn loop; kill = run raw (pane closes on exit). The
# try/finally is the pwsh analog of the Unix `trap '' INT`.
function _herdr_on_exit_wrap {
    param([string]$Inner, [string]$Mode, [string]$Label = 'agent')
    switch ($Mode) {
        'kill' { return $Inner }
        'restart' {
            $body = "while (`$true) { $Inner; Write-Host '[$Label exited - respawning in 1s; Ctrl+C to stop]' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }"
            return "pwsh -NoLogo -EncodedCommand $(_herdr_encode -Script $body)"
        }
        default {
            # shell (also the catch-all): run once, print a re-run hint, stay in a
            # prompt via -NoExit so the pane remains usable.
            $body = "try { $Inner } finally { Write-Host `"``n[$Label exited - back in shell. Re-run with: $Inner]`" -ForegroundColor Yellow }"
            return "pwsh -NoLogo -NoExit -EncodedCommand $(_herdr_encode -Script $body)"
        }
    }
}

# specstory-wrap + on-exit-wrap for one agent pane (label = agent name).
function _herdr_agent_cmd {
    param([string]$Agent, [string]$Mode, [string]$OnExit)
    $inner = _herdr_wrap_agent -Agent $Agent -Mode $Mode
    $label = if ($Agent) { $Agent } else { 'agent' }
    _herdr_on_exit_wrap -Inner $inner -Mode $OnExit -Label $label
}

# workspace_id of an existing workspace labeled $Label (else $null). Idempotency.
function _herdr_ws_by_label {
    param([string]$Label)
    $json = _herdr_json -Text ((herdr workspace list 2>$null) | Out-String)
    if (-not $json) { return $null }
    ($json.result.workspaces | Where-Object { $_.label -eq $Label } | Select-Object -First 1).workspace_id
}

# Create a labeled tab in workspace $Ws (cwd $Cwd) and run $Command in its root
# pane. `tab create` returns the new pane id at .result.root_pane.pane_id.
function _herdr_tool_tab {
    param([string]$Ws, [string]$Cwd, [string]$Label, [string]$Command)
    $json = _herdr_json -Text ((herdr tab create --workspace $Ws --cwd $Cwd --label $Label --no-focus 2>$null) | Out-String)
    $pane = if ($json) { $json.result.root_pane.pane_id }
    if ($pane) { herdr pane run $pane $Command | Out-Null }
}

# Resolve the target session NAME. An explicit -Session must exist and be
# running (validated via `herdr session list --json`); the caller scopes
# $env:HERDR_SESSION around its herdr calls. No arg -> ambient session inside
# herdr, else "default". Returns $null (after printing) on a bad explicit name.
function _herdr_resolve_session {
    param([string]$Want)
    if ($Want) {
        $json = _herdr_json -Text ((herdr session list --json 2>$null) | Out-String)
        $sess = if ($json) { $json.sessions | Where-Object { $_.name -eq $Want } | Select-Object -First 1 }
        if ($null -eq $sess) {
            Write-Error "session '$Want' not found. Start it with: herdr --session $Want"; return $null
        }
        if ($sess.running -ne $true) {
            Write-Error "session '$Want' is not running. Start it with: herdr --session $Want"; return $null
        }
        return $Want
    }
    if ($env:HERDR_SESSION) { return $env:HERDR_SESSION }
    return 'default'
}

# Bring up a client attached to the session when run from OUTSIDE herdr, so the
# just-created workspace is visible. Inside herdr ($env:HERDR_ENV set) the focus
# calls already moved the live client, so this is a no-op.
function _herdr_attach_if_outside {
    param([string]$Session = 'default')
    if ($env:HERDR_ENV) { return }
    if ($Session -eq 'default') { herdr } else { herdr session attach $Session }
}

# ── hvibe: parametric multi-agent pack ──────────────────────────────────────
function herdr-vibe {
    $target = ''; $noAttach = $false; $onExit = 'shell'; $specstory = 'auto'; $sessionArg = ''
    $nAgents = 0; $nAgentsSet = $false; $agentCli = 'claude'; $agentsCsv = ''; $tabPerAgent = $false
    $minWidth = if ($env:HVIBE_MIN_WIDTH) { $env:HVIBE_MIN_WIDTH } else { '80' }
    # Stagger between launches so agents sharing a cold-start resource (e.g.
    # opencode's single SQLite DB) don't race. Set 0 to launch all at once.
    $launchStagger = if ($env:HVIBE_LAUNCH_STAGGER) { $env:HVIBE_LAUNCH_STAGGER } else { '0.25' }
    $positionals = @()

    $i = 0
    while ($i -lt $args.Count) {
        $a = $args[$i]
        if     ($a -eq '-p' -or $a -eq '--path') { $i++; $target = $args[$i] }
        elseif ($a -eq '--on-exit')       { $i++; $onExit = $args[$i] }
        elseif ($a -eq '--agents')        { $i++; $agentsCsv = $args[$i] }
        elseif ($a -eq '--session')       { $i++; $sessionArg = $args[$i] }
        elseif ($a -eq '--min-width')     { $i++; $minWidth = $args[$i] }
        elseif ($a -eq '--tab-per-agent') { $tabPerAgent = $true }
        elseif ($a -eq '--no-specstory')  { $specstory = 'never' }
        elseif ($a -eq '--specstory')     { $specstory = 'auto' }
        elseif ($a -eq '--no-attach')     { $noAttach = $true }
        elseif ($a -eq '-h' -or $a -eq '--help') {
            Write-Host @'
hvibe — herdr multi-agent pack (herdr analog of svibe)

Usage:
  hvibe [-p DIR] [--on-exit MODE] [--no-specstory] [--no-attach]
        [--min-width COLS] [--tab-per-agent] [--session NAME] [N_AGENTS] [AGENT_CLI]
  hvibe [...] --agents A1,A2,A3[,...]

Builds a new herdr workspace `vibe/<repo>`:
  tab "agents" — N agent panes (side-by-side splits; --tab-per-agent = one tab each)
  tab "git"    — lazygit (falls back to `git status`)
  tab "edit"   — nvim
Idempotent: re-running in the same repo focuses the existing workspace.
Requires a git repo (pass -p DIR, or cd into one).

Modes for choosing agents:
  Homogeneous:   hvibe 3 codex                 → 3 panes all codex
  Heterogeneous: hvibe --agents claude,codex   → list length = pane count

Agent wrapping (auto; opt out with --no-specstory) applies only if the specstory
CLI is installed (it has no Windows build yet), else agents run raw.

--on-exit MODE (per pane): shell (default) | kill | restart
--min-width COLS (default $env:HVIBE_MIN_WIDTH, else 80) auto-picks N when omitted:
  N = clamp(term_width / min-width, 1, 6)
$env:HVIBE_LAUNCH_STAGGER (seconds, default 0.25) delays each pane launch.
'@
            return
        }
        elseif ($a -like '-*') { Write-Error "hvibe: unknown flag $a"; return }
        else { $positionals += $a }
        $i++
    }

    if ("$minWidth" -notmatch '^\d+$' -or [int]$minWidth -lt 1) {
        Write-Error "hvibe: --min-width must be a positive integer (got: $minWidth)"; return
    }
    if ("$launchStagger" -notmatch '^\d+(\.\d+)?$') {
        Write-Error "hvibe: HVIBE_LAUNCH_STAGGER must be a non-negative number (got: $launchStagger)"; return
    }
    $minWidth = [int]$minWidth
    $staggerMs = [int]([double]::Parse($launchStagger, [System.Globalization.CultureInfo]::InvariantCulture) * 1000)

    $termWidth = if ($env:COLUMNS) { [int]$env:COLUMNS }
                 elseif ($Host.UI.RawUI.WindowSize.Width) { [int]$Host.UI.RawUI.WindowSize.Width }
                 else { 200 }

    # Build the agents list (CSV and positional paths are mutually exclusive).
    $agents = @()
    if ($agentsCsv) {
        if ($positionals.Count -gt 0) {
            Write-Error "hvibe: cannot combine --agents with positional N_AGENTS/AGENT_CLI."; return
        }
        $agents = @($agentsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($agents.Count -eq 0) { Write-Error "hvibe: --agents list is empty."; return }
    }
    else {
        $pos = @($positionals)
        if ($pos.Count -gt 0 -and $pos[0] -match '^\d+$') {
            $nAgents = [int]$pos[0]; $nAgentsSet = $true
            $pos = if ($pos.Count -gt 1) { $pos[1..($pos.Count - 1)] } else { @() }
        }
        if ($pos.Count -gt 0) { $agentCli = $pos[0] }
        if (-not $nAgentsSet) {
            # Auto-pick N from terminal width; clamp [1,6] (herdr right-splits
            # nest, so many panes get cramped — use --tab-per-agent for more).
            $nAgents = [int]($termWidth / $minWidth)
            if ($nAgents -lt 1) { $nAgents = 1 }
            if ($nAgents -gt 6) { $nAgents = 6 }
        }
        for ($k = 0; $k -lt $nAgents; $k++) { $agents += $agentCli }
    }

    if ($onExit -notin 'shell', 'kill', 'restart') {
        Write-Error "hvibe: --on-exit must be one of: shell, kill, restart (got: $onExit)"; return
    }

    $repoRoot = _herdr_git_root -Target $target
    if (-not $repoRoot) {
        Write-Error "hvibe: not inside a git repo. Pass -p DIR, or cd into a repo."; return
    }

    # Fail-fast: every agent CLI must exist in PATH.
    $missing = @($agents | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -Unique)
    if ($missing.Count -gt 0) {
        Write-Error "hvibe: agent CLI(s) not found in PATH: $($missing -join ' ')"
        Write-Host  "       Available on Windows: claude codex opencode (install as needed)."
        return
    }

    $repo = Split-Path $repoRoot -Leaf
    $label = _herdr_sanitize -Text "vibe/$repo"

    $sessName = _herdr_resolve_session -Want $sessionArg
    if ($null -eq $sessName) { return }
    $hadSession = Test-Path Env:HERDR_SESSION
    $prevSession = $env:HERDR_SESSION
    if ($sessionArg) { $env:HERDR_SESSION = $sessName }
    try {
        # Idempotent: focus an existing workspace instead of duplicating.
        $existing = _herdr_ws_by_label -Label $label
        if ($existing) {
            Write-Host "hvibe: workspace '$label' already exists ($existing) — focusing."
            if (-not $noAttach) {
                herdr workspace focus $existing | Out-Null
                _herdr_attach_if_outside -Session $sessName
            }
            return
        }

        $wsJson = _herdr_json -Text ((herdr workspace create --cwd $repoRoot --label $label --no-focus 2>$null) | Out-String)
        $ws = if ($wsJson) { $wsJson.result.workspace.workspace_id }
        $p0 = if ($wsJson) { $wsJson.result.root_pane.pane_id }
        $t0 = if ($wsJson) { $wsJson.result.root_pane.tab_id }
        if (-not $ws -or -not $p0 -or -not $t0) {
            Write-Error "hvibe: failed to create workspace (is the herdr server running?)."; return
        }

        $firstAgent = $agents[0]
        if ($tabPerAgent) {
            # One tab per agent; the initial tab hosts the first.
            herdr tab rename $t0 $firstAgent | Out-Null
            herdr pane run $p0 (_herdr_agent_cmd -Agent $firstAgent -Mode $specstory -OnExit $onExit) | Out-Null
            if ($agents.Count -gt 1) {
                foreach ($ag in $agents[1..($agents.Count - 1)]) {
                    if ($staggerMs -gt 0) { Start-Sleep -Milliseconds $staggerMs }
                    _herdr_tool_tab -Ws $ws -Cwd $repoRoot -Label $ag -Command (_herdr_agent_cmd -Agent $ag -Mode $specstory -OnExit $onExit)
                }
            }
        }
        else {
            # Side-by-side splits in one "agents" tab. Thread $prev so each new
            # pane splits off the previous → predictable left-to-right columns.
            herdr tab rename $t0 agents | Out-Null
            herdr pane run $p0 (_herdr_agent_cmd -Agent $firstAgent -Mode $specstory -OnExit $onExit) | Out-Null
            # Even columns: herdr has no even-horizontal layout, so set each
            # split's ratio explicitly. --ratio is the fraction KEPT by the pane
            # being split; splitting the rightmost pane on step m of N-1 with
            # 1/(N-m+1) leaves every finalized column at 1/N width. Format with
            # InvariantCulture so a comma-decimal locale never emits "0,5000".
            $nTotal = $agents.Count; $prev = $p0; $m = 1
            if ($agents.Count -gt 1) {
                foreach ($ag in $agents[1..($agents.Count - 1)]) {
                    if ($staggerMs -gt 0) { Start-Sleep -Milliseconds $staggerMs }
                    $ratio = (1.0 / ($nTotal - $m + 1)).ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
                    $sj = _herdr_json -Text ((herdr pane split $prev --direction right --ratio $ratio --cwd $repoRoot --no-focus 2>$null) | Out-String)
                    $np = if ($sj) { $sj.result.pane.pane_id }
                    if ($np) {
                        herdr pane run $np (_herdr_agent_cmd -Agent $ag -Mode $specstory -OnExit $onExit) | Out-Null
                        $prev = $np
                    }
                    $m++
                }
            }
        }

        # git + edit tabs (same on-exit treatment as the agents).
        if (Get-Command lazygit -ErrorAction SilentlyContinue) { $gitInner = 'lazygit' } else { $gitInner = 'git status' }
        $gitLabel = ($gitInner -split ' ')[0]
        _herdr_tool_tab -Ws $ws -Cwd $repoRoot -Label 'git'  -Command (_herdr_on_exit_wrap -Inner $gitInner -Mode $onExit -Label $gitLabel)
        _herdr_tool_tab -Ws $ws -Cwd $repoRoot -Label 'edit' -Command (_herdr_on_exit_wrap -Inner 'nvim' -Mode $onExit -Label 'nvim')

        if (-not $noAttach) {
            herdr workspace focus $ws | Out-Null
            herdr tab focus $t0 | Out-Null
            _herdr_attach_if_outside -Session $sessName
        }
    }
    finally {
        if ($sessionArg) {
            if ($hadSession) { $env:HERDR_SESSION = $prevSession }
            else { Remove-Item Env:HERDR_SESSION -ErrorAction SilentlyContinue }
        }
    }
}

# ── hcode: repo-scoped single-agent layout ──────────────────────────────────
function herdr-code {
    $target = ''; $agent = ''; $noAttach = $false; $onExit = 'shell'; $specstory = 'auto'; $sessionArg = ''

    $i = 0
    while ($i -lt $args.Count) {
        $a = $args[$i]
        if     ($a -eq '-p' -or $a -eq '--path')  { $i++; $target = $args[$i] }
        elseif ($a -eq '-a' -or $a -eq '--agent') { $i++; $agent = $args[$i] }
        elseif ($a -eq '--on-exit')      { $i++; $onExit = $args[$i] }
        elseif ($a -eq '--session')      { $i++; $sessionArg = $args[$i] }
        elseif ($a -eq '--no-specstory') { $specstory = 'never' }
        elseif ($a -eq '--specstory')    { $specstory = 'auto' }
        elseif ($a -eq '--no-attach')    { $noAttach = $true }
        elseif ($a -eq '--agents') {
            Write-Error "hcode: --agents is hvibe-only (hcode is single-agent). For multi-agent: hvibe --agents …"; return
        }
        elseif ($a -eq '-h' -or $a -eq '--help') {
            Write-Host @'
hcode — herdr single-agent coding layout (herdr analog of scode)

Usage: hcode [-p DIR] [-a CLI] [--on-exit MODE] [--no-specstory]
             [--no-attach] [--session NAME] [AGENT]

Builds a new herdr workspace `coding-agent/<repo>`:
  tab "editor"  — nvim (left ~75%) | agent (right ~25%)
  tab "monitor" — btop (or htop / a pwsh process view)
Idempotent per repo; refuses outside a git repo.

Agent wrapping (auto; --no-specstory to opt out) applies only if the specstory
CLI is installed (no Windows build yet), else the agent runs raw.
--on-exit MODE (per pane): shell (default) | kill | restart

  hcode                 # default agent (claude)
  hcode codex           # right pane: codex
  hcode --on-exit kill claude
'@
            return
        }
        elseif ($a -like '-*') { Write-Error "hcode: unknown flag $a"; return }
        else { if (-not $agent) { $agent = $a } }
        $i++
    }

    if ($onExit -notin 'shell', 'kill', 'restart') {
        Write-Error "hcode: --on-exit must be one of: shell, kill, restart (got: $onExit)"; return
    }

    $repoRoot = _herdr_git_root -Target $target
    if (-not $repoRoot) {
        Write-Error "hcode: not inside a git repo. Pass -p DIR, or use hvibe in any dir."; return
    }
    if ($agent -and -not (Get-Command $agent -ErrorAction SilentlyContinue)) {
        Write-Error "hcode: agent CLI '$agent' not found in PATH."; return
    }

    $repo = Split-Path $repoRoot -Leaf
    $label = _herdr_sanitize -Text "coding-agent/$repo"

    $sessName = _herdr_resolve_session -Want $sessionArg
    if ($null -eq $sessName) { return }
    $hadSession = Test-Path Env:HERDR_SESSION
    $prevSession = $env:HERDR_SESSION
    if ($sessionArg) { $env:HERDR_SESSION = $sessName }
    try {
        $existing = _herdr_ws_by_label -Label $label
        if ($existing) {
            Write-Host "hcode: workspace '$label' already exists ($existing) — focusing."
            if (-not $noAttach) {
                herdr workspace focus $existing | Out-Null
                _herdr_attach_if_outside -Session $sessName
            }
            return
        }

        $wsJson = _herdr_json -Text ((herdr workspace create --cwd $repoRoot --label $label --no-focus 2>$null) | Out-String)
        $ws = if ($wsJson) { $wsJson.result.workspace.workspace_id }
        $p0 = if ($wsJson) { $wsJson.result.root_pane.pane_id }
        $t0 = if ($wsJson) { $wsJson.result.root_pane.tab_id }
        if (-not $ws -or -not $p0 -or -not $t0) {
            Write-Error "hcode: failed to create workspace (is the herdr server running?)."; return
        }

        # editor tab: nvim in the initial pane, agent split off right at ~25%.
        # --ratio 0.75 keeps nvim (the split pane) at 75%, agent gets 25%.
        herdr tab rename $t0 editor | Out-Null
        herdr pane run $p0 (_herdr_on_exit_wrap -Inner 'nvim' -Mode $onExit -Label 'nvim') | Out-Null
        $sj = _herdr_json -Text ((herdr pane split $p0 --direction right --ratio 0.75 --cwd $repoRoot --no-focus 2>$null) | Out-String)
        $ap = if ($sj) { $sj.result.pane.pane_id }
        if ($ap) { herdr pane run $ap (_herdr_agent_cmd -Agent $agent -Mode $specstory -OnExit $onExit) | Out-Null }

        # monitor tab: btop → htop → a small pwsh process view (no top on Windows).
        if     (Get-Command btop -ErrorAction SilentlyContinue) { $monInner = 'btop' }
        elseif (Get-Command htop -ErrorAction SilentlyContinue) { $monInner = 'htop' }
        else { $monInner = 'while ($true) { Clear-Host; Get-Process | Sort-Object -Property CPU -Descending | Select-Object -First 25 -Property Id, ProcessName, CPU, WS | Format-Table -AutoSize | Out-Host; Start-Sleep -Seconds 2 }' }
        $monLabel = if ($monInner -like 'while*') { 'monitor' } else { $monInner }
        _herdr_tool_tab -Ws $ws -Cwd $repoRoot -Label 'monitor' -Command (_herdr_on_exit_wrap -Inner $monInner -Mode $onExit -Label $monLabel)

        if (-not $noAttach) {
            herdr workspace focus $ws | Out-Null
            herdr tab focus $t0 | Out-Null
            if ($ap) { herdr pane focus --direction left --pane $ap | Out-Null }
            _herdr_attach_if_outside -Session $sessName
        }
    }
    finally {
        if ($sessionArg) {
            if ($hadSession) { $env:HERDR_SESSION = $prevSession }
            else { Remove-Item Env:HERDR_SESSION -ErrorAction SilentlyContinue }
        }
    }
}

# ── hhere: plain "open a workspace here + attach" ────────────────────────────
function herdr-here {
    $cmd = ''; $target = ''; $noAttach = $false; $sessionArg = ''
    $rest = @()

    $i = 0
    while ($i -lt $args.Count) {
        $a = $args[$i]
        if     ($a -eq '-c' -or $a -eq '--command') { $i++; $cmd = $args[$i] }
        elseif ($a -eq '-p' -or $a -eq '--path')    { $i++; $target = $args[$i] }
        elseif ($a -eq '--session')     { $i++; $sessionArg = $args[$i] }
        elseif ($a -eq '--no-attach')   { $noAttach = $true }
        elseif ($a -eq '-h' -or $a -eq '--help') {
            Write-Host @'
hhere — open a plain herdr workspace here + attach (herdr analog of shere)

Usage: hhere [-p DIR] [-c CMD] [--no-attach] [--session NAME] [CMD...]

Creates a herdr workspace at DIR (default $PWD), focuses it, and — from OUTSIDE
herdr — attaches a client. No git repo required and no agent layout: just a shell
in the root pane. For agent layouts use hcode (single) or hvibe (multi).

  hhere                        # plain shell at $PWD
  hhere npm run dev            # bare args → run as the root-pane command
  hhere -c "npm run dev"       # explicit --command flag
  hhere -p ~/proj              # explicit path
Idempotent: re-running in the same dir focuses the existing workspace.
'@
            return
        }
        elseif ($a -like '-*') { Write-Error "hhere: unknown flag $a"; return }
        else { $rest = $args[$i..($args.Count - 1)]; break }
        $i++
    }
    if ($rest.Count -gt 0 -and -not $cmd) { $cmd = $rest -join ' ' }
    if (-not $target) { $target = $PWD.Path }

    $label = _herdr_sanitize -Text (Split-Path $target -Leaf)

    $sessName = _herdr_resolve_session -Want $sessionArg
    if ($null -eq $sessName) { return }
    $hadSession = Test-Path Env:HERDR_SESSION
    $prevSession = $env:HERDR_SESSION
    if ($sessionArg) { $env:HERDR_SESSION = $sessName }
    try {
        $existing = _herdr_ws_by_label -Label $label
        if ($existing) {
            Write-Host "hhere: workspace '$label' already exists ($existing) — focusing."
            if (-not $noAttach) {
                herdr workspace focus $existing | Out-Null
                _herdr_attach_if_outside -Session $sessName
            }
            return
        }

        $wsJson = _herdr_json -Text ((herdr workspace create --cwd $target --label $label --no-focus 2>$null) | Out-String)
        $ws = if ($wsJson) { $wsJson.result.workspace.workspace_id }
        $p0 = if ($wsJson) { $wsJson.result.root_pane.pane_id }
        if (-not $ws -or -not $p0) {
            Write-Error "hhere: failed to create workspace (is the herdr server running?)."; return
        }

        # Optional command in the root pane (raw — no specstory/on-exit wrapping).
        if ($cmd) { herdr pane run $p0 $cmd | Out-Null }

        if (-not $noAttach) {
            herdr workspace focus $ws | Out-Null
            _herdr_attach_if_outside -Session $sessName
        }
    }
    finally {
        if ($sessionArg) {
            if ($hadSession) { $env:HERDR_SESSION = $prevSession }
            else { Remove-Item Env:HERDR_SESSION -ErrorAction SilentlyContinue }
        }
    }
}

# ── hroot: like hhere but at the git-root ────────────────────────────────────
function herdr-root {
    if ($args.Count -gt 0) {
        if ($args[0] -eq '-h' -or $args[0] -eq '--help') {
            Write-Host @'
hroot — open a plain herdr workspace at the git-root + attach (analog of sroot)

Usage: hroot [-c CMD] [--no-attach] [--session NAME] [CMD...]

Like hhere, but the workspace opens at the current git top-level (falls back to
$PWD outside a repo). All flags except -p/--path pass through to hhere.
'@
            return
        }
        if ($args[0] -eq '-p' -or $args[0] -eq '--path') {
            Write-Error "hroot: -p/--path is not accepted (root is derived from git). Use hhere -p DIR."; return
        }
    }
    $root = _herdr_git_root
    if (-not $root) { $root = $PWD.Path }
    herdr-here -p $root @args
}

# ── Review-pending flag (hmark / hunmark, ⭐) ────────────────────────────────
# Toggle a per-pane "I still need to review this" flag via herdr's custom-status
# metadata — orthogonal to agent state, so peeking into a done pane does NOT
# clear it. Inlined here (the Unix version shells out to a review-mark.sh shared
# with a keybind + tv channel; neither exists in this repo yet). Default pane =
# ambient $env:HERDR_PANE_ID.
function herdr-mark {
    if ($args.Count -gt 0 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
        Write-Host "hmark [PANE_ID] — flag a herdr pane as review-pending (⭐). Default: current pane."; return
    }
    $pane = if ($args.Count -gt 0) { $args[0] } else { $env:HERDR_PANE_ID }
    if (-not $pane) { Write-Error "hmark: no pane id (not inside herdr?). Pass one: hmark w1:p1"; return }
    herdr pane report-metadata $pane --source review --custom-status '⭐ REVIEW' | Out-Null
    Write-Host "review flag set on $pane"
}

function herdr-unmark {
    if ($args.Count -gt 0 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
        Write-Host "hunmark [PANE_ID] — clear a herdr pane's review-pending (⭐) flag. Default: current pane."; return
    }
    $pane = if ($args.Count -gt 0) { $args[0] } else { $env:HERDR_PANE_ID }
    if (-not $pane) { Write-Error "hunmark: no pane id (not inside herdr?). Pass one: hunmark w1:p1"; return }
    herdr pane report-metadata $pane --source review --clear-custom-status | Out-Null
    Write-Host "review flag cleared on $pane"
}

# ── Aliases ─────────────────────────────────────────────────────────────────
Set-Alias -Name hvibe   -Value herdr-vibe   -Scope Global
Set-Alias -Name hcode   -Value herdr-code   -Scope Global
Set-Alias -Name hhere   -Value herdr-here   -Scope Global
Set-Alias -Name hroot   -Value herdr-root   -Scope Global
Set-Alias -Name hmark   -Value herdr-mark   -Scope Global
Set-Alias -Name hunmark -Value herdr-unmark -Scope Global
