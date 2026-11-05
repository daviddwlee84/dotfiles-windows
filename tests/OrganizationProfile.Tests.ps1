#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    $utf8 = [Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
    $script:Repo = Split-Path $PSScriptRoot
    . (Join-Path $script:Repo 'scripts/organization-policy.ps1')
    . (Join-Path $script:Repo 'scripts/organization-packages.ps1')
    . (Join-Path $script:Repo 'bootstrap.ps1')
    $script:Catalog = (Get-Content -Raw (Join-Path $script:Repo '.chezmoidata/windows-tool-sources.json') | ConvertFrom-Json -AsHashtable).windowsToolSources
}

Describe 'Organization source decisions' {
    BeforeEach {
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; managedMachine = $true } -Catalog $script:Catalog
    }
    It 'defaults missing profile to legacy without conflating managedMachine' {
        Initialize-OrganizationPolicy -Data @{ managedMachine = $true } -Catalog $script:Catalog
        Test-MicrosoftOrganization | Should -BeFalse
        (Get-OrganizationSourceDecision scoop).Allowed | Should -BeTrue
    }
    It 'allows cataloged providers but never unknown or Scoop sources' {
        (Get-OrganizationSourceDecision git).Allowed | Should -BeTrue
        (Get-OrganizationSourceDecision pi).Allowed | Should -BeTrue
        (Get-OrganizationSourceDecision scoop).State | Should -Be blocked
        (Get-OrganizationSourceDecision imaginary).State | Should -Be pending-approval
        (Get-OrganizationSourceDecision herdr-plus -Operation build).Allowed | Should -BeFalse
    }
    It 'requires the existing corporate registry switch for corporate operations' {
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; managedMachine = $false } -Catalog $script:Catalog
        (Get-OrganizationSourceDecision pi).State | Should -Be blocked
    }
    It 'blocks direct package-runner calls before a public or Scoop attempt' {
        . (Join-Path $script:Repo 'scripts/package-source-runner.ps1')
        Mock Invoke-CapturedPackageProcess { throw 'No process should run' }
        $result = Invoke-PackageSourceCommand -Manager npm -Executable 'C:\Approved\node.exe' -Arguments @('--version') -Operation test -ManagedMachine $false -AllowPublicFallback $true
        $result.Succeeded | Should -BeFalse
        $result.Attempts.Count | Should -Be 0
        $result.FailureClass | Should -Be policy
        Should -Invoke Invoke-CapturedPackageProcess -Times 0
    }
    It 'accepts named approvals but not wildcard or unknown approvals' {
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; organizationSourceApprovals = @('yazi-plugins') } -Catalog $script:Catalog
        (Get-OrganizationSourceDecision yazi-plugins).Allowed | Should -BeTrue
        (Get-OrganizationSourceDecision nvim-plugins).Allowed | Should -BeFalse
        { Initialize-OrganizationPolicy -Data @{ organizationSourceApprovals = @('*') } -Catalog $script:Catalog } | Should -Throw
    }
    It 'does not make unsupported adapters installable by approval' {
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; organizationSourceApprovals = @('translate') } -Catalog $script:Catalog
        (Get-OrganizationSourceDecision translate).Allowed | Should -BeFalse
    }
    It 'preserves explicit false for personal tools and existing feature selection' {
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; installPersonalTools = $false; installHerdr = $true; installTranslate = $true } -Catalog $script:Catalog
        @(Get-OrganizationSelectedTools).id | Should -Not -Contain 'translate'
        @(Get-OrganizationSelectedTools).id | Should -Not -Contain 'dev-cli'
        @(Get-OrganizationSelectedTools).id | Should -Contain 'herdr'
    }
    It 'has unique IDs and exact identifiers for every enabled winget route' {
        @($script:Catalog.tools.id | Select-Object -Unique).Count | Should -Be $script:Catalog.tools.Count
        foreach ($tool in $script:Catalog.tools) {
            $tool.features.Count | Should -BeGreaterThan 0
            if ($tool.provider -eq 'winget') { $tool.packageId | Should -Match '^[A-Za-z0-9][A-Za-z0-9.+-]+$' }
            if ($tool.provider -in 'pending', 'approval', 'blocked') { $tool.reason | Should -Not -BeNullOrEmpty }
        }
    }
    It 'has a catalog classification for every Scoop package in the main installer' {
        $text = Get-Content -Raw (Join-Path $script:Repo '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl')
        $blocks = [regex]::Matches($text, '(?ms)^Scoop-Install @\((.*?)\)')
        foreach ($block in $blocks) {
            $withoutComments = $block.Groups[1].Value -replace '(?m)#.*$', ''
            foreach ($match in [regex]::Matches($withoutComments, "'([^']+)'")) {
                ($match.Groups[1].Value -split '/')[-1] | Should -BeIn $script:Catalog.tools.id
            }
        }
    }
}

