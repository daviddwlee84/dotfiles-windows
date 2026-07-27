# ~/.config/herdr/url-pick.ps1
# Source: dot_config/herdr/url-pick.ps1 (managed by chezmoi)
#
# herdr analog of tmux's `prefix + u` (joshmedeski/tmux-fzf-url). PowerShell port
# of the parent repo's dot_config/herdr/executable_url-pick.sh. Reads a herdr
# pane's text, extracts every URL-like token (same rewrite rules as tmux-fzf-url:
# http(s)/ftp/file, bare www., IPv4[:port], git@ SSH remotes, quoted owner/repo,
# npm imports), fuzzy-picks with fzf (multi-select), then opens each choice.
#
# The unix version shells out to this repo's `x open` (wslview / open / xdg-open);
# the Windows equivalent is Start-Process, which hands the URL to the registered
# shell handler (default browser).
#
# Usage:
#   url-pick.ps1 [PANE_ID] [--source visible|recent]
# --source defaults to visible (tmux-fzf-url's on-screen scope); recent scans the
# full retained scrollback.
#
# Consumer: the prefix+u keybind.

param([Parameter(ValueFromRemainingArguments)] [string[]] $Argument)

. (Join-Path $PSScriptRoot '_common.ps1')

function Show-Usage {
    Write-Host 'usage: url-pick.ps1 [PANE_ID] [--source visible|recent]'
    exit 64
}

if (-not (Test-HerdrPresent)) { exit 1 }
if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Show-HerdrNotice 'url-pick: fzf is required (scoop install fzf)'; exit 1
}

$argv = @($Argument | Where-Object { $null -ne $_ })
$paneArg = ''
$source = 'visible'
for ($i = 0; $i -lt $argv.Count; $i++) {
    switch -Regex ($argv[$i]) {
        '^--source$' { $source = $argv[++$i] }
        '^--source=' { $source = $argv[$i] -replace '^--source=', '' }
        '^(-h|--help)$' { Show-Usage }
        '^-' { Show-Usage }
        default { if (-not $paneArg) { $paneArg = $argv[$i] } else { Show-Usage } }
    }
}
if ($source -notin 'visible', 'recent', 'recent-unwrapped') {
    Write-Host 'url-pick: --source must be visible|recent'; exit 64
}

$pane = Resolve-HerdrPane -PaneId $paneArg
if (-not $pane) { Show-HerdrNotice 'url-pick: could not determine a pane id'; exit 1 }

$content = Get-HerdrPaneText -PaneId $pane -Source $source
if ($null -eq $content) { Show-HerdrNotice "url-pick: failed to read pane $pane"; exit 1 }

# Extraction — same passes/rewrites as tmux-fzf-url's fzf-url.sh, as .NET regex.
$items = [System.Collections.Generic.List[string]]::new()

foreach ($m in [regex]::Matches($content, '(https?|ftp|file):/?//[-A-Za-z0-9+&@#/%?=~_|!:,.;]*[-A-Za-z0-9+&@#/%=~_|]')) {
    $items.Add($m.Value)
}
foreach ($m in [regex]::Matches($content, '(?<!//)\bwww\.[a-zA-Z](-?[a-zA-Z0-9])+\.[a-zA-Z]{2,}(/\S+)*')) {
    $items.Add("http://$($m.Value)")
}
foreach ($m in [regex]::Matches($content, '\b[0-9]{1,3}(\.[0-9]{1,3}){3}(:[0-9]{1,5})?(/\S+)*')) {
    $items.Add("http://$($m.Value)")
}
# git@host:owner/repo(.git) -> https://host/owner/repo
foreach ($m in [regex]::Matches($content, '(ssh://)?git@\S+')) {
    $rewritten = $m.Value -replace '^(ssh://)?git@', '' -replace ':', '/'
    $items.Add("https://$rewritten")
}
foreach ($m in [regex]::Matches($content, '[''"]([A-Za-z0-9_-]+/[.A-Za-z0-9_-]+)[''"]')) {
    $items.Add("https://github.com/$($m.Groups[1].Value)")
}
foreach ($m in [regex]::Matches($content, 'import\s+[^"'';]*["'']([^.][^"'';]*)["'']')) {
    $items.Add("https://npmjs.com/package/$($m.Groups[1].Value)")
}

$urls = @($items | Where-Object { $_ } | Sort-Object -Unique)

if ($urls.Count -eq 0) {
    Show-HerdrNotice "url-pick: no URLs found in pane $pane ($source)"
    exit 0
}

# fzf multi-select; Esc / no match -> clean no-op.
$chosen = $urls | fzf --multi --prompt='url> ' --height=100% --border --no-sort
if ($LASTEXITCODE -ne 0 -or -not $chosen) { exit 0 }

foreach ($url in @($chosen)) {
    if (-not $url) { continue }
    try { Start-Process $url | Out-Null }
    catch { Write-Host "url-pick: could not open $url ($_)" -ForegroundColor Yellow }
}
