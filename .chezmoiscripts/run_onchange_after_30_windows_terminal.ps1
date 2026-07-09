#Requires -Version 7
# run_onchange_after_30_windows_terminal.ps1 — set Windows Terminal's shared
# profile defaults (font, color, opacity) without touching individual profiles.
# No-op if WT isn't installed / hasn't created its settings.json yet.

$ErrorActionPreference = 'Continue'   # best-effort; never abort the apply

$candidates = @()
$candidates += Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal*\LocalState\settings.json" -ErrorAction SilentlyContinue | ForEach-Object FullName
$candidates += "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
$path = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $path) { Write-Host 'Windows Terminal settings.json not found — launch WT once, then re-apply.'; return }

$raw = Get-Content -Raw $path

# Back up the pre-merge settings.json ONCE before we rewrite it. This merge is
# non-destructive (only profiles.defaults + defaultProfile change; your profile
# list / schemes / keybindings are preserved), but ConvertTo-Json reformats the
# file and strips comments, so keep an escape hatch. The run_once_before backup
# doesn't cover this package-versioned %LOCALAPPDATA% path.
$bak = Join-Path (Join-Path $HOME '.dotfiles-backup') 'windows-terminal-settings.json.bak'
if (-not (Test-Path -LiteralPath $bak)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $bak -Parent) | Out-Null
    Copy-Item -LiteralPath $path -Destination $bak -Force -ErrorAction SilentlyContinue
    Write-Host "backed up Windows Terminal settings -> $bak"
}

$raw = [regex]::Replace($raw, '(?m)^\s*//.*$', '')   # drop whole-line comments
try { $s = $raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "could not parse $path — skipping"; return }

if (-not $s.ContainsKey('profiles')) { $s['profiles'] = @{} }
if ($s.profiles -isnot [hashtable]) { $s['profiles'] = @{ list = $s.profiles } }
if (-not $s.profiles.ContainsKey('defaults')) { $s.profiles['defaults'] = @{} }

$s.profiles.defaults['font'] = @{ face = 'Hack Nerd Font Mono'; size = 11 }
$s.profiles.defaults['colorScheme'] = 'One Half Dark'
$s.profiles.defaults['opacity'] = 90
$s.profiles.defaults['useAcrylic'] = $true
$s.profiles.defaults['cursorShape'] = 'filledBox'
$s.profiles.defaults['antialiasingMode'] = 'grayscale'
$s.profiles.defaults['padding'] = '8'

# Prefer PowerShell 7 as the default profile when a matching profile exists.
if ($s.profiles.ContainsKey('list')) {
    $pwshProfile = @($s.profiles.list) |
        Where-Object { ($_.commandline -match 'pwsh') -or ($_.name -eq 'PowerShell') } |
        Select-Object -First 1
    if ($pwshProfile -and $pwshProfile.guid) { $s['defaultProfile'] = $pwshProfile.guid }
}

$s | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding utf8
Write-Host "Windows Terminal defaults updated -> $path"