Describe 'Organization runtime selection is metadata-only' {
    BeforeEach {
        $script:SavedEnvironment = @{}
        foreach ($key in 'PATH', 'SCOOP', 'SCOOP_GLOBAL', 'NVM_SYMLINK', 'LOCALAPPDATA', 'APPDATA', 'ProgramFiles', 'ProgramW6432', 'DOTFILES_ORGANIZATION_PROFILE', 'UV_PYTHON_DOWNLOADS', 'AZURE_EXTENSION_USE_DYNAMIC_INSTALL') {
            $script:SavedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
        }
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; managedMachine = $true } -Catalog $script:Catalog
    }
    AfterEach {
        foreach ($key in $script:SavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $script:SavedEnvironment[$key]) }
    }
    It 'removes custom/global Scoop entries but not similarly named sibling paths' {
        $env:SCOOP = Join-Path $TestDrive 'custom-scoop'
        $env:SCOOP_GLOBAL = Join-Path $TestDrive 'global-scoop'
        $keep = Join-Path $TestDrive 'custom-scoop-tools'
        $env:PATH = @((Join-Path $env:SCOOP 'shims'), (Join-Path $env:SCOOP_GLOBAL 'apps/node/current'), $keep) -join ';'
        Remove-OrganizationScoopPath
        $env:PATH | Should -Be $keep
    }
    It 'promotes the installed official archive CLI without duplicate PATH entries' {
        $env:ProgramFiles = Join-Path $TestDrive 'programs'
        $env:ProgramW6432 = $env:ProgramFiles
        $directory = Join-Path $env:ProgramFiles '7-Zip'
        New-Item -ItemType Directory -Force $directory | Out-Null
        New-Item -ItemType File (Join-Path $directory '7z.exe') | Out-Null
        Mock Resolve-OrganizationPython { $null }
        Set-OrganizationEnvironment
        Set-OrganizationEnvironment
        @($env:PATH -split ';' | Where-Object { $_ -eq $directory }).Count | Should -Be 1
    }
    It 'does not add an archive directory without its executable' {
        $env:ProgramFiles = Join-Path $TestDrive 'no-archive'
        $env:ProgramW6432 = $env:ProgramFiles
        Mock Resolve-OrganizationPython { $null }
        Set-OrganizationEnvironment
        @($env:PATH -split ';') | Should -Not -Contain (Join-Path $env:ProgramFiles '7-Zip')
    }
    It 'prefers the active NVM pair without running Node or npm' {
        $env:NVM_SYMLINK = Join-Path $TestDrive 'nvm-active'
        New-Item -ItemType Directory -Force (Join-Path $env:NVM_SYMLINK 'node_modules/npm/bin') | Out-Null
        foreach ($relative in 'node.exe', 'npm.cmd', 'node_modules/npm/bin/npm-cli.js') { New-Item -ItemType File -Path (Join-Path $env:NVM_SYMLINK $relative) | Out-Null }
        $layout = Get-OrganizationNpmLayout
        $layout.NodeExecutable | Should -Be (Join-Path $env:NVM_SYMLINK 'node.exe')
        $layout.NpmCommand | Should -Be (Join-Path $env:NVM_SYMLINK 'npm.cmd')
        $layout.Prefix | Should -Be (Join-Path $env:LOCALAPPDATA 'dotfiles/npm')
    }
    It 'refuses a disallowed explicit runtime instead of substituting a candidate' {
        $env:SCOOP = Join-Path $TestDrive 'scoop'
        $node = Join-Path $env:SCOOP 'node.exe'
        New-Item -ItemType Directory $env:SCOOP | Out-Null
        New-Item -ItemType File $node | Out-Null
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; nodeExecutable = $node } -Catalog $script:Catalog
        { Resolve-OrganizationNode } | Should -Throw '*disallowed*'
    }
}

