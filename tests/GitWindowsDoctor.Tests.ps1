#Requires -Version 7

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:RepoRoot 'dot_config\powershell\profile.d\22_git_windows.ps1')

    function New-GitWindowsTestRoot {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('git-windows-doctor-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        return $path
    }

    function Initialize-GitWindowsTestRepository {
        param([Parameter(Mandatory)][string] $Path)

        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        & git -C $Path init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        & git -C $Path config user.name 'Test User'
        & git -C $Path config user.email 'test@example.com'
        & git -C $Path config core.safecrlf false
        return $Path
    }

    function Add-GitWindowsPlaceholder {
        param(
            [Parameter(Mandatory)][string] $Repository,
            [string] $Path = '.claude/skills/example',
            [string] $Target = '../../.agents/skills/example'
        )

        $source = Join-Path $Repository '.agents\skills\example'
        New-Item -ItemType Directory -Force -Path $source | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'SKILL.md'), "---`nname: example`n---`n")
        & git -C $Repository add -- '.agents/skills/example/SKILL.md'
        if ($LASTEXITCODE -ne 0) { throw 'could not add target fixture' }

        $fullPath = Join-Path $Repository $Path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullPath) | Out-Null
        [IO.File]::WriteAllText($fullPath, $Target)
        $oid = (& git -C $Repository hash-object -w -- $Path).Trim()
        & git -C $Repository update-index --add --cacheinfo "120000,$oid,$Path"
        if ($LASTEXITCODE -ne 0) { throw 'could not add symlink fixture to the index' }
        & git -C $Repository config core.symlinks false
        return $fullPath
    }

    function Test-GitWindowsTestSymlinkCapability {
        $root = New-GitWindowsTestRoot
        try {
            $target = Join-Path $root 'target.txt'
            $link = Join-Path $root 'link.txt'
            [IO.File]::WriteAllText($target, 'probe')
            [IO.File]::CreateSymbolicLink($link, $target) | Out-Null
            return (Get-Item -LiteralPath $link -Force).LinkType -eq 'SymbolicLink'
        } catch {
            return $false
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'git-windows-doctor' {
    BeforeEach {
        $script:TestRoot = New-GitWindowsTestRoot
        $script:PreviousGlobalConfig = $env:GIT_CONFIG_GLOBAL
        $script:TestGlobalConfig = Join-Path $script:TestRoot 'global.gitconfig'
        [IO.File]::WriteAllText(
            $script:TestGlobalConfig,
            "[core]`n`tsymlinks = true`n`tautocrlf = input`n",
            [Text.UTF8Encoding]::new($false)
        )
        $env:GIT_CONFIG_GLOBAL = $script:TestGlobalConfig
    }

    AfterEach {
        if ($null -eq $script:PreviousGlobalConfig) {
            Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
        } else {
            $env:GIT_CONFIG_GLOBAL = $script:PreviousGlobalConfig
        }
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'recognizes an exact Git symlink placeholder without modifying it' {
        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        $placeholder = Add-GitWindowsPlaceholder -Repository $repo

        $result = @(git-windows-doctor -Root $repo)

        $result.Count | Should -Be 1
        $result[0].Status | Should -Be 'Repairable'
        $result[0].TrackedSymlinkCount | Should -Be 1
        $result[0].RepairableSymlinkCount | Should -Be 1
        (Get-Item -LiteralPath $placeholder -Force).LinkType | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($placeholder) | Should -BeExactly '../../.agents/skills/example'
    }

    It 'honors WhatIf without removing a placeholder or local override' {
        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        $placeholder = Add-GitWindowsPlaceholder -Repository $repo

        $result = @(gwinfix -Root $repo -WhatIf)

        $result[0].RepairableSymlinkCount | Should -Be 1
        Test-Path -LiteralPath $placeholder -PathType Leaf | Should -BeTrue
        (& git -C $repo config --local --get core.symlinks) | Should -BeExactly 'false'
    }

    It 'leaves the placeholder and local config untouched when symlink preflight fails' {
        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        $placeholder = Add-GitWindowsPlaceholder -Repository $repo
        $blockedTemp = Join-Path $script:TestRoot 'not-a-directory'
        [IO.File]::WriteAllText($blockedTemp, 'blocked')
        $previousTemp = $env:TEMP
        try {
            $env:TEMP = $blockedTemp
            $result = @(gwinfix -Root $repo)
        } finally {
            $env:TEMP = $previousTemp
        }

        $result[0].Status | Should -Be 'Error'
        $result[0].RepairedSymlinkCount | Should -Be 0
        Test-Path -LiteralPath $placeholder -PathType Leaf | Should -BeTrue
        [IO.File]::ReadAllText($placeholder) | Should -BeExactly '../../.agents/skills/example'
        (& git -C $repo config --local --get core.symlinks) | Should -BeExactly 'false'
    }

    It 'repairs an exact placeholder when unprivileged symlinks are available' {
        if (-not (Test-GitWindowsTestSymlinkCapability)) {
            Set-ItResult -Skipped -Because 'this host cannot create an unprivileged symbolic link'
            return
        }

        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        $placeholder = Add-GitWindowsPlaceholder -Repository $repo

        $result = @(gwinfix -Root $repo)
        $item = Get-Item -LiteralPath $placeholder -Force

        $item.LinkType | Should -BeExactly 'SymbolicLink'
        (($item.Target -join '') -replace '\\', '/') | Should -BeExactly '../../.agents/skills/example'
        $result[0].RepairedSymlinkCount | Should -Be 1
        $result[0].RepairableSymlinkCount | Should -Be 0
        (& git -C $repo config --local --get core.symlinks 2>$null) | Should -BeNullOrEmpty
    }

    It 'refuses a real file whose content differs from the index target' {
        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        $placeholder = Add-GitWindowsPlaceholder -Repository $repo
        [IO.File]::WriteAllText($placeholder, 'user-owned content')

        $result = @(gwinfix -Root $repo)

        $result[0].Status | Should -Be 'Error'
        $result[0].SymlinkConflictCount | Should -Be 1
        [IO.File]::ReadAllText($placeholder) | Should -BeExactly 'user-owned content'
        (& git -C $repo config --local --get core.symlinks) | Should -BeExactly 'false'
    }

    It 'does not restore a missing symlink marked skip-worktree' {
        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        $placeholder = Add-GitWindowsPlaceholder -Repository $repo
        & git -C $repo update-index --skip-worktree -- '.claude/skills/example'
        Remove-Item -LiteralPath $placeholder -Force

        $result = @(gwinfix -Root $repo)

        $result[0].SparseSymlinkCount | Should -Be 1
        $result[0].RepairableSymlinkCount | Should -Be 0
        Test-Path -LiteralPath $placeholder | Should -BeFalse
        (& git -C $repo config --local --get core.symlinks) | Should -BeExactly 'false'
    }

    It 'discovers multiple repositories beneath an explicit root' {
        Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'one') | Out-Null
        Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'nested\two') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:TestRoot 'node_modules\ignored\.git') | Out-Null

        $result = @(git-windows-doctor -Root $script:TestRoot -Depth 4)

        $result.Count | Should -Be 2
        @($result.Repository | Split-Path -Leaf | Sort-Object) | Should -Be @('one', 'two')
    }

    It 'reports mixed EOL, case collisions, long paths, and non-executable shell scripts' {
        $repo = Initialize-GitWindowsTestRepository -Path (Join-Path $script:TestRoot 'repo')
        [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'), "* text=auto eol=lf`n")
        [IO.File]::WriteAllBytes(
            (Join-Path $repo 'mixed.sh'),
            [Text.UTF8Encoding]::new($false).GetBytes("#!/bin/sh`r`necho one`necho two`r`n")
        )
        & git -C $repo add -- .gitattributes mixed.sh

        [IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), 'seed')
        $oid = (& git -C $repo hash-object -w -- seed.txt).Trim()
        & git -C $repo update-index --add --cacheinfo "100644,$oid,Foo.txt"
        & git -C $repo update-index --add --cacheinfo "100644,$oid,foo.txt"
        & git -C $repo -c core.protectNTFS=false update-index --add --cacheinfo "100644,$oid,aux.txt"
        $longPath = 'deep/' + ('a' * 230) + '.txt'
        & git -C $repo update-index --add --cacheinfo "100644,$oid,$longPath"

        $result = @(git-windows-doctor -Root $repo)

        $result[0].MixedEolCount | Should -BeGreaterThan 0
        $result[0].CaseCollisionCount | Should -BeGreaterThan 0
        $result[0].InvalidWindowsPathCount | Should -BeGreaterThan 0
        $result[0].LongPathCount | Should -BeGreaterThan 0
        @($result[0].Findings | Where-Object Category -EQ 'Executable').Count | Should -BeGreaterThan 0
    }
}
