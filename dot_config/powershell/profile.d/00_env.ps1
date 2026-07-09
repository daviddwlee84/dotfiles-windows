# 00_env.ps1 — environment variables & PATH. Sourced first by $PROFILE.

# UTF-8 console I/O. Without this, native tools that emit UTF-8 (git, winget's
# localized output, …) render as mojibake on legacy-codepage systems (e.g. GBK /
# cp936 on zh-* Windows). Guarded so a redirected/headless host can't error the
# rest of this fragment.
try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch { $null = $_ }

# XDG-style base dirs. Several tools honor these on Windows (starship, atuin,
# zoxide state, our own copilot module) so we set them for a tidy $HOME.
if (-not $env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME = Join-Path $HOME '.config' }
if (-not $env:XDG_DATA_HOME)   { $env:XDG_DATA_HOME   = Join-Path $HOME '.local/share' }
if (-not $env:XDG_STATE_HOME)  { $env:XDG_STATE_HOME  = Join-Path $HOME '.local/state' }
if (-not $env:XDG_CACHE_HOME)  { $env:XDG_CACHE_HOME  = Join-Path $HOME '.cache' }

$env:STARSHIP_CONFIG = Join-Path $env:XDG_CONFIG_HOME 'starship.toml'
# yazi looks in %APPDATA%\yazi\config by default; keep it XDG-consistent instead.
$env:YAZI_CONFIG_HOME = Join-Path $env:XDG_CONFIG_HOME 'yazi'

# uv-managed Python: `uv python install --default` drops python/python3 here.
# ~/.local/bin is prepended to PATH below, so they win over the Windows Store
# `python.exe` app-execution-alias.
$env:UV_PYTHON_BIN_DIR = Join-Path $HOME '.local/bin'

# Default editor
if (Get-Command nvim -ErrorAction SilentlyContinue) { $env:EDITOR = 'nvim' }

# Prepend user bin dirs to PATH, idempotently. scoop already adds its shims to
# the user PATH, but a fresh session inside chezmoi apply may not have it yet.
# mise shims expose the globally-pinned runtimes (node/bun/uv/…) reliably — the
# `mise activate` prompt-hook doesn't land global tools on PATH on Windows. mise's
# shims dir varies (XDG_DATA_HOME vs %LOCALAPPDATA%), so include both; Test-Path
# keeps only the one that exists.
$UserPaths = @(
    (Join-Path $HOME '.local/bin'),
    (Join-Path $HOME 'scoop/shims'),
    (Join-Path $env:XDG_DATA_HOME 'mise/shims'),
    (Join-Path $env:LOCALAPPDATA 'mise/shims')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$SepPaths = $env:PATH -split ';'
foreach ($p in $UserPaths) {
    if ($SepPaths -notcontains $p) { $env:PATH = "$p;$env:PATH" }
}
