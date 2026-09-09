#Requires -Version 7.4
#Requires -PSEdition Core

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
            chezmoi = @{ username = 'DOMAIN\ci'; homeDir = 'D:\Profiles\ci' }
        } | ConvertTo-Json -Depth 5 -Compress
        $path = Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl'
        $rendered = & chezmoi execute-template --source $RepoRoot --override-data $data --file $path
        if ($LASTEXITCODE -ne 0) { throw 'failed to render package installer' }
        $rendered -join "`n"
    }

    . (Join-Path $RepoRoot 'scripts/scoop-minimum-version.ps1')
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

    It 'renders the retry state key from homeDir rather than a domain username' {
        $script = Render-PackageInstaller -ManagedMachine $true -UseChineseMirror $false -AllowFallback $true
        $script | Should -Match ([regex]::Escape("state delete --bucket=entryState --key='D:/Profiles/ci/.chezmoiscripts/10_packages.ps1'; chezmoi apply"))
        $script | Should -Not -Match 'DOMAIN\\ci.+\.chezmoiscripts/10_packages\.ps1'
    }

    It 'embeds the Bun minimum-version migration into the package installer' {
        $script = Render-PackageInstaller -ManagedMachine $false -UseChineseMirror $false -AllowFallback $false
        $script | Should -Match 'function Ensure-ScoopMinimumVersion'
        $script | Should -Match "Ensure-ScoopMinimumVersion -App bun -MinimumVersion '1\.4\.0'"
    }
}

Describe 'Scoop minimum version helper' {
    It 'compares stable and prerelease versions semantically' {
        Test-ScoopMinimumVersion -Version '1.3.14' -MinimumVersion '1.4.0' | Should -BeFalse
        Test-ScoopMinimumVersion -Version '1.4.0-canary.1' -MinimumVersion '1.4.0' | Should -BeFalse
        Test-ScoopMinimumVersion -Version 'v1.4.0' -MinimumVersion '1.4.0' | Should -BeTrue
        Test-ScoopMinimumVersion -Version '1.10.0' -MinimumVersion '1.4.0' | Should -BeTrue
        Test-ScoopMinimumVersion -Version 'unknown' -MinimumVersion '1.4.0' | Should -BeFalse
    }

    It 'updates only an installed app below the floor and rechecks it' {
        $script:metadataCalls = 0
        $script:info = @()
        function global:scoop { $global:LASTEXITCODE = 0 }
        function global:Info($Message) { $script:info += $Message }
        function global:Register-Failure($Message) { throw "unexpected failure: $Message" }
        Mock Get-ScoopAppMetadata {
            $script:metadataCalls++
            [pscustomobject]@{ Name = 'bun'; Version = if ($script:metadataCalls -eq 1) { '1.3.14' } else { '1.4.0' } }
        }
        try {
            Ensure-ScoopMinimumVersion -App bun -MinimumVersion '1.4.0' | Should -BeTrue
            $script:metadataCalls | Should -Be 2
            $script:info[0] | Should -Match 'scoop update bun'
        } finally {
            Remove-Item Function:\scoop, Function:\Info, Function:\Register-Failure -ErrorAction SilentlyContinue
        }
    }

    It 'registers a nonfatal failure when the update remains below the floor' {
        $script:failure = $null
        function global:scoop { $global:LASTEXITCODE = 1 }
        function global:Info($Message) { $null = $Message }
        function global:Register-Failure($Message) { $script:failure = $Message }
        Mock Get-ScoopAppMetadata { [pscustomobject]@{ Name = 'bun'; Version = '1.3.14' } }
        try {
            Ensure-ScoopMinimumVersion -App bun -MinimumVersion '1.4.0' | Should -BeFalse
            $script:failure | Should -BeExactly 'scoop:bun'
        } finally {
            Remove-Item Function:\scoop, Function:\Info, Function:\Register-Failure -ErrorAction SilentlyContinue
        }
    }

    It 'registers a missing runtime after the core install attempt' {
        $script:failure = $null
        function global:Register-Failure($Message) { $script:failure = $Message }
        Mock Get-ScoopAppMetadata { $null }
        try {
            Ensure-ScoopMinimumVersion -App bun -MinimumVersion '1.4.0' | Should -BeFalse
            $script:failure | Should -BeExactly 'scoop:bun (requires >= 1.4.0; not installed)'
        } finally {
            Remove-Item Function:\Register-Failure -ErrorAction SilentlyContinue
        }
    }
}
