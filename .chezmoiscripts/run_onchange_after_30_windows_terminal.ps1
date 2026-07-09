#Requires -Version 7
# run_onchange_after_30_windows_terminal.ps1 — set Windows Terminal's shared
# profile defaults (font, color, opacity) without touching individual profiles.
# No-op if WT isn't installed / hasn't created its settings.json yet.

$ErrorActionPreference = 'Stop'

$candidates = @()
$candidates += Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal*\LocalState\settings.json" -ErrorAction SilentlyContinue | ForEach-Object FullName
$candidates += "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
$path = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $path) { Write-Host 'Windows Terminal settings.json not found — launch WT once, then re-apply.'; return }

$raw = Get-Content -Raw $path
$raw = [regex]::Replace($raw, '(?m)^\s*//.*$', '')   # drop whole-line comments
try { $s = $raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "could not parse $path — skipping"; return }

if (-not $s.ContainsKey('profiles')) { $s['profiles'] = @{} }
if ($s.profiles -isnot [hashtable]) { $s['profiles'] = @{ list = $s.profiles } }
if (-not $s.profiles.ContainsKey('defaults')) { $s.profiles['defaults'] = @{} }

$s.profiles.defaults['font'] = @{ face = 'Hack Nerd Font Mono'; size = 11 }
$s.profiles.defaults['colorScheme'] = 'Campbell'
$s.profiles.defaults['opacity'] = 90
$s.profiles.defaults['useAcrylic'] = $true

$s | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding utf8
Write-Host "Windows Terminal defaults updated -> $path"
