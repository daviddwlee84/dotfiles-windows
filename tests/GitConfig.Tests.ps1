#Requires -Version 7.4
#Requires -PSEdition Core
# Tests for the ~/.gitconfig overlay merge engine.
#
# The engine lives in scripts/gitconfig-merge.ps1 as a real .ps1 precisely so it
# can be dot-sourced here without invoking chezmoi. modify_dot_gitconfig.ps1.tmpl
# inlines the same file via {{ include }}, so what is tested is what ships.
#
# Fixture credentials below are FAKE. Never paste a real ~/.gitconfig into a
# test -- this repo's gitleaks hook scans tests/ like any other path.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'gitconfig-merge.ps1')

    $script:Baseline = @'
[user]
	name = Test User
	email = test@example.com

[core]
	autocrlf = input
	symlinks = true

[init]
	defaultBranch = main

[pull]
	rebase = true

[include]
	path = ~/.gitconfig.local
'@

    $script:Live = @'
[user]
	name = stale-name
	email = stale@example.com
[credential "azrepos:org/example"]
	username = someone@example.com
	azureAuthority = https://login.example.com/tenant-guid
[otel "trace2"]
	historyOn = true
[core]
	autocrlf = true
	symlinks = false
	editor = vim
[pull]
	rebase = false
'@
}

Describe 'ConvertFrom-GitConfigText' {
    It 'keeps the subsection in the section name' {
        $entries = ConvertFrom-GitConfigText -Text "[filter `"lfs`"]`n`trequired = true"
        $entries[0].Section | Should -Be 'filter "lfs"'
        $entries[0].Key | Should -Be 'required'
    }

    It 'ignores comments, blanks and malformed lines' {
        $entries = ConvertFrom-GitConfigText -Text "# comment`n; other`n`n[core]`nnot-a-pair`n`tautocrlf = input"
        $entries.Count | Should -Be 1
        $entries[0].Key | Should -Be 'autocrlf'
    }

    It 'returns an empty collection for empty input' {
        (ConvertFrom-GitConfigText -Text '').Count | Should -Be 0
    }
}

Describe 'Merge-GitConfig' {
    Context 'empty live file (fresh host, and what CI exercises)' {
        It 'emits the baseline' {
            $merged = Merge-GitConfig -BaselineText $script:Baseline -LiveText ''
            $merged | Should -Match 'autocrlf = input'
            $merged | Should -Match 'symlinks = true'
            $merged | Should -Match 'defaultBranch = main'
        }

        It 'never emits core.hooksPath -- it would disarm .git/hooks/pre-commit' {
            $merged = Merge-GitConfig -BaselineText $script:Baseline -LiveText ''
            $merged | Should -Not -Match 'hooksPath'
        }
    }

    Context 'live file with corp state' {
        BeforeAll {
            $script:Merged = Merge-GitConfig -BaselineText $script:Baseline -LiveText $script:Live
        }

        It 'preserves the credential block and both of its keys' {
            $script:Merged | Should -Match '\[credential "azrepos:org/example"\]'
            $script:Merged | Should -Match 'username = someone@example\.com'
            $script:Merged | Should -Match 'azureAuthority = https://login\.example\.com/tenant-guid'
        }

        It 'preserves an unmanaged section such as otel' {
            $script:Merged | Should -Match '\[otel "trace2"\]'
            $script:Merged | Should -Match 'historyOn = true'
        }

        It 'preserves an unmanaged key inside a managed section' {
            $script:Merged | Should -Match 'editor = vim'
        }

        It 'overrides managed keys rather than carrying the live value' {
            $script:Merged | Should -Match 'autocrlf = input'
            $script:Merged | Should -Not -Match 'autocrlf = true'
            $script:Merged | Should -Match 'symlinks = true'
            $script:Merged | Should -Not -Match 'symlinks = false'
            $script:Merged | Should -Not -Match 'rebase = false'
            $script:Merged | Should -Not -Match 'stale-name'
            $script:Merged | Should -Not -Match 'stale@example\.com'
        }
    }

    Context 'stability' {
        It 'is idempotent -- merging its own output changes nothing' {
            $once = Merge-GitConfig -BaselineText $script:Baseline -LiveText $script:Live
            $twice = Merge-GitConfig -BaselineText $script:Baseline -LiveText $once
            $twice | Should -BeExactly $once
        }

        It 'survives a malformed live file without throwing' {
            { Merge-GitConfig -BaselineText $script:Baseline -LiveText "[unclosed`ngarbage`n= novalue" } |
                Should -Not -Throw
        }

        It 'keeps two credential subsections that differ only by case' {
            # Regression: [ordered]@{} compares keys case-INsensitively, which
            # collapsed [credential "azrepos:org/O365Exchange"] into
            # [credential "azrepos:org/o365exchange"] and handed one org's
            # credentials to another. Git treats the quoted subsection as
            # case-sensitive, so both headers must survive.
            $live = @'
[credential "azrepos:org/o365exchange"]
	username = lower@example.com
[credential "azrepos:org/O365Exchange"]
	username = upper@example.com
'@
            $merged = Merge-GitConfig -BaselineText $script:Baseline -LiveText $live
            $merged | Should -Match '\[credential "azrepos:org/o365exchange"\]'
            $merged | Should -Match '\[credential "azrepos:org/O365Exchange"\]'
            $merged | Should -Match 'lower@example\.com'
            $merged | Should -Match 'upper@example\.com'
        }

        It 'emits LF only, never CRLF' {
            $merged = Merge-GitConfig -BaselineText $script:Baseline -LiveText $script:Live
            $merged | Should -Not -Match "`r"
        }
    }
}

Describe 'Shipped baseline template' {
    BeforeAll {
        $script:TemplateText = Get-Content -Raw (Join-Path $PSScriptRoot '..' '.chezmoitemplates' 'git' 'gitconfig')
    }

    It 'sets autocrlf=input -- load-bearing for scoop bucket updates' {
        $script:TemplateText | Should -Match 'autocrlf = input'
    }

    It 'sets symlinks=true for repo-local links on Windows' {
        $script:TemplateText | Should -Match 'symlinks = true'
    }

    It 'does not set core.hooksPath anywhere, including in a comment-free read' {
        $active = ($script:TemplateText -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }) -join "`n"
        $active | Should -Not -Match 'hooksPath'
    }

    It 'templates identity from the init prompts rather than hardcoding it' {
        $script:TemplateText | Should -Match '\{\{\s*\.name\s*\}\}'
        $script:TemplateText | Should -Match '\{\{\s*\.email\s*\}\}'
    }
}
