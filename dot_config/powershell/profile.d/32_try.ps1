# 32_try.ps1 — try (tobi/try, gem `try-cli`): ephemeral dated workspaces, for pwsh.
#
# The bareword command is **`tri`**, not `try`: `try` is a PowerShell keyword
# (try/catch), so `try foo` is a parse error and can never be a command. (`& try`
# still works via the call operator, so a thin `try` wrapper is defined too.)
#
# try-cli's own `try init` pwsh wrapper is unusable here: besides the keyword, its
# runtime `exec` output is POSIX shell (`mkdir -p`, ` && \` line-continuations,
# `/usr/bin/env sh -c`, `test -d`/`rm -rf`) which pwsh's Invoke-Expression can't
# eval. So we run `ruby try.rb exec` ourselves and TRANSLATE its POSIX stdout into
# native pwsh executed in the LIVE session (so the final `cd` moves this shell).
# See pitfalls/try-cli-pwsh-support-emits-posix.md.

# ── env (mirrors unix dot_config/zsh/tools/32_try.zsh:7-9) ───────────────────
if (-not $env:TRY_PATH) { $env:TRY_PATH = Join-Path $HOME 'src/tries' }
$env:TRY_PATH = [System.IO.Path]::GetFullPath($env:TRY_PATH)   # absolutize always
try { $env:TRY_PATH = (Resolve-Path -LiteralPath $env:TRY_PATH -ErrorAction Stop).Path } catch { $null = $_ }  # realpath if it exists
if (-not $env:TRY_PROJECTS) { $env:TRY_PROJECTS = Split-Path -Parent $env:TRY_PATH }

# ── POSIX → pwsh translator (defined unconditionally so it stays unit-testable
#    on a host without ruby; only the `tri` command further down needs try-cli) ─
# Tokenize one POSIX command line back to raw args. Handles '…' and "…" quoting;
# try's q() escape for an embedded quote is '"'"' (close-'/"'"/open-'), which this
# round-trips because adjacent quoted+bare segments concatenate into one token.
function _Try-ParsePosixArgs {
    param([string]$Line)
    $tokens = [System.Collections.Generic.List[string]]::new()
    $cur = [System.Text.StringBuilder]::new()
    $has = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq "'") {
            $has = $true; $i++
            while ($i -lt $Line.Length -and $Line[$i] -ne "'") { [void]$cur.Append($Line[$i]); $i++ }
        } elseif ($c -eq '"') {
            $has = $true; $i++
            while ($i -lt $Line.Length -and $Line[$i] -ne '"') { [void]$cur.Append($Line[$i]); $i++ }
        } elseif ($c -eq ' ' -or $c -eq "`t") {
            if ($has) { $tokens.Add($cur.ToString()); [void]$cur.Clear(); $has = $false }
        } else {
            $has = $true; [void]$cur.Append($c)
        }
    }
    if ($has) { $tokens.Add($cur.ToString()) }
    ,$tokens.ToArray()
}

# Translate + run ONE command element. Returns $false only for correctness-gating
# failures (mkdir / git clone) so a bad step aborts the chain before the final cd;
# best-effort and unknown verbs return $true so the trailing `cd` still lands.
function _Try-InvokeOne {
    param([string]$Command)

    # worktree creator: /usr/bin/env sh -c '…worktree add --detach 'P'…'
    if ($Command -match '/usr/bin/env sh -c') {
        $target = if ($Command -match "worktree add --detach '([^']*)'") { $Matches[1] } else { $null }
        if ($target) {
            $root = if ($Command -match "git -C '([^']*)' rev-parse") { & git -C $Matches[1] rev-parse --show-toplevel 2>$null }
                    else { & git rev-parse --show-toplevel 2>$null }
            if ($root) { & git -C $root worktree add --detach $target *> $null }   # POSIX `|| true`: non-fatal
        } else { Write-Warning "try: could not parse worktree target: $Command" }
        return $true
    }

    # delete restore trailer: cd 'D' 2>/dev/null || cd '…'  (also 1.7.1 subshell/"$HOME" form)
    if ($Command -match '2>/dev/null\s*\|\|\s*cd') {
        $cands = [regex]::Matches($Command, "cd '([^']*)'") | ForEach-Object { $_.Groups[1].Value }
        $dest = @($cands) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $dest) { $dest = $HOME }
        Set-Location -LiteralPath $dest
        return $true
    }

    # delete element (inline &&, single element): test -d 'X' && rm -rf 'X'
    if ($Command -match '^\s*test -d ') {
        $p = (_Try-ParsePosixArgs (($Command -split ' && ', 2)[0]))[-1]
        if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        return $true
    }

    $t = _Try-ParsePosixArgs $Command
    if ($t.Count -eq 0) { return $true }
    switch ($t[0]) {
        'cd'    { Set-Location -LiteralPath $t[-1]; return $? }
        'mkdir' { New-Item -ItemType Directory -Force -Path $t[-1] | Out-Null; return $? }
        'echo'  { Write-Host (($t | Select-Object -Skip 1) -join ' '); return $true }
        'touch' {
            $p = $t[-1]   # try uses the dir mtime for MRU ordering in its selector
            if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTime = Get-Date }
            else { New-Item -ItemType File -Force -Path $p | Out-Null }
            return $true
        }
        'git'   { & git @($t[1..($t.Count - 1)]); return ($LASTEXITCODE -eq 0) }   # clone / worktree move
        'mv'    { Move-Item -LiteralPath $t[-2] -Destination $t[-1] -Force; return $? }
        'rm'    { $p = $t[-1]; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }; return $true }
        'ln'    {   # ln -s TARGET LINK (graduate); needs Developer Mode/admin on Windows
            try { New-Item -ItemType SymbolicLink -Path $t[-1] -Target $t[-2] -Force -ErrorAction Stop | Out-Null }
            catch { Write-Warning "try: symlink skipped (needs Developer Mode/admin): $($t[-1])" }
            return $true
        }
        default { Write-Warning "try: unhandled command, skipped: $Command"; return $true }
    }
}

