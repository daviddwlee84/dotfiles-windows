#Requires -Version 7.4
#Requires -PSEdition Core

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../dot_config/powershell/modules/AppSource/AppSource.psd1') -Force
}

Describe 'appsrc local evidence' {
    InModuleScope AppSource {
        BeforeAll {
            function Add-FixtureFile([string]$Path, [string]$Body = '') {
                $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
                [IO.File]::WriteAllText($Path, $Body)
                $Path
            }
            function Add-ScoopFixture {
                $script:scoopExe = Add-FixtureFile (Join-Path $script:ctx.ScoopRoots[0] 'apps/lazygit/current/lazygit.exe')
                $null = Add-FixtureFile (Join-Path (Split-Path $script:scoopExe) 'manifest.json') '{"version":"2.0","bin":"lazygit.exe"}'
                $script:scoopShim = Add-FixtureFile (Join-Path $script:ctx.ScoopRoots[0] 'shims/lazygit.exe')
                $null = Add-FixtureFile ([IO.Path]::ChangeExtension($script:scoopShim, '.shim')) ('path = "' + $script:scoopExe + '"')
            }
        }
        BeforeEach {
            $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:ctx = [pscustomobject]@{
                PowerShellVersion = '7.4.0'; PSEdition = 'Core'
                ProcessPath = @(); PersistedPath = @(); PathExt = @('.ps1', '.com', '.exe', '.bat', '.cmd')
                ScoopRoots = @((Join-Path $script:root 'custom-scoop'), (Join-Path $script:root 'global-scoop'))
                ChocolateyRoot = Join-Path $script:root 'custom-choco'
                HomePath = Join-Path $script:root 'home'; AppData = Join-Path $script:root 'roaming'
                LocalAppData = Join-Path $script:root 'local'; WindowsRoot = Join-Path $script:root 'windows'
                VirtualEnv = ''; CondaPrefix = ''
            }
            Mock Get-SourceContext { $script:ctx }
            Mock Get-SourceInstallLocations { @() }
            Mock Get-SourceResolution { @() }
        }

        It 'finds two installations, not three shim/target files, using custom roots' {
            Add-ScoopFixture
            $chocoExe = Add-FixtureFile (Join-Path $script:ctx.ChocolateyRoot 'lib/lazygit/tools/lazygit.exe')
            $chocoShim = Add-FixtureFile (Join-Path $script:ctx.ChocolateyRoot 'bin/lazygit.exe')
            $null = Add-FixtureFile (Join-Path $script:ctx.ChocolateyRoot 'lib/lazygit/lazygit.nuspec') '<package><metadata><id>lazygit</id><version>1.0</version></metadata></package>'
            $null = Add-FixtureFile (Join-Path $script:ctx.ChocolateyRoot '.chocolatey/lazygit.1.0/.files') ('<fileSnapshot><files><file path="' + [Security.SecurityElement]::Escape($chocoExe) + '" /></files></fileSnapshot>')
            $script:ctx.ProcessPath = @((Split-Path $script:scoopShim), (Split-Path $chocoShim))
            $script:ctx.PersistedPath = @((Split-Path $chocoShim), (Split-Path $script:scoopShim))
            $report = Get-AppSourceReport -Name lazygit
            $g = $report.Groups[0]
            $g.Installations | Should -Be 2
            $g.Candidates | Should -HaveCount 3
            $g.ProcessPathCandidate | Should -Be $script:scoopShim
            $g.PersistedPathCandidate | Should -Be $chocoShim
            $g.Findings | Should -Contain 'process-vs-persisted-PATH'
            ($g.Candidates | Where-Object Path -eq $chocoShim).Confidence | Should -Be 'heuristic'
            ($g.Candidates | Where-Object Path -eq $script:scoopShim).Version | Should -Be '2.0'
        }

        It 'counts the package only once when its real binary directory is on PATH too' {
            Add-ScoopFixture
            $script:ctx.ProcessPath = @((Split-Path $script:scoopShim), (Split-Path $script:scoopExe))
            (Get-AppSourceReport -Name lazygit).Groups[0].Installations | Should -Be 1
            (Get-AppSourceReport -Conflicts).Groups | Should -HaveCount 0
        }

        It 'preserves alias metadata without printing or executing a function body' {
            Add-ScoopFixture
            Mock Get-SourceResolution { @([pscustomobject]@{CommandType='Alias';AliasTarget='lazygit.exe';Path=$null;ModuleName=''}) }
            $r = Get-AppSourceReport -Name lazygit
            $r.Groups[0].Findings | Should -Contain 'shell-wrapper'
            $r.Groups[0].Resolution[0].AliasTarget | Should -Be 'lazygit.exe'
        }

        It 'labels an active virtual environment and a Windows copy, without proposing removal' {
            $script:ctx.VirtualEnv = Join-Path $script:root '.venv'
            $a = Add-FixtureFile (Join-Path $script:ctx.VirtualEnv 'Scripts/python.exe')
            $b = Add-FixtureFile (Join-Path $script:ctx.WindowsRoot 'python.exe')
            $script:ctx.ProcessPath = @((Split-Path $a), (Split-Path $b))
            $r = Get-AppSourceReport -Name python
            ($r.Groups[0].Candidates | Where-Object Path -eq $a).ExpectedOverride | Should -BeTrue
            ($r.Groups[0].Candidates | Where-Object Path -eq $b).Manager | Should -Be 'Windows'
        }

        It 'never activates a WindowsApps alias and leaves its target unexpanded' {
            $alias = Add-FixtureFile (Join-Path $script:ctx.LocalAppData 'Microsoft/WindowsApps/python.exe')
            Mock Resolve-SourceTarget { throw 'must not resolve this app alias' }
            $r = Get-AppSourceReport -Path $alias
            $r.Groups[0].Candidates[0].Manager | Should -Be 'AppExecutionAlias'
            Should -Invoke Resolve-SourceTarget -Times 0 -Exactly
        }

        It 'reports a missing shim target while keeping valid metadata results' {
            Add-ScoopFixture
            [IO.File]::WriteAllText([IO.Path]::ChangeExtension($script:scoopShim, '.shim'), 'path = "missing-target.exe"')
            $r = Get-AppSourceReport -Name lazygit
            $r.Groups[0].Findings | Should -Contain 'unavailable-target'
            $r.Groups[0].Candidates[0].Status | Should -Be 'unavailable'
        }

        It 'keeps explicit missing paths as unavailable instead of claiming an installation' {
            $r = Get-AppSourceReport -Path (Join-Path $script:root 'gone.exe')
            $r.Groups[0].Installations | Should -Be 0
            $r.Groups[0].Candidates[0].Status | Should -Be 'unavailable'
        }

        It 'ignores missing files in stale Chocolatey snapshots' {
            $null = Add-FixtureFile (Join-Path $script:ctx.ChocolateyRoot 'lib/gone/gone.nuspec') '<package><metadata><version>1</version></metadata></package>'
            $null = Add-FixtureFile (Join-Path $script:ctx.ChocolateyRoot '.chocolatey/gone.1/.files') ('<fileSnapshot><files><file path="' + (Join-Path $script:root 'missing.exe') + '" /></files></fileSnapshot>')
            (Get-AppSourceReport).Groups | Should -HaveCount 0
        }

        It 'continues after invalid metadata with warnings in JSON rather than on stdout' {
            Add-ScoopFixture
            $null = Add-FixtureFile (Join-Path $script:ctx.ScoopRoots[1] 'apps/broken/current/manifest.json') '{bad'
            $json = Invoke-AppSource which lazygit -Json
            $r = $json | ConvertFrom-Json
            $r.SchemaVersion | Should -Be 1
            $r.Groups | Should -HaveCount 1
            $r.Warnings | Should -HaveCount 1
        }

        It 'merges standard npm cmd and ps1 launchers but never executes their contents' {
            $prefix = Join-Path $script:root 'node prefix'
            $cmd = Add-FixtureFile (Join-Path $prefix 'example.cmd') '"%dp0%\node_modules\example\cli.js"'
            $null = Add-FixtureFile (Join-Path $prefix 'example.ps1') 'throw "not executed"; & node "$basedir/node_modules/example/cli.js"'
            $null = Add-FixtureFile (Join-Path $prefix 'node_modules/example/cli.js') 'throw new Error("not executed")'
            $null = Add-FixtureFile (Join-Path $prefix 'node_modules/example/package.json') '{"name":"example","version":"3.0"}'
            $script:ctx.ProcessPath = @($prefix)
            $r = Get-AppSourceReport -Name example
            $r.Groups[0].Installations | Should -Be 1
            $r.Groups[0].Candidates | Should -HaveCount 2
            $r.Groups[0].Candidates[0].Manager | Should -Be 'npm'
            $r.Groups[0].Candidates[0].Version | Should -Be '3.0'
        }

        It 'does not mistake a similarly prefixed folder for a managed root' {
            Test-SourceChild (Join-Path $script:root 'scoop-malicious/bin') (Join-Path $script:root 'scoop') | Should -BeFalse
        }

        It 'honors an explicit executable extension while retaining alternate candidates' {
            $dir = Join-Path $script:root 'bin'
            $exe = Add-FixtureFile (Join-Path $dir 'example.exe')
            $null = Add-FixtureFile (Join-Path $dir 'example.ps1') 'throw "not executed"'
            $script:ctx.ProcessPath = @($dir)
            $r = Get-AppSourceReport -Name example.exe
            $r.Groups[0].ProcessPathCandidate | Should -Be $exe
            $r.Groups[0].Candidates | Should -HaveCount 2
        }

        It 'continues when one candidate cannot be inspected' {
            Add-ScoopFixture
            Mock Get-SourceCandidate { throw 'fixture access denied' } -ParameterFilter { $Path -eq $script:scoopShim }
            $r = Get-AppSourceReport -Name lazygit
            $r.Warnings[0] | Should -BeLike '*fixture access denied*'
        }

        It 'resolves ancestor junctions and reuses only per-invocation directory facts' -Skip:(-not $IsWindows) {
            $target = Join-Path $script:root 'physical'
            $leaf = Add-FixtureFile (Join-Path $target 'tool.exe')
            $link = Join-Path $script:root 'current'
            $null = New-Item -ItemType Junction -Path $link -Target $target
            $cache = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
            Resolve-SourceTarget (Join-Path $link 'tool.exe') -Cache $cache | Should -Be $leaf
            $cache.Count | Should -BeGreaterThan 0
            $cache.ContainsKey($leaf) | Should -BeFalse
        }

        It 'rejects DTD metadata instead of resolving external entities' {
            $file = Add-FixtureFile (Join-Path $script:root 'unsafe.xml') '<!DOCTYPE x [<!ENTITY x SYSTEM "file:///secret">]><x>&x;</x>'
            { Read-SourceXml $file } | Should -Throw
        }

        It 'returns shell-only and not-found lookups explicitly' {
            (Get-AppSourceReport -Name absent).Groups[0].Findings | Should -Contain 'not-found'
            Mock Get-SourceResolution { @([pscustomobject]@{CommandType='Function';Path=$null;AliasTarget=$null;ModuleName='Test'}) }
            (Get-AppSourceReport -Name wrapper).Groups[0].Findings | Should -Contain 'shell-only'
        }

        It 'does not treat registered installation metadata as proof of winget ownership' {
            $exe = Add-FixtureFile (Join-Path $script:root 'system-git/bin/git.exe')
            Mock Get-SourceInstallLocations { @([pscustomobject]@{Root=(Join-Path $script:root 'system-git');Name='Git';Version='1';Evidence='registry fixture'}) }
            $r = Get-AppSourceReport -Path $exe
            $r.Groups[0].Candidates[0].Manager | Should -Be 'RegisteredInstaller'
            $r.Groups[0].Candidates[0].Confidence | Should -Be 'heuristic'
        }
    }
}
