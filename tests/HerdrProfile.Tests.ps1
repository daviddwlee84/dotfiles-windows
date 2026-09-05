#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Fragment = Join-Path $script:RepoRoot 'dot_config\powershell\profile.d\25_herdr.ps1'
}

Describe 'Herdr profile fragment scope' {
    It 'keeps hhere and its target after a function-scoped profile reload' {
        $escapedFragment = $script:Fragment.Replace("'", "''")
        $probe = @'
function Import-HerdrFragment {
    function herdr { }
    . '__FRAGMENT__'
}

Import-HerdrFragment

$alias = Get-Command hhere -CommandType Alias -ErrorAction SilentlyContinue
$target = Get-Command herdr-here -CommandType Function -ErrorAction SilentlyContinue
if (-not $alias -or $alias.Definition -ne 'herdr-here' -or -not $target) {
    exit 7
}

hhere --help | Out-Null
if (-not $?) { exit 8 }
'@.Replace('__FRAGMENT__', $escapedFragment)

        & pwsh -NoProfile -Command $probe
        $LASTEXITCODE | Should -Be 0
    }

    It 'declares every helper and public command in global scope' {
        $definitions = Select-String -LiteralPath $script:Fragment -Pattern '^function\s+(?<name>[^\s{]+)'
        $definitions.Count | Should -BeGreaterThan 10
        foreach ($definition in $definitions) {
            $definition.Matches[0].Groups['name'].Value | Should -Match '^global:'
        }
    }
}
