#Requires -Version 7.4
#Requires -PSEdition Core
# Read-only branch containment report for Lazygit. This intentionally does not
# fetch: the report describes the remote-tracking refs currently on disk.
[CmdletBinding()]
param(
    [ValidateSet('git', 'pr')]
    [string]$Mode = 'git',
    [string]$SelectedBranch = ''
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $output = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output
}

function Test-GitRef {
    param([string]$Ref)
    & git show-ref --verify --quiet $Ref
    return $LASTEXITCODE -eq 0
}

function Get-RemoteBranchName {
    param([string]$Ref)
    $parts = $Ref -split '/', 2
    if ($parts.Count -eq 2) { return $parts[1] }
    return $Ref
}

function Get-AheadBehind {
    param([string]$Left, [string]$Right)
    $value = Invoke-Git rev-list --left-right --count "$Left...$Right"
    if (-not $value) { return @('?', '?') }
    return ([string]$value).Trim() -split '\s+'
}

function Get-UpstreamState {
    param([string]$Upstream, [string]$TrackShort, [string]$Track)
    if (-not $Upstream) { return '-' }
    if ($Track -match '\[gone\]') { return 'gone' }
    if ($TrackShort -eq '=') { return '=' }
    $aheadMatch = [regex]::Match($Track, 'ahead (\d+)')
    $behindMatch = [regex]::Match($Track, 'behind (\d+)')
    $ahead = if ($aheadMatch.Success) { $aheadMatch.Groups[1].Value } else { '0' }
    $behind = if ($behindMatch.Success) { $behindMatch.Groups[1].Value } else { '0' }
    if ($behind -eq '0') { return "up$ahead" }
    if ($ahead -eq '0') { return "down$behind" }
    return "down$behind/up$ahead"
}

& git rev-parse --git-dir *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Output 'Branch insights: not inside a Git repository.'
    exit 0
}

$baseName = ''
$localBase = ''
$remoteBase = ''
$baseOverride = [string](Invoke-Git config --get lazygit.branchBase)
$baseOverride = $baseOverride.Trim()

if ($baseOverride) {
    if ($baseOverride.StartsWith('refs/heads/')) {
        $baseName = $baseOverride.Substring('refs/heads/'.Length)
    } elseif ($baseOverride.StartsWith('refs/remotes/')) {
        $remoteBase = $baseOverride.Substring('refs/remotes/'.Length)
        $baseName = Get-RemoteBranchName $remoteBase
    } elseif (Test-GitRef "refs/heads/$baseOverride") {
        $baseName = $baseOverride
    } elseif (Test-GitRef "refs/remotes/$baseOverride") {
        $remoteBase = $baseOverride
        $baseName = Get-RemoteBranchName $remoteBase
    } else {
        $baseName = $baseOverride
    }
}

if (-not $baseName) {
    $remoteHead = [string](Invoke-Git symbolic-ref --quiet --short refs/remotes/origin/HEAD)
    $remoteHead = $remoteHead.Trim()
    if ($remoteHead) {
        $remoteBase = $remoteHead
        $baseName = Get-RemoteBranchName $remoteHead
    } elseif (Test-GitRef 'refs/heads/main') {
        $baseName = 'main'
    } elseif (Test-GitRef 'refs/heads/master') {
        $baseName = 'master'
    } elseif (Test-GitRef 'refs/remotes/origin/main') {
        $baseName = 'main'
        $remoteBase = 'origin/main'
    } elseif (Test-GitRef 'refs/remotes/origin/master') {
        $baseName = 'master'
        $remoteBase = 'origin/master'
    }
}

if (-not $baseName) {
    Write-Output 'Branch insights: no base branch found.'
    Write-Output 'Set one for this repository with:'
    Write-Output '  git config lazygit.branchBase <branch>'
    exit 0
}

if (Test-GitRef "refs/heads/$baseName") {
    $localBase = $baseName
    $localUpstream = [string](Invoke-Git rev-parse --abbrev-ref "$localBase@{upstream}")
    $localUpstream = $localUpstream.Trim()
    if ($localUpstream) { $remoteBase = $localUpstream }
}

if (-not $remoteBase -and (Test-GitRef "refs/remotes/origin/$baseName")) {
    $remoteBase = "origin/$baseName"
}

if (-not $SelectedBranch) {
    $SelectedBranch = ([string](Invoke-Git branch --show-current)).Trim()
}

