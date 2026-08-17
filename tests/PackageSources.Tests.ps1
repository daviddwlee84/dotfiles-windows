#Requires -Version 7

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot '.chezmoitemplates/package-sources.ps1'

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
}

Describe 'shared package-source policy' {
    It 'uses company PyPI and npm registries on managed machines' {
        $rendered = Render-PackageSources -ManagedMachine $true -UseChineseMirror $false
        $rendered | Should -Match 'packagefeedproxy\.microsoft\.io/pypi/simple/'
        $rendered | Should -Match 'packagefeedproxy\.microsoft\.io/npm/'
        $rendered | Should -Not -Match 'tuna|npmmirror|goproxy|rsproxy'
    }

    It 'keeps managed-machine policy ahead of China mirrors' {
        $rendered = Render-PackageSources -ManagedMachine $true -UseChineseMirror $true
        $rendered | Should -Match 'packagefeedproxy\.microsoft\.io/pypi/simple/'
        $rendered | Should -Not -Match 'tuna|npmmirror|goproxy|rsproxy'
    }

    It 'uses China mirrors only on an unmanaged opted-in machine' {
        $rendered = Render-PackageSources -ManagedMachine $false -UseChineseMirror $true
        $rendered | Should -Match 'pypi\.tuna\.tsinghua\.edu\.cn'
        $rendered | Should -Match 'registry\.npmmirror\.com'
        $rendered | Should -Match 'goproxy\.cn'
        $rendered | Should -Match 'rsproxy\.cn'
        $rendered | Should -Not -Match 'packagefeedproxy\.microsoft\.io'
    }

    It 'sets no registry overrides by default on an unmanaged machine' {
        $rendered = Render-PackageSources -ManagedMachine $false -UseChineseMirror $false
        $rendered | Should -Not -Match '\$env:(PIP_INDEX_URL|UV_DEFAULT_INDEX|npm_config_registry|GOPROXY)\s*='
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

Describe 'package installer command compatibility' {
    It 'passes the Herdr Plus repository before the non-interactive option' {
        $script = Get-Content -Raw (Join-Path $RepoRoot '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl')
        $script | Should -Match 'herdr plugin install cloudmanic/herdr-plus --yes'
        $script | Should -Not -Match 'herdr plugin install -y cloudmanic/herdr-plus'
    }
}
