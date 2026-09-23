#Requires -Version 7.4
#Requires -PSEdition Core
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Live acceptance requires a disposable GitHub-hosted Windows runner.'
}
$Root = [IO.Path]::GetFullPath($Root)
$expectedHome = Join-Path $Root 'home'
if ([IO.Path]::GetFullPath($HOME) -ne $expectedHome -or $env:SCOOP -ne (Join-Path $Root 'scoop')) {
    throw 'The child process does not have the isolated HOME/SCOOP environment.'
}
$RepoRoot = Split-Path $PSScriptRoot
. (Join-Path $RepoRoot 'scripts/windows-cli-release.ps1')
. (Join-Path $RepoRoot 'scripts/personal-tools.ps1')
$script:Failures = [Collections.Generic.List[string]]::new()
$script:Installs = [Collections.Generic.List[string]]::new()
function Register-Failure($What) { $script:Failures.Add($What) }
function Install-DevCli { Install-WindowsCliRelease -Name dev-cli }
function Scoop-Install([string[]]$Apps) {
    foreach ($app in $Apps) {
        $name = ($app -split '/')[-1]
        if (Test-Path -LiteralPath (Join-Path $env:SCOOP "apps/$name/current/install.json")) { continue }
        $script:Installs.Add($app)
        $output = @(& scoop install $app *>&1)
        $code = $LASTEXITCODE
        $output | Out-Host
        $plain = (($output -join "`n") -replace '\x1b\[[0-?]*[ -/]*[@-~]', '')
        if ($code -ne 0 -or $plain -match '(?:^|\s)ERROR[ :!]') { throw "Scoop install failed: $app" }
    }
}
# No implicit migration: explicit false overrides both legacy switches.
Install-SelectedPersonalTools -Data @{installPersonalTools=$false;installHerdr=$true;installTranslate=$true}
if ($script:Installs.Count -or (Test-Path (Join-Path $HOME '.local/bin/dev-cli.exe'))) { throw 'Explicit false installed a tool' }
Install-SelectedPersonalTools -Data @{installPersonalTools=$true}
if ($script:Failures.Count) { throw "Installer failures: $($script:Failures -join ', ')" }
$records = foreach ($tool in Get-PersonalTools) {
    $owner = Get-PersonalToolOwner -Tool $tool
    if ($owner.Kind -ne $tool.Manager) { throw "Wrong installation owner: $($tool.Id): $($owner.Kind)" }
    $version = Get-PersonalToolVersion -Tool $tool -Path $owner.Path
    $help = @(& $owner.Path --help 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $help) { throw "Help failed: $($tool.Id)" }
    $completion = @(& $owner.Path completion powershell 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $completion -notmatch 'Register-ArgumentCompleter') { throw "Completion failed: $($tool.Id)" }
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseInput($completion,[ref]$null,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "PowerShell completion parse failed: $($tool.Id)" }
    if ($tool.Id -in @('lazyclash','lazypueue','lazychezmoi','lazymlflow')) {
        $check = @(& $owner.Path upgrade --check --json) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Upgrade check failed: $($tool.Id)" }
        $report = $check | ConvertFrom-Json
        if ($report.manager -ne 'scoop' -or $report.package -ne $tool.Id -or -not $report.can_upgrade) { throw "Upgrade owner mismatch: $($tool.Id)" }
    }
    [pscustomobject]@{tool=$tool.Id;owner=$owner.Kind;version=$version;help='passed';completion='passed';sha256=(Get-FileHash $owner.Path -Algorithm SHA256).Hash}
}
$before = @($records | ForEach-Object {$_.sha256})
$installCount = $script:Installs.Count
Install-SelectedPersonalTools -Data @{installPersonalTools=$true}
if ($script:Failures.Count -or $script:Installs.Count -ne $installCount) { throw 'Reapply reinstalled a package or failed' }
$after = @(Get-PersonalTools | ForEach-Object { (Get-FileHash (Get-PersonalToolOwner -Tool $_).Path -Algorithm SHA256).Hash })
if (Compare-Object $before $after) { throw 'Install-only reapply changed binaries' }
Update-SelectedPersonalTools -Data @{installPersonalTools=$true} -WhatIf | Out-Host
$records | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'personal-tools-live.json') -Encoding utf8
Write-Host 'PASS: six tools, verified owners, native version/help/completion, Scoop check, false gate and install-only reapply'