Describe 'Organization install and upgrade adapters' {
    BeforeEach {
        Initialize-OrganizationPolicy -Data @{ organizationProfile = 'microsoft'; managedMachine = $true } -Catalog $script:Catalog
        Mock Set-OrganizationEnvironment {}
        Mock Resolve-OrganizationCommand { $null }
        Mock Resolve-OrganizationNode { $null }
        $script:GitTool = $script:Catalog.tools | Where-Object id -EQ git
    }
    It 'does not install a missing tool during upgrade' {
        Mock Invoke-OrganizationWingetProcess { [pscustomobject]@{ ExitCode = -1978335212; Output = 'No installed package' } }
        Invoke-OrganizationWinget -Tool $script:GitTool -Upgrade | Should -Be missing-not-upgraded
        Should -Invoke Invoke-OrganizationWingetProcess -Times 1 -Exactly
    }
    It 'does not treat an inventory failure as package absence' {
        Mock Invoke-OrganizationWingetProcess { [pscustomobject]@{ ExitCode = 5; Output = 'Access denied' } }
        { Invoke-OrganizationWinget -Tool $script:GitTool } | Should -Throw '*inventory failed*'
        Should -Invoke Invoke-OrganizationWingetProcess -Times 1 -Exactly
    }
    It 'never retries denied installs with another scope or source' {
        Mock Invoke-OrganizationWingetProcess {
            param($Arguments)
            if ($Arguments[0] -eq 'list') { return [pscustomobject]@{ ExitCode = -1978335212; Output = '' } }
            if ($Arguments[0] -eq 'show') { return [pscustomobject]@{ ExitCode = 0; Output = '' } }
            [pscustomobject]@{ ExitCode = 1625; Output = 'Policy denial' }
        }
        { Invoke-OrganizationWinget -Tool $script:GitTool } | Should -Throw '*no scope/source retry*'
        Should -Invoke Invoke-OrganizationWingetProcess -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'install' -and '--no-upgrade' -in $Arguments -and 'winget' -in $Arguments -and $StreamOutput }
    }
    It 'reports pending sources without invoking an installer' {
        Mock Invoke-OrganizationPackageAction { throw 'Must not install pending tools' }
        $result = @(Invoke-OrganizationPackages -Only pueue, gcc, uv-python)
        $result.Count | Should -Be 3
        @($result | Where-Object Status -NE 'pending-approval').Count | Should -Be 0
        Should -Invoke Invoke-OrganizationPackageAction -Times 0
    }
}

Describe 'Winget process progress diagnostics' {
    BeforeAll {
        function Invoke-FixtureWinget {
            param([string]$Mode)
            'download started'
            'installer started'
            if ($Mode -ne 'no-exit') { $global:LASTEXITCODE = 5 }
        }
    }
    BeforeEach {
        Mock Resolve-OrganizationCommand { 'Invoke-FixtureWinget' }
        Mock Write-Host {}
    }
    It 'streams installation progress while retaining output and failure status' {
        $result = Invoke-OrganizationWingetProcess -Arguments @('install') -StreamOutput
        $result.ExitCode | Should -Be 5
        $result.Output | Should -Be "download started`ninstaller started"
        Should -Invoke Write-Host -Times 2 -Exactly
    }
    It 'keeps metadata calls quiet' {
        $result = Invoke-OrganizationWingetProcess -Arguments @('list')
        $result.Output | Should -Match 'download started'
        Should -Invoke Write-Host -Times 0
    }
    It 'does not inherit a prior success when no native exit code is returned' {
        $global:LASTEXITCODE = 0
        (Invoke-OrganizationWingetProcess -Arguments @('no-exit')).ExitCode | Should -Be 126
    }
}

Describe 'Microsoft bootstrap boundary' {
    BeforeEach {
        Mock Update-BootstrapPath {}
        Mock Assert-UnattendedFreshState {}
        Mock Install-OrganizationBaselineTools {
            [pscustomobject]@{ PowerShellExecutable = 'C:\Approved\pwsh.exe'; PythonExecutable = 'C:\Approved\python.exe'; ChezmoiExecutable = 'C:\Approved\chezmoi.exe' }
        }
        Mock Get-BootstrapPowerShellOverride { $null }
        Mock Get-BootstrapPythonOverride { $null }
        Mock Resolve-BootstrapOrganizationCommand { param($Name) "C:\Approved\$Name.exe" }
        Mock Get-PwshRuntime { [pscustomobject]@{ Path = 'C:\Approved\pwsh.exe'; Version = '7.4.0'; PSEdition = 'Core' } }
        Mock Invoke-ChezmoiSetup {}
        Mock Initialize-Scoop { throw 'Scoop must not run' }
        Mock Set-ExecutionPolicy { throw 'Policy must not change' }
        $script:OriginalPath = $env:PATH
    }
    AfterEach { $env:PATH = $script:OriginalPath }
    It 'selects the branch before Scoop or execution-policy operations' {
        Invoke-Bootstrap -OrganizationProfile microsoft -Source $TestDrive
        Should -Invoke Initialize-Scoop -Times 0
        Should -Invoke Set-ExecutionPolicy -Times 0
        Should -Invoke Install-OrganizationBaselineTools -Times 1
        Should -Invoke Invoke-ChezmoiSetup -Times 1 -ParameterFilter { $OrganizationProfile -eq 'microsoft' -and $PowerShellExecutable -eq 'C:\Approved\pwsh.exe' }
    }
}

