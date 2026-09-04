#Requires -Version 7

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot '.chezmoitemplates/package-sources.ps1'
    $SourceVariables = @(
        'PIP_INDEX_URL', 'UV_DEFAULT_INDEX', 'npm_config_registry', 'GOPROXY',
        'MISE_NODE_MIRROR_URL', 'RUSTUP_DIST_SERVER', 'RUSTUP_UPDATE_ROOT'
    )

    function Render-PackageSources {
        param([bool] $ManagedMachine, [bool] $UseChineseMirror)
        $data = @{
            managedMachine   = $ManagedMachine
            useChineseMirror = $UseChineseMirror
        } | ConvertTo-Json -Compress
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $TemplatePath
        if ($LASTEXITCODE -ne 0) { throw 'failed to render package-source policy' }
        $rendered -join "`n"
    }

    function Invoke-PackageSources {
        param(
            [bool] $ManagedMachine,
            [bool] $UseChineseMirror,
            [hashtable] $InitialValues = @{}
        )
        $previous = @{}
        foreach ($name in $SourceVariables) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        try {
            foreach ($name in $InitialValues.Keys) { [Environment]::SetEnvironmentVariable($name, $InitialValues[$name], 'Process') }
            & ([scriptblock]::Create((Render-PackageSources -ManagedMachine $ManagedMachine -UseChineseMirror $UseChineseMirror)))
            $result = [ordered]@{}
            foreach ($name in $SourceVariables) { $result[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
            $result
        } finally {
            foreach ($name in $SourceVariables) {
                if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
            }
        }
    }

    function Render-PackageInstaller {
        param(
            [bool] $ManagedMachine,
            [bool] $UseChineseMirror,
            [bool] $AllowFallback,
            [bool] $InstallHerdr = $false
        )
        $data = @{
            installCodingAgents = $true; installSpecstoryBuild = $false
            installWindowsApps = $false; installUtilityApps = $false; installGamingApps = $false
            installExtraRuntimes = $false; installMediaTools = $false; installLlmTools = $true
            installSummarize = $true
            installTunnelTools = $false; installIacTools = $false; installHerdr = $InstallHerdr
            installClink = $false; installTry = $true; installTranslate = $true
            installInputMethod = $false; useChineseMirror = $UseChineseMirror
            managedMachine = $ManagedMachine; allowPublicPackageFallback = $AllowFallback
            chezmoi = @{ username = 'ci' }
        } | ConvertTo-Json -Depth 5 -Compress
        $path = Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl'
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $path
        if ($LASTEXITCODE -ne 0) { throw 'failed to render package installer' }
        $rendered -join "`n"
    }
}

Describe 'shared package-source policy' {
    It 'uses company PyPI and npm registries on managed machines' {
        $values = Invoke-PackageSources -ManagedMachine $true -UseChineseMirror $false
        $values.PIP_INDEX_URL | Should -BeExactly 'https://packagefeedproxy.microsoft.io/pypi/simple/'
        $values.UV_DEFAULT_INDEX | Should -BeExactly 'https://packagefeedproxy.microsoft.io/pypi/simple/'
        $values.npm_config_registry | Should -BeExactly 'https://packagefeedproxy.microsoft.io/npm/'
        $values.GOPROXY | Should -BeNullOrEmpty
        $values.RUSTUP_DIST_SERVER | Should -BeNullOrEmpty
    }

    It 'keeps managed-machine policy ahead of China mirrors' {
        $values = Invoke-PackageSources -ManagedMachine $true -UseChineseMirror $true
        $values.PIP_INDEX_URL | Should -Match 'packagefeedproxy\.microsoft\.io'
        $values.npm_config_registry | Should -Match 'packagefeedproxy\.microsoft\.io'
        $values.GOPROXY | Should -BeNullOrEmpty
        $values.RUSTUP_DIST_SERVER | Should -BeNullOrEmpty
    }

    It 'uses China mirrors only on an unmanaged opted-in machine' {
        $values = Invoke-PackageSources -ManagedMachine $false -UseChineseMirror $true
        $values.PIP_INDEX_URL | Should -Match 'pypi\.tuna\.tsinghua\.edu\.cn'
        $values.npm_config_registry | Should -Match 'registry\.npmmirror\.com'
        $values.GOPROXY | Should -BeExactly 'https://goproxy.cn,direct'
        $values.RUSTUP_DIST_SERVER | Should -BeExactly 'https://rsproxy.cn'
        $values.MISE_NODE_MIRROR_URL | Should -BeNullOrEmpty
    }

    It 'removes repo-owned values when switching to official sources' {
        $values = Invoke-PackageSources -ManagedMachine $false -UseChineseMirror $false -InitialValues @{
            PIP_INDEX_URL = 'https://packagefeedproxy.microsoft.io/pypi/simple/'
            UV_DEFAULT_INDEX = 'https://pypi.tuna.tsinghua.edu.cn/simple'
            npm_config_registry = 'https://registry.npmmirror.com'
            GOPROXY = 'https://goproxy.cn,direct'
            MISE_NODE_MIRROR_URL = 'https://npmmirror.com/mirrors/node/'
            RUSTUP_DIST_SERVER = 'https://rsproxy.cn'
            RUSTUP_UPDATE_ROOT = 'https://rsproxy.cn/rustup'
        }
        foreach ($name in $SourceVariables) { $values[$name] | Should -BeNullOrEmpty }
    }

    It 'removes China-only values when switching to managed sources' {
        $values = Invoke-PackageSources -ManagedMachine $true -UseChineseMirror $true -InitialValues @{
            GOPROXY = 'https://goproxy.cn,direct'
            MISE_NODE_MIRROR_URL = 'https://npmmirror.com/mirrors/node/'
            RUSTUP_DIST_SERVER = 'https://rsproxy.cn'
            RUSTUP_UPDATE_ROOT = 'https://rsproxy.cn/rustup'
        }
        $values.PIP_INDEX_URL | Should -Match 'packagefeedproxy'
        $values.GOPROXY | Should -BeNullOrEmpty
        $values.MISE_NODE_MIRROR_URL | Should -BeNullOrEmpty
        $values.RUSTUP_DIST_SERVER | Should -BeNullOrEmpty
    }

    It 'preserves unrelated user or IT values in official mode' {
        $values = Invoke-PackageSources -ManagedMachine $false -UseChineseMirror $false -InitialValues @{
            PIP_INDEX_URL = 'https://packages.example.test/simple'
            npm_config_registry = 'https://npm.example.test/'
            GOPROXY = 'https://go.example.test,direct'
        }
        $values.PIP_INDEX_URL | Should -BeExactly 'https://packages.example.test/simple'
        $values.npm_config_registry | Should -BeExactly 'https://npm.example.test/'
        $values.GOPROXY | Should -BeExactly 'https://go.example.test,direct'
    }

    It 'is embedded by install-time, modify-time, and interactive-shell entry points' {
        Get-Content -Raw (Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl') |
            Should -Match 'template "package-sources\.ps1"'
        Get-Content -Raw (Join-Path $RepoRoot 'dot_config/herdr/modify_config.toml.ps1.tmpl') |
            Should -Match 'template "package-sources\.ps1"'
        Get-Content -Raw (Join-Path $RepoRoot 'dot_config/powershell/profile.d/05_mirrors.ps1.tmpl') |
            Should -Match 'template "package-sources\.ps1"'
    }
}

Describe 'package installer source policy' {
    It 'renders fallback policy into the run-onchange hash' {
        (Render-PackageInstaller -ManagedMachine $true -UseChineseMirror $false -AllowFallback $true) |
            Should -Match '\$allowPublicPackageFallback = \$true'
    }

    It 'never selects Ruby China when managed policy wins' {
        (Render-PackageInstaller -ManagedMachine $true -UseChineseMirror $true -AllowFallback $true) |
            Should -Not -Match 'gem install --clear-sources --source https://gems\.ruby-china\.com'
        (Render-PackageInstaller -ManagedMachine $false -UseChineseMirror $true -AllowFallback $false) |
            Should -Match 'gem install --clear-sources --source https://gems\.ruby-china\.com'
    }

    It 'wraps corporate-backed commands but leaves other ecosystems direct' {
        $script = Render-PackageInstaller -ManagedMachine $true -UseChineseMirror $false -AllowFallback $true -InstallHerdr $true
        $script | Should -Match 'Invoke-PackageSourceCommand -Manager npm'
        $script | Should -Match 'Invoke-PackageSourceCommand -Manager uv'
        $script | Should -Match 'uv python install --default --preview'
        $script | Should -Match 'Install-WindowsCliRelease -Name dev-cli'
        $script | Should -Not -Match 'Invoke-PackageSourceCommand -Manager go'
    }

    It 'passes the Herdr Plus repository before the non-interactive option' {
        $script = Get-Content -Raw (Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl')
        $script | Should -Match 'herdr plugin install cloudmanic/herdr-plus --yes'
        $script | Should -Not -Match 'herdr plugin install -y cloudmanic/herdr-plus'
    }
}
