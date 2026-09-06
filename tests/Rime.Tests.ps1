#Requires -Version 7.4
#Requires -PSEdition Core

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $CoreTemplate = Join-Path $RepoRoot '.chezmoitemplates' 'weasel-core.ps1'
    $PackageTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_10_packages.ps1.tmpl'
    $DeployTemplate = Join-Path $RepoRoot '.chezmoiscripts' 'run_onchange_after_50_rime_deploy.ps1.tmpl'
    . ([scriptblock]::Create((Get-Content -Raw -LiteralPath $CoreTemplate)))

    function New-CompleteWeaselRoot([string] $Path) {
        $null = New-Item -ItemType Directory -Force -Path $Path
        $null = New-Item -ItemType File -Force -Path (
            (Join-Path $Path 'WeaselSetup.exe'),
            (Join-Path $Path 'WeaselDeployer.exe')
        )
        $Path
    }
}

Describe 'Weasel registry-view discovery' {
    BeforeEach {
        Mock Get-WeaselRegistryMetadata { $null }
    }

    It 'resolves a versioned root from the 64-bit registry view' {
        $root = New-CompleteWeaselRoot (Join-Path $TestDrive 'weasel-64')
        Mock Get-WeaselRegistryMetadata {
            if ($View -eq [Microsoft.Win32.RegistryView]::Registry64) {
                [pscustomobject]@{ RegistryView = $View; WeaselRoot = $root; InstallDir = 'C:\Rime' }
            }
        }

        $result = Resolve-WeaselInstallation
        $result.Root | Should -BeExactly $root
        $result.SetupPath | Should -BeExactly (Join-Path $root 'WeaselSetup.exe')
        Should -Invoke Get-WeaselRegistryMetadata -Times 1 -Exactly
    }

    It 'continues past stale Registry64 metadata to a valid Registry32 root' {
        $script:registry32Root = New-CompleteWeaselRoot (Join-Path $TestDrive 'weasel-32')
        Mock Get-WeaselRegistryMetadata {
            if ($View -eq [Microsoft.Win32.RegistryView]::Registry64) {
                [pscustomobject]@{ RegistryView = $View; WeaselRoot = 'C:\stale'; InstallDir = 'C:\stale-parent' }
            } else {
                [pscustomobject]@{ RegistryView = $View; WeaselRoot = $script:registry32Root; InstallDir = 'C:\Program Files\Rime' }
            }
        }

        $result = Resolve-WeaselInstallation
        $result.RegistryView | Should -Be ([Microsoft.Win32.RegistryView]::Registry32)
        $result.DeployerPath | Should -BeExactly (Join-Path $script:registry32Root 'WeaselDeployer.exe')
        Should -Invoke Get-WeaselRegistryMetadata -Times 2 -Exactly
    }

    It 'supports a legacy complete layout directly under InstallDir' {
        $root = New-CompleteWeaselRoot (Join-Path $TestDrive 'legacy')
        Mock Get-WeaselRegistryMetadata {
            [pscustomobject]@{ RegistryView = $View; WeaselRoot = ''; InstallDir = $root }
        }

        (Resolve-WeaselInstallation).Root | Should -BeExactly $root
    }

    It 'rejects partial executable layouts' {
        $root = Join-Path $TestDrive 'partial'
        $null = New-Item -ItemType Directory -Force -Path $root
        $null = New-Item -ItemType File -Force -Path (Join-Path $root 'WeaselSetup.exe')
        Mock Get-WeaselRegistryMetadata {
            [pscustomobject]@{ RegistryView = $View; WeaselRoot = $root; InstallDir = $root }
        }

        Resolve-WeaselInstallation | Should -BeNullOrEmpty
    }
}

Describe 'Rime package and deploy integration' {
    BeforeAll {
        $script:package = Get-Content -Raw -LiteralPath $PackageTemplate
        $script:deploy = Get-Content -Raw -LiteralPath $DeployTemplate
    }

    It 'embeds the shared resolver in both run scripts' {
        $package | Should -Match 'template "weasel-core\.ps1" \.'
        $deploy | Should -Match 'template "weasel-core\.ps1" \.'
        $package | Should -Not -Match 'template "weasel-core\.ps1" \.\s*\|\s*replace'
        $deploy | Should -Not -Match 'template "weasel-core\.ps1" \.\s*\|\s*replace'
        $package | Should -Match '\$installation = Resolve-WeaselInstallation'
        $deploy | Should -Match '\$installation = Resolve-WeaselInstallation'
        $package | Should -Not -Match 'Get-ItemProperty.+SOFTWARE\\Rime\\Weasel'
        $deploy | Should -Not -Match 'Get-ItemProperty.+SOFTWARE\\Rime\\Weasel'
    }

    It 'uses resolver-owned paths and retains Traditional registration' {
        $package | Should -Match "winget install --id Rime\.Weasel -e --silent --custom '/T'"
        $package | Should -Match '& \$installation\.SetupPath /lt'
        $package | Should -Match '& \$installation\.SetupPath /toggleascii'
        $package | Should -Not -Match "Join-Path.+WeaselSetup\.exe"
    }

    It 'uses the resolved deployer and remains nonfatal' {
        $deploy | Should -Match 'Start-Process -FilePath \$installation\.DeployerPath'
        $deploy | Should -Not -Match "Join-Path.+WeaselDeployer\.exe"
        $deploy | Should -Match '(?s)catch \{.*?Rime deploy error:.*?\}\s*exit 0'
    }

    It 'renders with one valid Requires directive of each kind' {
        $data = @{ installInputMethod = $true } | ConvertTo-Json -Compress
        $rendered = (& chezmoi execute-template --source $RepoRoot --override-data $data --file $DeployTemplate) -join "`n"
        $LASTEXITCODE | Should -Be 0

        $errors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseInput(
            $rendered,
            [ref] $null,
            [ref] $errors
        )
        $errors | Should -BeNullOrEmpty
        [regex]::Matches($rendered, '(?m)^#Requires -Version 7\.4$').Count | Should -Be 1
        [regex]::Matches($rendered, '(?m)^#Requires -PSEdition Core$').Count | Should -Be 1
    }
}
