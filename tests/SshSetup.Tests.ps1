# Pester tests for the SSH setup fragment (profile.d/96_ssh_setup.ps1).
#
# Native pwsh counterpart of the Unix repo's tests/unit/ssh_setup.bats. Two
# real failures drove this file, mirrored here so both platforms are pinned
# down the same way:
#
#   1. A target reached via ProxyJump used to get set up ALONE — ssh(1)
#      tunnels through the jump host transparently, so the jump host kept
#      asking for a password on every connection.
#   2. A private key whose .pub half is missing needs to be repaired before
#      the install step, not discovered by it with a confusing error.
#
# The config parser (Find-SshHostBlock / Add-SshIdentityFile / ...) is tested
# against real temp files — fully deterministic, no external command needed,
# runs on macOS/Linux too. The ssh/jump-chain/remote-install logic goes
# through the fragment's own seam functions (Invoke-SshConfigQuery /
# Invoke-SshRemote / Invoke-SshPowerShell), which are mocked so no real ssh
# needs to be installed. Per the angle-bracket pitfall
# (pitfalls/pester-test-name-angle-brackets-command-not-found.md), no `It`/
# `Describe` title uses `<Name>` placeholders even with -TestCases.

BeforeDiscovery {
    # -Skip conditions are evaluated during discovery, before BeforeAll.
    $HaveSshKeygen = [bool](Get-Command ssh-keygen -ErrorAction SilentlyContinue)
}