Describe 'Organization public command boundary' {
    It 'refuses a Scoop upgrade in a no-profile child before invoking either package manager' -Skip:(-not $IsWindows) {
        $bin = Join-Path $TestDrive 'fake-bin'
        New-Item -ItemType Directory $bin | Out-Null
        $dataPath = Join-Path $TestDrive 'policy.json'
        @{ organizationProfile = 'microsoft'; managedMachine = $true; windowsToolSources = $script:Catalog } |
            ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $dataPath
        Set-Content -LiteralPath (Join-Path $bin 'chezmoi.cmd') -Encoding ascii -Value '@type "%ORG_TEST_DATA%"'
        foreach ($name in 'scoop', 'winget') {
            Set-Content -LiteralPath (Join-Path $bin "$name.cmd") -Encoding ascii -Value '@echo invoked>"%ORG_TEST_MARKER%"'
        }
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $script:Repo 'scripts/upgrade-packages.ps1'), '-Action', 'Scoop')) { $start.ArgumentList.Add($argument) }
        $start.Environment['PATH'] = "$bin;$env:PATH"
        $start.Environment['ORG_TEST_DATA'] = $dataPath
        $start.Environment['ORG_TEST_MARKER'] = Join-Path $TestDrive 'manager-invoked'
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $out = $process.StandardOutput.ReadToEndAsync()
            $err = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Upgrade guard child timed out' }
            $process.ExitCode | Should -Not -Be 0
            ($out.GetAwaiter().GetResult() + $err.GetAwaiter().GetResult()) | Should -Match 'Scoop upgrades are disabled'
            (Join-Path $TestDrive 'manager-invoked') | Should -Not -Exist
        } finally { $process.Dispose() }
    }
}

