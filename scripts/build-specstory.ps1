#Requires -Version 7
# build-specstory.ps1 — EXPERIMENTAL: build the SpecStory Windows-native CLI
# from the still-unmerged PR #191 and drop specstory.exe into ~/.local/bin.
#
# SpecStory ships no native-Windows CLI release yet; Windows/WSL/SSH support
# lives in getspecstory PR #191 (open, mergeable=false at time of writing).
# Treat the result as EXPERIMENTAL — behaviour may change or break until the PR
# lands. Tracking + revisit criteria: backlog/specstory-windows-native-cli.md
#
# Needs: git + go (Go toolchain). Enable the "Extra runtimes" init toggle or run
# `scoop install go` first. Run via: just specstory-build
[CmdletBinding()]
param(
    [string]$Pr  = '191',
    [string]$Ref = 'pull/191/head'
)
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }

foreach ($t in 'git', 'go') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        throw "$t not found. Install it first (go: enable Extra runtimes, or run: scoop install go)."
    }
}

$cache = Join-Path $HOME '.cache\specstory-build'
$repo  = Join-Path $cache 'getspecstory'
$bin   = Join-Path $HOME '.local\bin'
New-Item -ItemType Directory -Force -Path $cache, $bin | Out-Null

if (-not (Test-Path (Join-Path $repo '.git'))) {
    Info 'cloning specstoryai/getspecstory'
    git clone --filter=blob:none https://github.com/specstoryai/getspecstory.git $repo
}

Push-Location $repo
try {
    Info "fetching PR #$Pr"
    git fetch origin "${Ref}:pr-$Pr" --force
    git checkout --force "pr-$Pr"

    $out = Join-Path $bin 'specstory.exe'
    Push-Location (Join-Path $repo 'specstory-cli')
    try {
        Info "go build -> $out"
        go build -o $out .
    } finally { Pop-Location }

    Info "built: $out"
    & $out --help | Select-Object -First 5
    Write-Host "`nExperimental specstory.exe is in ~/.local/bin (already on PATH). Open a new pwsh and run: specstory --help" -ForegroundColor Green
} finally { Pop-Location }
