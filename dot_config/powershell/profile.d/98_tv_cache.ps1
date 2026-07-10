# 98_tv_cache.ps1 — precompute the alias/function list for the `tv aliases`
# channel. tv runs channel commands in a fresh shell without our $PROFILE, so we
# snapshot the current session's aliases + functions here (runs late, after the
# other fragments have defined theirs). No-op if tv isn't installed.
if (Get-Command tv -ErrorAction SilentlyContinue) {
    $dir = Join-Path $HOME '.cache/tv'
    $out = Join-Path $dir 'aliases.txt'
    # The alias/function set is stable across shells (it's defined by this same
    # $PROFILE), so recomputing it on every start is wasted work. Refresh at most
    # once a day; delete the file to force an immediate rebuild after adding aliases.
    $stale = (-not (Test-Path -LiteralPath $out)) -or
             ((Get-Item -LiteralPath $out).LastWriteTime -lt (Get-Date).AddDays(-1))
    if ($stale) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lines = [System.Collections.Generic.List[string]]::new()
        Get-Alias | Sort-Object Name | ForEach-Object { $lines.Add("$($_.Name) -> $($_.Definition)") }
        Get-Command -CommandType Function -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Source -or $_.Source -eq 'Copilot' } |
            Sort-Object Name | ForEach-Object { $lines.Add("$($_.Name) (function)") }
        $lines | Set-Content -Path $out -Encoding utf8
    }
}
