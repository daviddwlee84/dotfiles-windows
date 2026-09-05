#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:PackagePath = Join-Path $RepoRoot 'dot_config\yazi\package.toml'
    $script:InitPath = Join-Path $RepoRoot 'dot_config\yazi\init.lua'
    $script:ConfigPath = Join-Path $RepoRoot 'dot_config\yazi\yazi.toml'
    $script:GuardPath = Join-Path $RepoRoot 'dot_config\yazi\plugins\git-guard.yazi\main.lua'
    $script:TemplatePath = Join-Path $RepoRoot '.chezmoiscripts\run_after_16_yazi_plugins.ps1.tmpl'

    $rendered = & chezmoi execute-template --source $RepoRoot --file $TemplatePath | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'failed to render Yazi plugin installer' }
    $script:RenderedPath = Join-Path $TestDrive 'run_after_16_yazi_plugins.ps1'
    [IO.File]::WriteAllText($RenderedPath, $rendered, [Text.UTF8Encoding]::new($false))
    . $RenderedPath
}

Describe 'Yazi Git status integration' {
    It 'pins the reviewed latest git.yazi revision in a comment-free lockfile' {
        $package = Get-Content -Raw -LiteralPath $PackagePath
        $package | Should -Match 'use = "yazi-rs/plugins:git"'
        $package | Should -Match 'rev = "c591a36"'
        $package | Should -Match 'hash = "5bb0bfab901d3601c370eafdd66edd31"'
        $package | Should -Not -Match '(?m)^\s*#'
    }

    It 'uses fail-soft setup and a guarded file/directory fetcher pair' {
        $init = Get-Content -Raw -LiteralPath $InitPath
        $configLines = @(Get-Content -LiteralPath $ConfigPath)
        $guard = Get-Content -Raw -LiteralPath $GuardPath

        $init | Should -Match 'pcall\(function\(\)'
        $init | Should -Match 'require\("git"\):setup\(\{ order = 1500 \}\)'
        @($configLines | Where-Object { $_ -ceq 'id = "git"' }).Count | Should -Be 2
        @($configLines | Where-Object { $_ -ceq 'group = "git"' }).Count | Should -Be 2
        @($configLines | Where-Object { $_ -ceq 'run = "git-guard"' }).Count | Should -Be 2
        $guard | Should -Match 'pcall\(require, "git"\)'
        $guard | Should -Match 'require\("noop"\):fetch\(job\)'
    }

    It 'counts fetcher fields in <LineEnding> checkouts' -TestCases @(
        @{ LineEnding = 'LF'; Newline = "`n" }
        @{ LineEnding = 'CRLF'; Newline = "`r`n" }
    ) {
        param($LineEnding, $Newline)
        $null = $LineEnding
        $fixture = Join-Path $TestDrive 'yazi.toml'
        $content = (Get-Content -Raw -LiteralPath $ConfigPath) -replace "`r?`n", $Newline
        [IO.File]::WriteAllText($fixture, $content, [Text.UTF8Encoding]::new($false))
        $lines = @(Get-Content -LiteralPath $fixture)

        @($lines | Where-Object { $_ -ceq 'id = "git"' }).Count | Should -Be 2
        @($lines | Where-Object { $_ -ceq 'group = "git"' }).Count | Should -Be 2
        @($lines | Where-Object { $_ -ceq 'run = "git-guard"' }).Count | Should -Be 2
    }

    It 'derives plugin directory names from monorepo and standalone lock entries' {
        $package = Join-Path $TestDrive 'package.toml'
        @'
[[plugin.deps]]
use = "yazi-rs/plugins:git"
[[plugin.deps]]
use = "owner/standalone"
'@ | Set-Content -LiteralPath $package

        @(Get-YaziPluginNames -PackageFile $package) | Should -Be @('git.yazi', 'standalone.yazi')
    }

    It 'marks missing plugins and accepts materialized main.lua files' {
        $root = Join-Path $TestDrive 'config'
        $package = Join-Path $root 'package.toml'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        "[[plugin.deps]]`nuse = `"yazi-rs/plugins:git`"" | Set-Content -LiteralPath $package

        Test-YaziPluginsMissing -ConfigDir $root -PackageFile $package | Should -BeTrue
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'plugins\git.yazi') | Out-Null
        'return {}' | Set-Content -LiteralPath (Join-Path $root 'plugins\git.yazi\main.lua')
        Test-YaziPluginsMissing -ConfigDir $root -PackageFile $package | Should -BeFalse
    }

    It 'keeps the run-script fail-soft and explicitly sets YAZI_CONFIG_HOME' {
        $rendered = Get-Content -Raw -LiteralPath $RenderedPath
        $rendered | Should -Match '\$ErrorActionPreference = ''Continue'''
        $rendered | Should -Match '\$env:YAZI_CONFIG_HOME = \$configDir'
        $rendered | Should -Match 'exit 0'

        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseInput($rendered, [ref]$null, [ref]$parseErrors) | Out-Null
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'installs a missing plugin and stamps only after main.lua appears' {
        $testHome = Join-Path $TestDrive 'install-success-home'
        $cache = Join-Path $TestDrive 'install-success-cache'
        $config = Join-Path $testHome '.config\yazi'
        New-Item -ItemType Directory -Force -Path $config | Out-Null
        Copy-Item -LiteralPath $PackagePath -Destination (Join-Path $config 'package.toml')

        function global:yazi { }
        function global:ya {
            New-Item -ItemType Directory -Force -Path (Join-Path $env:YAZI_CONFIG_HOME 'plugins\git.yazi') | Out-Null
            'return {}' | Set-Content -LiteralPath (Join-Path $env:YAZI_CONFIG_HOME 'plugins\git.yazi\main.lua')
            $global:LASTEXITCODE = 0
        }

        try {
            Invoke-YaziPluginInstall -HomePath $testHome -CacheRoot $cache

            Test-Path -LiteralPath (Join-Path $cache 'chezmoi\yazi-plugins-lock') | Should -BeTrue
            $env:YAZI_CONFIG_HOME | Should -BeExactly $config
        } finally {
            Remove-Item -LiteralPath Function:\yazi, Function:\ya -ErrorAction SilentlyContinue
        }
    }

    It 'keeps installer failure non-fatal and leaves no success stamp' {
        $testHome = Join-Path $TestDrive 'install-failure-home'
        $cache = Join-Path $TestDrive 'install-failure-cache'
        $config = Join-Path $testHome '.config\yazi'
        New-Item -ItemType Directory -Force -Path $config | Out-Null
        Copy-Item -LiteralPath $PackagePath -Destination (Join-Path $config 'package.toml')

        function global:yazi { }
        function global:ya {
            Write-Error 'simulated ya failure' -ErrorAction Continue
            $global:LASTEXITCODE = 9
        }

        try {
            { Invoke-YaziPluginInstall -HomePath $testHome -CacheRoot $cache } | Should -Not -Throw
            Test-Path -LiteralPath (Join-Path $cache 'chezmoi\yazi-plugins-lock') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath Function:\yazi, Function:\ya -ErrorAction SilentlyContinue
        }
    }
}