Describe 'Organization template contracts' {
    BeforeAll {
        $root = Join-Path $TestDrive 'organization-render'
        New-Item -ItemType Directory -Force $root | Out-Null
        $script:TemplateArgs = @('--source', $script:Repo, '--config', (Join-Path $root 'config.toml'), '--persistent-state', (Join-Path $root 'state.db'), '--cache', (Join-Path $root 'cache'), '--destination', (Join-Path $root 'home'))
        & chezmoi init @script:TemplateArgs --no-tty --promptDefaults --promptChoice 'Role: workstation (full desktop) or minimal (shell only)=minimal' --promptString 'Your full name (git)=Test' --promptString 'Your git email=test@example.com'
        if ($LASTEXITCODE -ne 0) { throw 'Isolated organization test init failed.' }
    }
    It 'persists the bootstrap profile and runtime and restores its temporary environment' {
        $root = Join-Path $TestDrive 'microsoft-init'
        New-Item -ItemType Directory -Force $root | Out-Null
        $common = @('--source', $script:Repo, '--config', (Join-Path $root 'config.toml'), '--persistent-state', (Join-Path $root 'state.db'), '--cache', (Join-Path $root 'cache'), '--destination', (Join-Path $root 'home'))
        $before = $env:DOTFILES_BOOTSTRAP_ORGANIZATION_PROFILE
        $beforePwsh = $env:DOTFILES_BOOTSTRAP_POWERSHELL_EXECUTABLE
        $beforePython = $env:DOTFILES_BOOTSTRAP_PYTHON_EXECUTABLE
        $arguments = @('init') + $common + @(Get-UnattendedChezmoiArguments -Role workstation -Name Test -Email test@example.com -OrganizationProfile microsoft)
        $chezmoi = (Get-Command chezmoi -CommandType Application | Select-Object -First 1).Source
        Invoke-ChezmoiCommand -Path $chezmoi -ArgumentList $arguments -OrganizationProfile microsoft -PowerShellExecutable 'C:\Approved\pwsh.exe' -PythonExecutable 'C:\Approved\python.exe'
        $data = (& $chezmoi data @common --format json) | ConvertFrom-Json
        $data.organizationProfile | Should -Be microsoft
        $data.powerShellExecutable | Should -Be 'C:\Approved\pwsh.exe'
        $data.pythonExecutable | Should -Be 'C:\Approved\python.exe'
        $data.role | Should -Be workstation
        $data.installCodingAgents | Should -BeTrue
        $data.installHerdr | Should -BeTrue
        $data.managedMachine | Should -BeTrue
        $data.allowPublicPackageFallback | Should -BeFalse
        $env:DOTFILES_BOOTSTRAP_ORGANIZATION_PROFILE | Should -Be $before
        $env:DOTFILES_BOOTSTRAP_POWERSHELL_EXECUTABLE | Should -Be $beforePwsh
        $env:DOTFILES_BOOTSTRAP_PYTHON_EXECUTABLE | Should -Be $beforePython
    }
    It 'renders restricted externals and startup without unapproved downloads' {
        $override = @{ organizationProfile = 'microsoft'; powerShellExecutable = 'C:\Approved\pwsh.exe'; organizationSourceApprovals = @(); installCodingAgents = $true } | ConvertTo-Json -Compress
        $external = (Get-Content -Raw (Join-Path $script:Repo '.chezmoiexternal.toml.tmpl') | & chezmoi execute-template @script:TemplateArgs --override-data $override) -join "`n"
        $LASTEXITCODE | Should -Be 0
        $external | Should -Not -Match 'git-repo'
        $nvim = (Get-Content -Raw (Join-Path $script:Repo 'dot_config/nvim/init.lua.tmpl') | & chezmoi execute-template @script:TemplateArgs --override-data $override) -join "`n"
        $LASTEXITCODE | Should -Be 0
        $nvim | Should -Not -Match 'require\("config.lazy"\)'
        $nvim | Should -Match 'source approval is pending'
    }
    It 'parses the restricted installer, environment and config modifiers without executing them' {
        $data = (& chezmoi data @script:TemplateArgs --format json) | ConvertFrom-Json
        $full = @{ organizationProfile = 'microsoft'; powerShellExecutable = 'C:\Approved\pwsh.exe'; managedMachine = $true }
        foreach ($property in $data.PSObject.Properties | Where-Object Name -Like 'install*') { $full[$property.Name] = $true }
        $override = $full | ConvertTo-Json -Compress
        $templates = @(Get-ChildItem -LiteralPath $script:Repo -Recurse -File | Where-Object Name -Match '\.(ps1|psm1)\.tmpl$')
        $templates.Count | Should -BeGreaterThan 10
        foreach ($relative in @($templates | ForEach-Object { [IO.Path]::GetRelativePath($script:Repo, $_.FullName) })) {
            $text = (Get-Content -Raw (Join-Path $script:Repo $relative) | & chezmoi execute-template @script:TemplateArgs --override-data $override) -join "`n"
            $LASTEXITCODE | Should -Be 0 -Because $relative
            $errors = $null
            [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0 -Because $relative
        }
    }
    It 'retains deployed policy functions after a function-scoped reload' {
        $module = Join-Path $TestDrive 'OrganizationFixture.psm1'
        $override = @{ organizationProfile = 'microsoft'; managedMachine = $true } | ConvertTo-Json -Compress
        & chezmoi execute-template @script:TemplateArgs --override-data $override --file (Join-Path $script:Repo 'dot_config/powershell/modules/OrganizationPolicy/OrganizationPolicy.psm1.tmpl') --output $module
        $LASTEXITCODE | Should -Be 0
        $probe = Join-Path $TestDrive 'retained-policy.ps1'
        @'
function Load-Fixture { Import-Module '__MODULE__' -Global -Force }
Load-Fixture
Load-Fixture
if (-not (Test-MicrosoftOrganization)) { throw 'Profile state did not survive reload' }
if ((Get-OrganizationSourceDecision scoop).State -ne 'blocked') { throw 'Policy functions did not survive reload' }
'@.Replace('__MODULE__', $module.Replace("'", "''")) | Set-Content -LiteralPath $probe
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $probe
        $LASTEXITCODE | Should -Be 0
    }
    It 'keeps the restricted installer branch before unconditional legacy entry points' {
        $text = Get-Content -Raw (Join-Path $script:Repo '.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl')
        $text.IndexOf('Invoke-OrganizationPackages |') | Should -BeLessThan ([regex]::Match($text, '(?m)^Ensure-Scoop$').Index)
        $text | Should -Match '(?s)if \(Test-MicrosoftOrganization\).*?Invoke-OrganizationPackages.*?exit 0'
    }
}
