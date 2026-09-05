#Requires -Version 7.4
#Requires -PSEdition Core
# Behavioral contracts for the native PowerShell Lazygit branch-insights helper.

BeforeAll {
    $script:Helper = Join-Path $PSScriptRoot '..' 'dot_config' 'lazygit' 'branch-insights.ps1'
    $script:Config = Join-Path $PSScriptRoot '..' 'dot_config' 'lazygit' 'config.yml'
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("lazygit-branch-insights-{0}" -f [guid]::NewGuid())
    $script:Repo = Join-Path $script:Root 'repo'
    $script:Remote = Join-Path $script:Root 'remote.git'
    $script:Worktree = Join-Path $script:Root 'active-worktree'
    New-Item -ItemType Directory -Path $script:Root | Out-Null

    function Invoke-TestGit {
        & git -C $script:Repo @args *> $null
        if ($LASTEXITCODE -ne 0) { throw "git failed: $args" }
    }

    & git init --bare $script:Remote *> $null
    & git -C $script:Remote symbolic-ref HEAD refs/heads/main
    & git init -b main $script:Repo *> $null
    Invoke-TestGit config user.name 'Test User'
    Invoke-TestGit config user.email test@example.com
    Set-Content -NoNewline -Path (Join-Path $script:Repo 'file.txt') -Value 'base'
    Invoke-TestGit add file.txt
    Invoke-TestGit commit -m base
    Invoke-TestGit remote add origin $script:Remote
    Invoke-TestGit push -u origin main
    Invoke-TestGit remote set-head origin -a
    Invoke-TestGit branch contained origin/main
    Invoke-TestGit branch gone origin/main
    Invoke-TestGit push -u origin gone
    Invoke-TestGit push origin --delete gone

    Add-Content -Path (Join-Path $script:Repo 'file.txt') -Value 'local-main'
    Invoke-TestGit add file.txt
    Invoke-TestGit commit -m local-main
    Invoke-TestGit branch local-only
    Invoke-TestGit switch -c feature/unmerged origin/main
    Set-Content -NoNewline -Path (Join-Path $script:Repo 'feature.txt') -Value 'feature'
    Invoke-TestGit add feature.txt
    Invoke-TestGit commit -m feature
    Invoke-TestGit branch worktree-active origin/main
    Invoke-TestGit worktree add $script:Worktree worktree-active
    Invoke-TestGit switch main
}

AfterAll {
    & git -C $script:Repo worktree remove --force $script:Worktree *> $null
    Remove-Item -Recurse -Force $script:Root -ErrorAction SilentlyContinue
}

Describe 'Lazygit branch insights config' {
    It 'enables status-first branch display and the I menu' {
        $text = Get-Content -Raw $script:Config
        $text | Should -Match 'nerdFontsVersion: "3"'
        $text | Should -Match 'showDivergenceFromBaseBranch: arrowAndNumber'
        $text | Should -Match 'localBranchSortOrder: recency'
        $text | Should -Match 'context: localBranches'
        $text | Should -Match 'key: I'
        $text | Should -Not -Match 'showBranchCommitHash: true'
    }
}

Describe 'Lazygit branch insights helper' {
    It 'separates local and remote containment and shows main divergence' {
        Push-Location $script:Repo
        try {
            $output = (& $script:Helper -Mode git -SelectedBranch feature/unmerged) -join "`n"
        } finally {
            Pop-Location
        }
        $output | Should -Match 'Local main vs origin/main: ahead 1, behind 0'
        $output | Should -Match 'Y\s+Y.+contained'
        $output | Should -Match 'Y\s+N.+local-only'
        $output | Should -Match '>\s+N\s+N.+feature/unmerged'
        $output | Should -Match 'gone.+gone'
        $output | Should -Match 'active-worktree.+worktree-active'
    }

    It 'honors a repo-local base override' {
        Invoke-TestGit branch develop origin/main
        Invoke-TestGit config lazygit.branchBase develop
        Push-Location $script:Repo
        try {
            $output = (& $script:Helper -Mode git -SelectedBranch develop) -join "`n"
        } finally {
            Pop-Location
            Invoke-TestGit config --unset lazygit.branchBase
        }
        $output | Should -Match 'Local base:\s+develop'
        $output | Should -Match 'Remote base: origin/main'
    }

    It 'keeps a squash-style merged PR separate from ancestry' {
        $fakeBin = Join-Path $script:Root 'fake-bin'
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        $json = '[{"headRefName":"main","baseRefName":"main","state":"CLOSED","isDraft":false,"isCrossRepository":true,"number":4,"createdAt":"2026-08-01T00:00:00Z"},{"headRefName":"feature/unmerged","baseRefName":"main","state":"MERGED","isDraft":false,"isCrossRepository":false,"number":42,"createdAt":"2026-09-01T00:00:00Z"}]'
        $posixGh = Join-Path $fakeBin 'gh'
        Set-Content -Path $posixGh -Value "#!/bin/sh`nprintf '%s\n' '$json'"
        if (-not $IsWindows) { & chmod +x $posixGh }
        Set-Content -Path (Join-Path $fakeBin 'gh.cmd') -Value "@echo off`r`necho $json"

        $oldPath = $env:PATH
        $oldRemote = (& git -C $script:Repo remote get-url origin).Trim()
        try {
            $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$oldPath"
            Invoke-TestGit remote set-url origin https://github.com/example/demo.git
            Push-Location $script:Repo
            try {
                $output = (& $script:Helper -Mode pr -SelectedBranch feature/unmerged) -join "`n"
            } finally {
                Pop-Location
            }
        } finally {
            $env:PATH = $oldPath
            Invoke-TestGit remote set-url origin $oldRemote
        }

        $output | Should -Match 'GitHub PR data: loaded'
        $output | Should -Match 'N\s+N.+feature/unmerged\s+MERGED->main#42'
        $output | Should -Not -Match 'CLOSED->main#4'
    }
}
