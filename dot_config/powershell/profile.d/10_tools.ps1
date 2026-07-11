# 10_tools.ps1 — activate CLI tools. Each block no-ops if the tool is absent,
# so a partial install (or the minimal role) never errors the prompt.
#
# Tool `init` output (starship/zoxide/atuin/direnv/tv) is cached under
# $XDG_CACHE_HOME/pwsh-init so a warm shell dot-sources a static file instead of
# cold-spawning the binary on every start — the dominant pwsh-startup cost on a
# fresh box (each spawn is a process launch + Defender scan). The cache
# auto-regenerates when the tool's exe timestamp changes (e.g. a scoop upgrade);
# delete ~/.cache/pwsh-init to force a rebuild.
function Import-CachedInit {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][scriptblock]$Generate
    )
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return }
    $cacheDir  = Join-Path $env:XDG_CACHE_HOME 'pwsh-init'
    $cacheFile = Join-Path $cacheDir "$Name.ps1"
    $stampFile = "$cacheFile.stamp"
    try { $stamp = (Get-Item -LiteralPath $cmd.Source).LastWriteTimeUtc.Ticks.ToString() } catch { $stamp = '' }
    $fresh = (Test-Path -LiteralPath $cacheFile) -and (Test-Path -LiteralPath $stampFile) -and
             ((Get-Content -LiteralPath $stampFile -Raw -ErrorAction SilentlyContinue).Trim() -eq $stamp)
    if (-not $fresh) {
        try {
            $out = & $Generate | Out-String
            if (-not $out.Trim()) { return }   # tool errored / empty output — retry next start
            if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
            Set-Content -LiteralPath $cacheFile -Value $out   -Encoding utf8
            Set-Content -LiteralPath $stampFile -Value $stamp -Encoding utf8
        } catch { return }
    }
    try { . $cacheFile } catch { Write-Warning "profile: cached init '$Name' failed: $_" }
}

# starship prompt
Import-CachedInit -Name 'starship' -Exe 'starship' -Generate { starship init powershell }

# zoxide — smarter cd (rebinds `cd` to `z`)
Import-CachedInit -Name 'zoxide' -Exe 'zoxide' -Generate { zoxide init powershell --cmd cd }

# Runtimes (node/bun/go/rust/ruby) are native via scoop and Python via uv — no
# mise on Windows (its activate/shims are unreliable here). See docs/rationale.

# atuin — SQLite shell history with fuzzy search (Ctrl+R)
Import-CachedInit -Name 'atuin' -Exe 'atuin' -Generate { atuin init powershell }

# fzf — fuzzy finder + PSFzf key bindings (Ctrl+t files, Ctrl+r history)
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    $env:FZF_DEFAULT_OPTS = '--height 40% --layout=reverse --border'
    if (Get-Command fd -ErrorAction SilentlyContinue) {
        $env:FZF_DEFAULT_COMMAND = 'fd --hidden --strip-cwd-prefix --exclude .git'
    }
    # Import directly — a `Get-Module -ListAvailable` guard scans all of
    # PSModulePath (slow, esp. under OneDrive-hydrated Documents\PowerShell\Modules).
    # `Get-Module -Name` checks only loaded modules, so it's cheap.
    # The Ctrl+t / Ctrl+r chords are bound in 90_psreadline.ps1 — they must be
    # applied AFTER `Set-PSReadLineOption -EditMode`, which resets key handlers.
    Import-Module PSFzf -ErrorAction SilentlyContinue
}

# direnv — per-directory environments
Import-CachedInit -Name 'direnv' -Exe 'direnv' -Generate { direnv hook pwsh }

# television (tv) — fuzzy picker shell integration. tv 0.15+ renamed the shell
# value `powershell` -> `power-shell`; older builds used `powershell`. Try the
# new spelling first, fall back, and only cache non-empty output so a version
# mismatch never errors the prompt.
Import-CachedInit -Name 'tv' -Exe 'tv' -Generate {
    $o = tv init power-shell 2>$null | Out-String
    if (-not $o.Trim()) { $o = tv init powershell 2>$null | Out-String }
    $o
}
