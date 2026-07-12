# Pester tests for the try fragment (profile.d/32_try.ps1).
#
# The translator (`_Try-ParsePosixArgs` / `_Try-InvokeEmitted`) is defined
# unconditionally, so most tests need only git (not ruby) and run in CI too. They
# feed hand-built emit strings that match try-cli's exact `emit_script` format
# (verified against real `ruby try.rb exec` output on a dev box) and assert the
# real filesystem effect + final location. A ruby-gated block exercises the whole
# `tri` command end-to-end when try-cli is actually installed.

BeforeDiscovery {
    # -Skip conditions are evaluated during discovery (before BeforeAll), so the
    # capability probes must live here, not in BeforeAll.
    $HaveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    $HaveTry = $false
    if (Get-Command ruby -ErrorAction SilentlyContinue) {
        $p = & ruby -e "require 'rubygems'; puts File.join(Gem::Specification.find_by_name('try-cli').gem_dir,'try.rb')" 2>$null |
             Select-Object -First 1
        $HaveTry = [bool]$p -and (Test-Path -LiteralPath $p)
    }
}

BeforeAll {
    $Fragment = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'profile.d' '32_try.ps1'
    . $Fragment

    # Build try's `emit_script` output for a command list (comment + " && \" joins).
    function New-Emit([string[]]$Cmds) {
        $marker = "# if you can read this, you didn't launch try from an alias. run try --help."
        ($marker, (($Cmds | ForEach-Object { $_ }) -join " && \`n  ")) -join "`n"
    }
    function New-TempDir {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("try-t-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        $p
    }
}

Describe 'try fragment' {

    Context '_Try-ParsePosixArgs (POSIX quote tokenizer)' {
        It 'splits flags and a quoted path with spaces' {
            (_Try-ParsePosixArgs "mkdir -p '/a b/c'") -join '|' | Should -Be 'mkdir|-p|/a b/c'
        }
        It "round-trips try's embedded-quote escape '\'' " {
            # try emits path a'b as:  'a'"'"'b'
            (_Try-ParsePosixArgs "cd 'a'`"'`"'b'") -join '|' | Should -Be "cd|a'b"
        }
        It 'yields an empty token for an empty quoted string' {
            (_Try-ParsePosixArgs "echo ''") -join '|' | Should -Be 'echo|'
        }
    }

    Context 'translator: create (mkdir + cd)' {
        It 'creates the dated dir and lands in it' {
            $tmp = New-TempDir
            try {
                $dest = Join-Path $tmp '2026-07-12-x'
                Push-Location $tmp
                _Try-InvokeEmitted -Emitted (New-Emit @("mkdir -p '$dest'", "touch '$dest'", "echo '$dest'", "cd '$dest'"))
                (Get-Location).Path | Should -Be (Resolve-Path -LiteralPath $dest).Path
                Test-Path -LiteralPath $dest | Should -BeTrue
            } finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        }
    }

    Context 'translator: clone' -Skip:(-not $HaveGit) {
        It 'clones a local repo and lands in the checkout' {
            $tmp = New-TempDir
            try {
                $seed = Join-Path $tmp 'seed'; git init -q $seed
                Set-Content (Join-Path $seed 'a.txt') 'hi'
                git -C $seed -c user.email=t@t -c user.name=t add -A 2>$null
                git -C $seed -c user.email=t@t -c user.name=t commit -qm init 2>$null
                $origin = Join-Path $tmp 'seed.git'; git clone -q --bare $seed $origin 2>$null
                $dest = Join-Path $tmp '2026-07-12-seed'
                Push-Location $tmp
                _Try-InvokeEmitted -Emitted (New-Emit @(
                        "mkdir -p '$dest'", "echo 'Using git clone.'", "git clone '$origin' '$dest'",
                        "touch '$dest'", "echo '$dest'", "cd '$dest'"))
                (Get-Location).Path | Should -Be (Resolve-Path -LiteralPath $dest).Path
                Test-Path -LiteralPath (Join-Path $dest '.git') | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $dest 'a.txt') | Should -BeTrue
            } finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        }
    }

    Context 'translator: worktree (native git worktree add)' -Skip:(-not $HaveGit) {
        It 'adds a detached worktree and lands in it' {
            $tmp = New-TempDir
            try {
                $repo = Join-Path $tmp 'repo'; git init -q $repo
                Set-Content (Join-Path $repo 'r.txt') 'x'
                git -C $repo -c user.email=t@t -c user.name=t add -A 2>$null
                git -C $repo -c user.email=t@t -c user.name=t commit -qm init 2>$null
                $dest = Join-Path $tmp '2026-07-12-wt'
                $sh = "/usr/bin/env sh -c 'if git -C '$repo' rev-parse --is-inside-work-tree; then git -C `"`$repo`" worktree add --detach '$dest'; fi'"
                Push-Location $repo
                _Try-InvokeEmitted -Emitted (New-Emit @("mkdir -p '$dest'", "echo 'Using git worktree.'", $sh, "touch '$dest'", "echo '$dest'", "cd '$dest'"))
                (Get-Location).Path | Should -Be (Resolve-Path -LiteralPath $dest).Path
                Test-Path -LiteralPath (Join-Path $dest '.git') -PathType Leaf | Should -BeTrue   # worktree = .git file
            } finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        }
    }

    Context 'translator: delete + restore trailer' {
        It 'removes the victim dir and restores to an existing dir' {
            $tmp = New-TempDir
            try {
                $victim = Join-Path $tmp 'doomed'; New-Item -ItemType Directory -Force -Path $victim | Out-Null
                $restore = Join-Path $tmp 'restore'; New-Item -ItemType Directory -Force -Path $restore | Out-Null
                Push-Location $tmp
                _Try-InvokeEmitted -Emitted (New-Emit @("cd '$tmp'", "test -d 'doomed' && rm -rf 'doomed'", "cd '$restore' 2>/dev/null || cd '$tmp'"))
                Test-Path -LiteralPath $victim | Should -BeFalse
                (Get-Location).Path | Should -Be (Resolve-Path -LiteralPath $restore).Path
            } finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        }
    }

    Context 'end-to-end tri (real try-cli)' -Skip:(-not $HaveTry) {
        It 'tri . <name> creates a dated trial and cd''s in' {
            $tmp = New-TempDir
            try {
                $env:TRY_PATH = Join-Path $tmp 'tries'
                $work = Join-Path $tmp 'work'; New-Item -ItemType Directory -Force -Path $work | Out-Null
                Push-Location $work
                tri . e2e
                (Get-Location).Path | Should -Match 'e2e$'
                (Get-Location).Path | Should -BeLike (Join-Path $tmp 'tries*')
            } finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
        }
    }
}
