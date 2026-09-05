#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot -Parent
}

Describe 'first-party PowerShell runtime contract' {
    It 'marks first-party scripts and templates as 7.4+ Core, except bootstrap' {
        $roots = @('.chezmoiscripts', '.chezmoitemplates', 'Documents', 'dot_claude', 'dot_codex', 'dot_config', 'dot_summarize', 'scripts', 'tests')
        $files = @($roots | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $script:Repo $_) -Recurse -File } |
            Where-Object Name -Match '\.(ps1|psm1)(\.tmpl)?$')
        $files += Get-Item (Join-Path $script:Repo 'modify_dot_gitconfig.ps1.tmpl')
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text | Should -Match '(?m)^#Requires -Version 7\.4\r?$' -Because $file.FullName
            if ($file.FullName -ne (Join-Path $script:Repo '.chezmoitemplates/package-sources.ps1')) {
                $text | Should -Match '(?m)^#Requires -PSEdition Core\r?$' -Because $file.FullName
            }
        }
        $bootstrap = Get-Content -LiteralPath (Join-Path $script:Repo 'bootstrap.ps1') -Raw
        $bootstrap | Should -Match '^#Requires -Version 5\.1'
        $bootstrap | Should -Not -Match '(?m)^#Requires -PSEdition Core'
    }

    It 'declares the same contract in module manifests' {
        foreach ($file in Get-ChildItem (Join-Path $script:Repo 'dot_config/powershell/modules') -Recurse -Filter *.psd1) {
            $data = Import-PowerShellDataFile $file.FullName
            $data.PowerShellVersion | Should -Be '7.4'
            $data.CompatiblePSEditions | Should -Contain 'Core'
        }
    }

    It 'parses and dot-sources bootstrap under real Windows PowerShell 5.1 without installing anything' -Skip:(-not $IsWindows) {
        $path = (Join-Path $script:Repo 'bootstrap.ps1').Replace("'", "''")
        $probe = @'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile('__BOOTSTRAP__', [ref]$null, [ref]$errors)
if ($errors.Count) { $errors | Out-String | Write-Error; exit 1 }
. '__BOOTSTRAP__'
if ($PSVersionTable.PSVersion.Major -ne 5 -or -not (Get-Command Get-PwshRuntime)) { exit 2 }
'@.Replace('__BOOTSTRAP__', $path)
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $probe
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'profile function-scoped reloads' {
    It 'retains basic helpers and dynamic Git shortcuts outside reload/cas/cau scope' {
        $aliases = (Join-Path $script:Repo 'dot_config/powershell/profile.d/20_aliases.ps1').Replace("'", "''")
        $git = (Join-Path $script:Repo 'dot_config/powershell/profile.d/21_git.ps1').Replace("'", "''")
        $probe = @'
function Import-FixtureProfile {
    . '__ALIASES__'
    . '__GIT__'
}
Import-FixtureProfile
Import-FixtureProfile
foreach ($name in 'reload','cas','cau','which','run-for','git_current_branch','gswm','glol') {
    if (-not (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) { exit 3 }
}
'@.Replace('__ALIASES__', $aliases).Replace('__GIT__', $git)
        & (Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) -NoProfile -NonInteractive -Command $probe
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'WSL elevation argument serialization' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'scripts/enable-wsl.ps1'), [ref]$null, [ref]$null)
        $functionAst = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WslElevation'
        }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    It 'quotes paths with spaces and uses the current runtime without an invisible input wait' {
        Mock Start-Process {}
        Invoke-WslElevation -ScriptPath 'C:\Users\Test User\dot files\enable-wsl.ps1'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $PSHOME 'pwsh.exe') -and $Verb -eq 'RunAs' -and $Wait -and
            $WindowStyle -eq 'Hidden' -and
            $ArgumentList -eq '-NoProfile -NoLogo -NonInteractive -File "C:\Users\Test User\dot files\enable-wsl.ps1" -Elevated -Unattended'
        }
    }
}