$prStatus = 'disabled'
$prByBranch = @{}
if ($Mode -eq 'pr') {
    $prStatus = 'unavailable'
    $remoteName = if ($remoteBase -and $remoteBase.Contains('/')) { $remoteBase.Split('/', 2)[0] } else { 'origin' }
    $remoteUrl = ([string](Invoke-Git remote get-url $remoteName)).Trim()
    if ($remoteUrl -notmatch 'github\.com') {
        $prStatus = 'not-github'
    } elseif (Get-Command gh -ErrorAction SilentlyContinue) {
        $json = & gh pr list --state all --limit 200 --json headRefName,baseRefName,state,isDraft,isCrossRepository,number,createdAt 2>$null
        if ($LASTEXITCODE -eq 0) {
            try {
                foreach ($item in ($json | ConvertFrom-Json)) {
                    if (-not $item.isCrossRepository -and -not $prByBranch.ContainsKey($item.headRefName)) {
                        $state = if ($item.isDraft) { 'DRAFT' } else { [string]$item.state }
                        $prByBranch[$item.headRefName] = "$state->$($item.baseRefName)#$($item.number)"
                    }
                }
                $prStatus = 'loaded'
            } catch {
                $prStatus = 'unavailable'
            }
        }
    }
}

Write-Output 'Branch insights (read-only; remote refs are not fetched)'
Write-Output ("Local base:  {0}" -f $(if ($localBase) { $localBase } else { '-' }))
Write-Output ("Remote base: {0}" -f $(if ($remoteBase) { $remoteBase } else { '-' }))

if ($localBase -and $remoteBase) {
    $baseCounts = Get-AheadBehind $localBase $remoteBase
    Write-Output ("Local {0} vs {1}: ahead {2}, behind {3}" -f $localBase, $remoteBase, $baseCounts[0], $baseCounts[1])
}
if ($Mode -eq 'pr') { Write-Output "GitHub PR data: $prStatus" }

$countBase = if ($remoteBase) { $remoteBase } else { $localBase }
$remoteBaseAvailable = $false
if ($remoteBase) {
    $remoteBaseAvailable = (Test-GitRef "refs/remotes/$remoteBase") -or (Test-GitRef "refs/heads/$remoteBase")
}
$localMerged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$remoteMerged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
if ($localBase) {
    foreach ($value in @(Invoke-Git for-each-ref "--merged=$localBase" '--format=%(refname:short)' refs/heads)) {
        [void]$localMerged.Add(([string]$value).Trim())
    }
}
if ($remoteBaseAvailable) {
    foreach ($value in @(Invoke-Git for-each-ref "--merged=$remoteBase" '--format=%(refname:short)' refs/heads)) {
        [void]$remoteMerged.Add(([string]$value).Trim())
    }
}

$header = '{0,-3} {1,-3} {2,-3} {3,6} {4,6} {5,-13} {6,-12} {7,-10} {8}' -f 'SEL', 'LOC', 'REM', 'BASE-', 'BASE+', 'UPSTREAM', 'WORKTREE', 'DATE', 'BRANCH'
if ($Mode -eq 'pr') { $header += '  PR' }
Write-Output ''
Write-Output $header

$separator = [char]31
$format = '%(refname:short)%1f%(upstream:short)%1f%(upstream:trackshort)%1f%(upstream:track)%1f%(worktreepath)%1f%(committerdate:short)'
$branches = @(Invoke-Git for-each-ref --sort=-committerdate "--format=$format" refs/heads)
foreach ($branchValue in $branches) {
    $fields = ([string]$branchValue).Split($separator)
    $branch = $fields[0].Trim()
    if (-not $branch) { continue }
    $marker = if ($branch -eq $SelectedBranch) { '>' } else { '' }
    $localMark = if (-not $localBase) { '-' } elseif ($localMerged.Contains($branch)) { 'Y' } else { 'N' }
    $remoteMark = if (-not $remoteBase) { '-' } elseif (-not $remoteBaseAvailable) { '?' } elseif ($remoteMerged.Contains($branch)) { 'Y' } else { 'N' }
    $counts = Get-AheadBehind $countBase $branch
    $upstream = Get-UpstreamState $fields[1].Trim() $fields[2].Trim() $fields[3].Trim()
    $worktree = $fields[4].Trim()
    if ($worktree) { $worktree = Split-Path -Leaf $worktree } else { $worktree = '-' }
    $commitDate = $fields[5].Trim()
    if (-not $commitDate) { $commitDate = '-' }

    $line = '{0,-3} {1,-3} {2,-3} {3,6} {4,6} {5,-13} {6,-12} {7,-10} {8}' -f $marker, $localMark, $remoteMark, $counts[0], $counts[1], $upstream, $worktree, $commitDate, $branch
    if ($Mode -eq 'pr') {
        $pr = if ($prStatus -eq 'unavailable') { '?' } elseif ($branch -ne $baseName -and $prByBranch.ContainsKey($branch)) { $prByBranch[$branch] } else { '-' }
        $line += "  $pr"
    }
    Write-Output $line
}

Write-Output ''
Write-Output 'LOC/REM: branch tip is an ancestor of local/remote base (Y/N).'
Write-Output 'BASE-/BASE+: commits only on the comparison base / only on the branch.'
Write-Output 'A merged PR can still show REM=N after squash or rebase merge.'