# Split try's emit-script into logical commands and run them with `&&` semantics.
function _Try-InvokeEmitted {
    param([string]$Emitted)
    $body = (($Emitted -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if (-not $body.Trim()) { return }
    # Split ONLY on the real element separator " && \"+newline+indent, so the
    # inline " && " inside `test -d 'X' && rm -rf 'X'` stays one element.
    foreach ($el in ($body -split ' && \\\r?\n[ \t]*')) {
        $cmd = $el.Trim()
        if (-not $cmd) { continue }
        if (-not (_Try-InvokeOne -Command $cmd)) { break }
    }
}

# ── guard: opt-in tool. No ruby → define no command (helpers above are inert). ─
if (-not (Get-Command ruby -ErrorAction SilentlyContinue)) { return }

# ── resolve + cache the try.rb path (mtime-invalidated, like 98_tv_cache.ps1) ─
# The `ruby -e Gem::Specification…` lookup is a ~30-60ms cold start; cache it and
# only re-resolve when the ruby binary is newer (a mise/scoop ruby upgrade). A
# gem-only `gem update try-cli` that keeps the same ruby won't bump it — delete
# the cache file to force a rebuild.
$env:__TRY_SCRIPT = $null
$cacheRoot = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
$cacheFile = Join-Path $cacheRoot 'pwsh/try_script.txt'
$rubyExe   = (Get-Command ruby).Source
$fresh = (Test-Path -LiteralPath $cacheFile) -and
         ((Get-Item -LiteralPath $cacheFile).LastWriteTime -ge (Get-Item -LiteralPath $rubyExe).LastWriteTime)
if ($fresh) { $env:__TRY_SCRIPT = (Get-Content -LiteralPath $cacheFile -Raw).Trim() }
if (-not $env:__TRY_SCRIPT -or -not (Test-Path -LiteralPath $env:__TRY_SCRIPT)) {
    $resolved = & ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir, 'try.rb')" 2>$null |
                Select-Object -First 1
    if ($resolved -and (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cacheFile) | Out-Null
        Set-Content -LiteralPath $cacheFile -Value $resolved -Encoding utf8
        $env:__TRY_SCRIPT = $resolved
    }
}
if (-not $env:__TRY_SCRIPT) { return }   # try-cli gem not installed → inert

# ── the command: `tri` (bareword) + `try` (only reachable as `& try`) ─────────
function tri {
    if (-not $env:__TRY_SCRIPT) { Write-Error 'tri: try-cli not resolved'; return }
    # Passthrough non-exec subcommands (don't translate their output).
    if ($args.Count -ge 1 -and $args[0] -in @('--help', '-h', 'help', '--version', 'version', 'init')) {
        & ruby $env:__TRY_SCRIPT @args
        return
    }
    # Run try; keep the child's stderr on the console (the selector TUI), capture
    # stdout. Shield the expected non-zero "Cancelled." exit from a Stop policy.
    $havePref = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($havePref) { $prev = $PSNativeCommandUseErrorActionPreference; $PSNativeCommandUseErrorActionPreference = $false }
    try {
        $out  = & ruby $env:__TRY_SCRIPT exec --path $env:TRY_PATH @args
        $code = $LASTEXITCODE
    } finally {
        if ($havePref) { $PSNativeCommandUseErrorActionPreference = $prev }
    }
    $text = ($out -join "`n")
    # Only translate a genuine emit-script (exit 0 + the stable marker). Anything
    # else (Cancelled., errors) is a human message → print verbatim.
    if ($code -eq 0 -and $text -match "you didn't launch try from an alias") {
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { _Try-InvokeEmitted -Emitted $text } finally { $ErrorActionPreference = $eap }
    } elseif ($text.Trim()) {
        $text -split "`r?`n" | ForEach-Object { Write-Host $_ }
    }
}
# `try` is a keyword, so bareword `try …` can't parse — but `& try …` can. Define
# it via Set-Item so the linter doesn't flag the reserved word (intentional here).
Set-Item -Path function:global:try -Value { tri @args }
