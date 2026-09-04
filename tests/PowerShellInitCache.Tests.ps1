#Requires -Version 7

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $ToolsProfile = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '10_tools.ps1'
    $PsReadLineTemplate = Join-Path $RepoRoot 'dot_config' 'powershell' 'profile.d' '90_psreadline.ps1.tmpl'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ToolsProfile,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "10_tools.ps1 did not parse: $($parseErrors[0].Message)"
    }
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Import-CachedInit'
    }, $true)
    if (-not $functionAst) { throw 'Import-CachedInit was not found' }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

Describe 'PSReadLine command-mode guard' {
    It 'returns on redirected streams before importing PSReadLine' {
        $source = Get-Content -Raw -LiteralPath $PsReadLineTemplate
        $guard = $source.IndexOf('[Console]::IsInputRedirected -or [Console]::IsOutputRedirected')
        $import = $source.IndexOf('Import-Module PSReadLine')

        $guard | Should -BeGreaterOrEqual 0
        $import | Should -BeGreaterThan $guard
        $source.Substring($guard, $import - $guard) | Should -Match '\{\s*return\s*\}'
    }
}

Describe 'Import-CachedInit revision stamp' {
    BeforeEach {
        $script:PreviousCacheHome = $env:XDG_CACHE_HOME
        $env:XDG_CACHE_HOME = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Remove-Item Env:PIA_CACHED_INIT_PROBE -ErrorAction SilentlyContinue
    }

    AfterEach {
        if ($null -eq $script:PreviousCacheHome) {
            Remove-Item Env:XDG_CACHE_HOME -ErrorAction SilentlyContinue
        } else {
            $env:XDG_CACHE_HOME = $script:PreviousCacheHome
        }
        Remove-Item Env:PIA_CACHED_INIT_PROBE -ErrorAction SilentlyContinue
    }

    It 'reuses one revision and regenerates when only the revision changes' {
        $counterFile = Join-Path $TestDrive 'revision-counter.txt'
        $generate = {
            $next = if (Test-Path -LiteralPath $counterFile) {
                [int](Get-Content -LiteralPath $counterFile -Raw) + 1
            } else { 1 }
            Set-Content -LiteralPath $counterFile -Value $next -NoNewline
            '$env:PIA_CACHED_INIT_PROBE = ''{0}''' -f $next
        }.GetNewClosure()
        $exe = (Get-Process -Id $PID).Path

        Import-CachedInit -Name 'revision-test' -Exe $exe -RevisionStamp 'rev-a' -Generate $generate
        $env:PIA_CACHED_INIT_PROBE | Should -BeExactly '1'
        Get-Content -LiteralPath $counterFile -Raw | Should -BeExactly '1'

        Remove-Item Env:PIA_CACHED_INIT_PROBE -ErrorAction SilentlyContinue
        Import-CachedInit -Name 'revision-test' -Exe $exe -RevisionStamp 'rev-a' -Generate $generate
        $env:PIA_CACHED_INIT_PROBE | Should -BeExactly '1'
        Get-Content -LiteralPath $counterFile -Raw | Should -BeExactly '1'

        Remove-Item Env:PIA_CACHED_INIT_PROBE -ErrorAction SilentlyContinue
        Import-CachedInit -Name 'revision-test' -Exe $exe -RevisionStamp 'rev-b' -Generate $generate
        $env:PIA_CACHED_INIT_PROBE | Should -BeExactly '2'
        Get-Content -LiteralPath $counterFile -Raw | Should -BeExactly '2'
        Get-Content -LiteralPath (Join-Path $env:XDG_CACHE_HOME 'pwsh-init/revision-test.ps1.stamp') -Raw |
            Should -Match 'rev-b'
    }

    It 'retains executable-mtime-only caching when no revision is supplied' {
        $counterFile = Join-Path $TestDrive 'legacy-counter.txt'
        $generate = {
            $next = if (Test-Path -LiteralPath $counterFile) {
                [int](Get-Content -LiteralPath $counterFile -Raw) + 1
            } else { 1 }
            Set-Content -LiteralPath $counterFile -Value $next -NoNewline
            '$env:PIA_CACHED_INIT_PROBE = ''{0}''' -f $next
        }.GetNewClosure()
        $exe = (Get-Process -Id $PID).Path

        Import-CachedInit -Name 'mtime-test' -Exe $exe -Generate $generate
        Import-CachedInit -Name 'mtime-test' -Exe $exe -Generate $generate

        $env:PIA_CACHED_INIT_PROBE | Should -BeExactly '1'
        Get-Content -LiteralPath $counterFile -Raw | Should -BeExactly '1'
    }
}
