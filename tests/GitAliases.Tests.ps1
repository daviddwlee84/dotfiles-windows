# Pester tests for the git-alias fragment (profile.d/21_git.ps1).
#
# The functions are thin `git …` wrappers, so we assert the *generated
# definitions* rather than running git (unavailable/irrelevant off a real repo).
# The things worth locking down: the omz mappings survive edits, gl means pull
# (not this repo's old `git log`), gcm/gm stay the PowerShell built-ins the user
# asked to keep, and the case-only omz variants (gbD/gcB) fail safe to their
# lowercase twin because pwsh command names are case-insensitive.

BeforeAll {
    $Fragment = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'profile.d' '21_git.ps1'
    . $Fragment
}

Describe 'git alias fragment' {

    Context 'static passthroughs map to the oh-my-zsh command' {
        It '<Name> -> git <Cmd>' -TestCases @(
            @{ Name = 'gst';   Cmd = 'status' }
            @{ Name = 'gs';    Cmd = 'status' }              # bonus, non-omz
            @{ Name = 'gco';   Cmd = 'checkout' }
            @{ Name = 'gcb';   Cmd = 'checkout -b' }
            @{ Name = 'gcmsg'; Cmd = 'commit --message' }
            @{ Name = 'gcam';  Cmd = 'commit --all --message' }
            @{ Name = 'gc';    Cmd = 'commit --verbose' }
            @{ Name = 'gp';    Cmd = 'push' }
            @{ Name = 'gl';    Cmd = 'pull' }                # omz: gl = pull, NOT log
            @{ Name = 'glo';   Cmd = 'log --oneline --decorate' }
            @{ Name = 'gaa';   Cmd = 'add --all' }
            @{ Name = 'gbd';   Cmd = 'branch --delete' }
        ) {
            (Get-Command $Name -CommandType Function).Definition.Trim() |
                Should -BeExactly "git $Cmd @args"
        }
    }

    Context '!-suffixed amend/force aliases are defined and callable' {
        It '<Name> is a function' -TestCases @(
            @{ Name = 'gc!' }
            @{ Name = 'gca!' }
            @{ Name = 'gcann!' }
            @{ Name = 'gpf!' }
        ) {
            Get-Command $Name -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    Context 'dynamic (branch-aware) helpers resolve to the right git verb' {
        It '<Name> definition matches <Pattern>' -TestCases @(
            @{ Name = 'gswm';  Pattern = 'switch \(git_main_branch\)' }
            @{ Name = 'gpsup'; Pattern = 'push --set-upstream origin \(git_current_branch\)' }
            @{ Name = 'grbom'; Pattern = 'rebase.*origin/.*git_main_branch' }
            @{ Name = 'gdup';  Pattern = "diff '@\{upstream\}'" }
            @{ Name = 'glol';  Pattern = 'log --graph --pretty=' }
        ) {
            (Get-Command $Name -CommandType Function).Definition | Should -Match $Pattern
        }
    }

    Context 'PowerShell built-ins we promised to keep' {
        It 'gcm stays the Get-Command alias' {
            $c = Get-Command gcm
            $c.CommandType | Should -Be 'Alias'
            $c.Definition  | Should -Be 'Get-Command'
        }
        It 'gm stays the Get-Member alias' {
            $c = Get-Command gm
            $c.CommandType | Should -Be 'Alias'
            $c.Definition  | Should -Be 'Get-Member'
        }
    }

    Context 'case-only omz variants fail safe (pwsh is case-insensitive)' {
        It 'gbD resolves to the non-force gbd' {
            (Get-Command gbD -CommandType Function).Definition.Trim() |
                Should -BeExactly 'git branch --delete @args'
        }
        It 'gcB resolves to the -b (not -B) gcb' {
            (Get-Command gcB -CommandType Function).Definition.Trim() |
                Should -BeExactly 'git checkout -b @args'
        }
    }

    Context 'coverage' {
        It 'defines a large git-alias surface' {
            (Get-Command -CommandType Function |
                Where-Object { $_.Name -like 'g*' -and -not $_.Source }).Count |
                Should -BeGreaterThan 150
        }
    }
}