BeforeAll {
    $Fragment = Join-Path $PSScriptRoot '..' 'dot_config' 'powershell' 'profile.d' '96_ssh_setup.ps1'
    . $Fragment

    function New-SshTestHome {
        $p = Join-Path ([IO.Path]::GetTempPath()) ('ssh-setup-t-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path (Join-Path $p '.ssh') | Out-Null
        $p
    }
}

Describe 'ssh-setup-remote fragment' {

    Context 'Split-SshHop' {
        It 'splits user@host:port' {
            $r = Split-SshHop -Spec 'user@host:2222'
            $r.Dest | Should -BeExactly 'user@host'
            $r.Port | Should -BeExactly '2222'
        }
        It 'splits an IPv6 literal with a port' {
            $r = Split-SshHop -Spec '[::1]:22'
            $r.Dest | Should -BeExactly '[::1]'
            $r.Port | Should -BeExactly '22'
        }
        It 'leaves a bare alias with no port' {
            $r = Split-SshHop -Spec 'plain'
            $r.Dest | Should -BeExactly 'plain'
            $r.Port | Should -BeExactly ''
        }
        It 'treats a non-numeric colon suffix as part of the host, not a port' {
            $r = Split-SshHop -Spec 'host:notaport'
            $r.Dest | Should -BeExactly 'host:notaport'
            $r.Port | Should -BeExactly ''
        }
    }

    Context 'Get-SshJumpChain' {
        BeforeAll {
            # Fixture table standing in for `ssh -G <host>`, mirroring the
            # bats stub on the Unix side so both suites exercise the same shapes.
            $script:JumpFixture = @{
                plain   = @('hostname plain')
                one     = @('proxyjump jump1')
                jump1   = @('hostname jump1')
                deep    = @('proxyjump mid')
                mid     = @('proxyjump jump1')
                multi   = @('proxyjump a,b:2222')
                a       = @('hostname a')
                b       = @('hostname b')
                nojump  = @('proxyjump none')
                cyc1    = @('proxyjump cyc2')
                cyc2    = @('proxyjump cyc1')
            }
            Mock -CommandName Invoke-SshConfigQuery {
                param($Target)
                if ($script:JumpFixture.ContainsKey($Target)) { return $script:JumpFixture[$Target] }
                return @("hostname $Target")
            }
        }

        It 'is empty for a host with no ProxyJump' {
            Get-SshJumpChain -Target 'plain' | Should -BeNullOrEmpty
        }
        It 'treats ProxyJump none as no hop' {
            Get-SshJumpChain -Target 'nojump' | Should -BeNullOrEmpty
        }
        It 'reports one jump host, target excluded' {
            @(Get-SshJumpChain -Target 'one') | Should -BeExactly @('jump1')
        }
        It 'resolves nested ProxyJump outermost-first' {
            @(Get-SshJumpChain -Target 'deep') | Should -BeExactly @('jump1', 'mid')
        }
        It 'keeps order and port suffixes for a comma-separated -J list' {
            @(Get-SshJumpChain -Target 'multi') | Should -BeExactly @('a', 'b:2222')
        }
        It 'terminates on a ProxyJump cycle and never lists the target itself' {
            @(Get-SshJumpChain -Target 'cyc1') | Should -BeExactly @('cyc2')
        }
    }

    Context 'local key discovery' {
        BeforeEach { $Home_ = New-SshTestHome }
        AfterEach { Remove-Item -Recurse -Force $Home_ -ErrorAction SilentlyContinue }

        It 'finds a private key with no .pub and flags it' -Skip:(!$HaveSshKeygen) {
            & ssh-keygen -q -t ed25519 -N '' -C 'test' -f (Join-Path $Home_ '.ssh/lonely') 2>$null
            Remove-Item (Join-Path $Home_ '.ssh/lonely.pub')
            $env:SSH_SETUP_HOME = $Home_
            try {
                $keys = @(Get-SshLocalKey)
                $keys.Count | Should -Be 1
                $keys[0].HasPub | Should -BeFalse
            } finally { Remove-Item Env:SSH_SETUP_HOME -ErrorAction SilentlyContinue }
        }

        It 'skips config, known_hosts and .DS_Store' -Skip:(!$HaveSshKeygen) {
            & ssh-keygen -q -t ed25519 -N '' -C 'test' -f (Join-Path $Home_ '.ssh/normal') 2>$null
            'x' | Set-Content (Join-Path $Home_ '.ssh/config')
            'x' | Set-Content (Join-Path $Home_ '.ssh/known_hosts')
            'x' | Set-Content (Join-Path $Home_ '.ssh/.DS_Store')
            $env:SSH_SETUP_HOME = $Home_
            try {
                $keys = @(Get-SshLocalKey)
                $keys.Count | Should -Be 1
                $keys[0].Path | Should -Match 'normal$'
            } finally { Remove-Item Env:SSH_SETUP_HOME -ErrorAction SilentlyContinue }
        }

        It 'regenerates a missing .pub matching ssh-keygen -y' -Skip:(!$HaveSshKeygen) {
            $k = Join-Path $Home_ '.ssh/k'
            & ssh-keygen -q -t ed25519 -N '' -C 'test' -f $k 2>$null
            $expected = (Get-Content "$k.pub") -split ' ' | Select-Object -First 2
            Remove-Item "$k.pub"
            $env:SSH_SETUP_ASSUME_YES = '1'
            try {
                Restore-SshPublicKey -KeyPath $k | Should -BeTrue
                Test-Path "$k.pub" | Should -BeTrue
                ((Get-Content "$k.pub") -split ' ' | Select-Object -First 2) | Should -BeExactly $expected
            } finally { Remove-Item Env:SSH_SETUP_ASSUME_YES -ErrorAction SilentlyContinue }
        }
    }

    Context '~/.ssh/config parsing (Find-SshHostBlock / Add-SshIdentityFile)' {
        BeforeEach {
            $Home_ = New-SshTestHome
            $env:SSH_CFG_ROOT = Join-Path $Home_ '.ssh/config'
            # Needed for the Include drop-in test: `~` in an Include pattern
            # expands via Get-SshSetupHome, not the real $HOME.
            $env:SSH_SETUP_HOME = $Home_
        }
        AfterEach {
            Remove-Item Env:SSH_CFG_ROOT -ErrorAction SilentlyContinue
            Remove-Item Env:SSH_SETUP_HOME -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $Home_ -ErrorAction SilentlyContinue
        }

        It 'returns nothing for an unknown alias' {
            Set-Content $env:SSH_CFG_ROOT ''
            Find-SshHostBlock -Alias 'nosuchhost' | Should -BeNullOrEmpty
        }

        It 'finds a Host defined in an Included drop-in' {
            New-Item -ItemType Directory -Path (Join-Path $Home_ '.ssh/config.d') | Out-Null
            Set-Content $env:SSH_CFG_ROOT 'Include ~/.ssh/config.d/*'
            Set-Content (Join-Path $Home_ '.ssh/config.d/host_box') @('Host box', '    HostName 10.0.0.1')
            $found = Find-SshHostBlock -Alias 'box'
            $found | Should -Not -BeNullOrEmpty
            $found.File | Should -Match 'host_box$'
            $found.HasIdentityFile | Should -BeFalse
        }

        It 'never matches a wildcard Host pattern' {
            Set-Content $env:SSH_CFG_ROOT @('Host *', '    IdentitiesOnly yes')
            Find-SshHostBlock -Alias '*' | Should -BeNullOrEmpty
        }

        It 'replace swaps the existing IdentityFile in place' {
            Set-Content $env:SSH_CFG_ROOT @('Host box', '    HostName 10.0.0.1', '    IdentityFile ~/.ssh/old')
            $ok = Add-SshIdentityFile -File $env:SSH_CFG_ROOT -Alias 'box' -KeyPath (Join-Path $Home_ '.ssh/new') -Action replace
            $ok | Should -BeTrue
            $lines = Get-Content $env:SSH_CFG_ROOT
            # Match on whole IdentityFile LINES, not a raw substring search —
            # a temp dir under macOS's /var/folders/ contains "old" itself
            # (fOLDers), which would false-positive a plain -match 'old'.
            $idfLines = @($lines | Where-Object { $_ -match '^\s*IdentityFile\s' })
            $idfLines.Count | Should -Be 1
            $idfLines[0] | Should -Match 'new$'
            $lines | Should -Contain '    HostName 10.0.0.1'
        }

        It 'add keeps both keys and --identities-only appends the flag' {
            Set-Content $env:SSH_CFG_ROOT @('Host box', '    IdentityFile ~/.ssh/old')
            $ok = Add-SshIdentityFile -File $env:SSH_CFG_ROOT -Alias 'box' -KeyPath (Join-Path $Home_ '.ssh/new') -Action add -IdentitiesOnly
            $ok | Should -BeTrue
            $content = Get-Content $env:SSH_CFG_ROOT -Raw
            $content | Should -Match 'IdentityFile.*old'
            $content | Should -Match 'IdentityFile.*new'
            $content | Should -Match 'IdentitiesOnly yes'
        }

        It 'preserves a ProxyJump line already in the block' {
            # The whole point of in-place editing — it must not disturb the jump wiring.
            Set-Content $env:SSH_CFG_ROOT @('Host zr', '    HostName 10.0.0.2', '    ProxyJump zr-windows')
            $ok = Add-SshIdentityFile -File $env:SSH_CFG_ROOT -Alias 'zr' -KeyPath (Join-Path $Home_ '.ssh/k') -Action insert
            $ok | Should -BeTrue
            $content = Get-Content $env:SSH_CFG_ROOT -Raw
            $content | Should -Match 'ProxyJump zr-windows'
            $content | Should -Match 'IdentityFile'
        }

        It 'add-include wires config.d in and is idempotent' {
            Set-Content $env:SSH_CFG_ROOT @('Host box', '    HostName 10.0.0.1')
            Test-SshConfigDInclude | Should -BeFalse
            Add-SshConfigDInclude | Should -BeTrue
            $lines = Get-Content $env:SSH_CFG_ROOT
            @($lines | Where-Object { $_ -match '^Include' }).Count | Should -Be 1
            Test-SshConfigDInclude | Should -BeTrue
            Add-SshConfigDInclude | Should -BeTrue
            $lines2 = Get-Content $env:SSH_CFG_ROOT
            @($lines2 | Where-Object { $_ -match '^Include' }).Count | Should -Be 1
        }
    }

    Context 'Windows remote install payloads' {
        # The PowerShell SOURCE sent to the remote contains BOTH the admin-file
        # and per-user branches as text unconditionally (it's a runtime `if`,
        # not templated out) — so asserting a branch's STRING is present/absent
        # tests nothing. What actually varies is the substituted admin flag
        # that picks which branch runs, so assert on that instead.
        It 'requests administrators_authorized_keys and an ACL reset when UseAdminFile is set' {
            Mock -CommandName Invoke-SshPowerShell {
                param($Dest, $SshArgs, $Script)
                $null = $Dest, $SshArgs
                $script:CapturedPs = $Script
                return @('added:remote', 'acl:remote')
            }
            $null = Install-SshKeyWindows -Dest 'winbox' -PublicKey 'ssh-ed25519 AAAA test' -UseAdminFile
            $script:CapturedPs | Should -Match "if \('1' -eq '1'\)"
            $script:CapturedPs | Should -Match 'icacls'
            $script:CapturedPs | Should -Match 'SYSTEM:F'
        }

        It 'requests the per-user authorized_keys when UseAdminFile is not set' {
            Mock -CommandName Invoke-SshPowerShell {
                param($Dest, $SshArgs, $Script)
                $null = $Dest, $SshArgs
                $script:CapturedPs = $Script
                return @('added:remote')
            }
            $null = Install-SshKeyWindows -Dest 'winbox' -PublicKey 'ssh-ed25519 AAAA test'
            $script:CapturedPs | Should -Match "if \('0' -eq '1'\)"
        }

        It 'doubles a single quote in the key comment for the PowerShell literal' {
            Mock -CommandName Invoke-SshPowerShell {
                param($Dest, $SshArgs, $Script)
                $null = $Dest, $SshArgs
                $script:CapturedPs = $Script
                return @('added:remote')
            }
            $null = Install-SshKeyWindows -Dest 'winbox' -PublicKey "ssh-ed25519 AAAA ada's box"
            $script:CapturedPs | Should -Match "ada''s box"
        }
    }

    Context 'Get-SshRemoteKind' {
        It 'reports posix when uname succeeds' {
            Mock -CommandName Invoke-SshRemote { return @('Linux') }
            (Get-SshRemoteKind -Dest 'box').Kind | Should -BeExactly 'posix'
        }

        It 'falls back to a PowerShell probe and reports admin + username' {
            Mock -CommandName Invoke-SshRemote { return @() }
            Mock -CommandName Invoke-SshPowerShell { return @('windows admin=1 user=Ada') }
            $r = Get-SshRemoteKind -Dest 'winbox'
            $r.Kind | Should -BeExactly 'windows'
            $r.Admin | Should -BeTrue
            $r.User | Should -BeExactly 'Ada'
        }

        It 'reports unknown when neither probe identifies the remote' {
            Mock -CommandName Invoke-SshRemote { return @() }
            Mock -CommandName Invoke-SshPowerShell { return @() }
            (Get-SshRemoteKind -Dest 'mystery').Kind | Should -BeExactly 'unknown'
        }
    }
}
