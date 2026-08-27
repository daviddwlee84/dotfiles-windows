# Pester tests for the translate install path.
#
# translate moved from a version-pinned `go install` to the author's own scoop
# bucket on 2026-08-27. These guard the two things that silently rot: the repo
# drifting back to a source build, and the migration guard that stops a leftover
# ~\.local\bin\translate.exe shadowing the scoop shim forever.

BeforeAll {
    $RepoRoot        = Join-Path $PSScriptRoot '..'
    $PackageTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $ToolsProfile    = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '10_tools.ps1'
    $Justfile        = Join-Path $RepoRoot 'justfile'
    $DocPath         = Join-Path $RepoRoot 'docs' 'translate.md'
}

Describe 'translate install path' {
    BeforeAll {
        $script:package = Get-Content -Raw -LiteralPath $PackageTemplate
        $script:tools   = Get-Content -Raw -LiteralPath $ToolsProfile
        $script:just    = Get-Content -Raw -LiteralPath $Justfile
        $script:doc     = Get-Content -Raw -LiteralPath $DocPath
    }

    It 'installs from the personal scoop bucket, not from source' {
        $package | Should -Match 'scoop bucket add daviddwlee84 https://github\.com/daviddwlee84/scoop-bucket'
        $package | Should -Match "Scoop-Install @\('daviddwlee84/translate'\)"
    }

    It 'no longer go-installs translate or pins a version for it' {
        $package | Should -Not -Match 'go install "github\.com/daviddwlee84/translate'
        $package | Should -Not -Match '\$translateVersion'
    }

    It 'removes the shadowing go-install binary only once the scoop shim exists' {
        # ~\.local\bin precedes ~\scoop\shims on PATH, so the stale copy wins
        # forever if left behind — but deleting it before the shim lands would
        # leave the box with no translate at all.
        $package | Should -Match '\$trOld\s*=\s*Join-Path'
        $package | Should -Match 'local\\bin\\translate\.exe'
        $package | Should -Match 'shims\\translate\.exe'
        $package | Should -Match 'Remove-Item -LiteralPath \$trOld'
        $package | Should -Match '\$env:SCOOP'
    }

    It 'still generates pwsh completions, cached against the binary mtime' {
        $tools | Should -Match "Import-CachedInit -Name 'translate' -Exe 'translate'"
        $tools | Should -Match 'translate completion powershell'
    }

    It 'upgrades through scoop' {
        $just | Should -Match 'upgrade-translate:\s*\r?\n\s*scoop update translate'
        $just | Should -Not -Match 'go install github\.com/daviddwlee84/translate@latest'
    }

    It 'documents the install path and the shadowing trap' {
        $doc | Should -Match 'scoop install daviddwlee84/translate'
        $doc | Should -Match 'Get-Command translate -All'
    }
}
