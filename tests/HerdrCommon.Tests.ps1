#Requires -Version 7.4
#Requires -PSEdition Core
# Pester tests for the herdr keybind helpers' shared library
# (dot_config/herdr/_common.ps1).
#
# These are REGRESSION tests for three bugs that actually shipped, in the order
# they were found:
#
#   1. herdr on the Windows preview does NOT expand $VAR inside a
#      [[keys.command]] string, so a keybind written as `... "$HERDR_ACTIVE_PANE_ID"`
#      handed the script the LITERAL text. Resolve-HerdrPane / Resolve-HerdrCwd
#      must skip any unexpanded `$*` placeholder and fall through to the env var
#      herdr DID inject.
#   2. A CLI/server protocol mismatch surfaced as a generic "failed to read pane
#      <id>", hiding the trivial fix (relaunch herdr). Detection was added.
#   3. *** THE ONE THAT MATTERS *** that detection scanned the PANE'S OWN TEXT
#      for the marker string "protocol_mismatch". A pane merely DISPLAYING that
#      word (someone debugging herdr — i.e. the exact session that produced this
#      code) was misread as a broken server. Only a FAILED command's output, or
#      stderr, may be treated as diagnostics.
#
# Everything is stubbed: the suite must pass on windows-latest with no herdr
# installed and no herdr server running, and must never contact a real server
# (the author keeps a live session with ~20 panes of running agents).
#
# HOW THE STUB WORKS
# `& herdr` resolves through the scope chain, and a *function* beats an
# application, so a `function herdr` defined next to the dot-sourced helpers
# intercepts every call — including `Get-Command herdr` in Test-HerdrPresent.
# The stub reproduces what pwsh 7.6.3 measurably does to a native command under
# `@(& cmd 2>&1)`: one [ErrorRecord] per stderr LINE, plain [String] per stdout
# line, and $LASTEXITCODE left intact by the array wrap. That last property was
# verified against a control matrix (exit 0/1/7/42, with and without stdout).
# The `cmd.exe` context at the bottom is the control that pins the stub's
# fidelity to the real thing.
#
# Empirically, on herdr 0.7.5-preview: BOTH failure classes write to stderr and
# leave stdout at zero bytes, and both exit 1. An unreachable socket yields a
# NON-JSON Rust line (`Error: Os { code: 2, kind: NotFound, ... }`, with an
# OS-LOCALIZED message — never match on its wording); a server-side error yields
# the structured object. A SUCCESSFUL call writes nothing at all to stderr,
# which is why the stderr substring scan cannot false-positive today.

BeforeDiscovery {
    # -Skip is evaluated during discovery, so the probe has to live here.
    $HaveCmd = [bool](Get-Command cmd.exe -ErrorAction SilentlyContinue)
}

BeforeAll {
    # Belt and braces. Command resolution should always find the stub below, but
    # if it ever did not, this points the real CLI at a socket that cannot exist
    # so no live server is reachable from this process.
    $script:SavedEnv = @{
        Socket = $env:HERDR_SOCKET_PATH
        Active = $env:HERDR_ACTIVE_PANE_ID
        Pane   = $env:HERDR_PANE_ID
        Cwd    = $env:HERDR_ACTIVE_PANE_CWD
    }
    $env:HERDR_SOCKET_PATH = Join-Path ([IO.Path]::GetTempPath()) 'herdr-tests-nonexistent.sock'

    . (Join-Path $PSScriptRoot '..' 'dot_config' 'herdr' '_common.ps1')

    # ---- test doubles -------------------------------------------------------

    # What pwsh materialises for each stderr line of a native command under 2>&1.
    function New-StubStderrLine {
        param([string] $Line)
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($Line),
            'NativeCommandError',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $null)
    }

    # THE STUB. A simple (non-advanced) function so `$args` swallows herdr's
    # `--source` / `--format` flags verbatim instead of the parameter binder
    # trying to match them.
    function herdr {
        $script:HerdrStub.Calls += , @($args | ForEach-Object { [string]$_ })
        foreach ($line in $script:HerdrStub.Out) { Write-Output ([string]$line) }
        foreach ($line in $script:HerdrStub.Err) { Write-Output (New-StubStderrLine $line) }
        # A function cannot set $LASTEXITCODE implicitly; assign it the way the
        # native command would. _common.ps1 reads it unscoped, so global wins.
        $global:LASTEXITCODE = $script:HerdrStub.Exit
    }

    # Show-HerdrStaleServer sleeps 5s to hold a closing pane open, and
    # Show-HerdrNotice 1.5s. Shadow the cmdlet so the suite stays instant.
    function Start-Sleep {
        param([Parameter(Position = 0)] [double] $Seconds, [int] $Milliseconds)
        $script:HerdrSleptSeconds += $Seconds + ($Milliseconds / 1000)
    }

    # Capture the operator-facing diagnostics instead of printing them: whether
    # the stale-server banner fired is the whole point of bug #3.
    function Write-Host {
        param(
            [Parameter(Position = 0, ValueFromRemainingArguments)] [object[]] $Object,
            [switch] $NoNewline,
            [object] $Separator,
            [object] $ForegroundColor,
            [object] $BackgroundColor
        )
        $script:HerdrHostLines += (@($Object) | ForEach-Object { [string]$_ }) -join ' '
    }

    # ---- helpers (defined here so every $script: touch happens in ONE scope) --

    function Set-HerdrStub {
        param([string[]] $Out = @(), [string[]] $Err = @(), [int] $Exit = 0)
        $script:HerdrStub = @{ Out = @($Out); Err = @($Err); Exit = $Exit; Calls = @() }
        $script:HerdrHostLines = @()
        $script:HerdrSleptSeconds = 0
        # _common.ps1 latches its banner to once-per-process; unlatch per test.
        $script:HerdrStaleServerWarned = $false
        $global:LASTEXITCODE = 0
    }
    function Get-HerdrStubCalls { , @($script:HerdrStub.Calls) }
    function Get-HerdrHostText { (@($script:HerdrHostLines) -join "`n") }
    function Test-HerdrWarnedStale { [bool]$script:HerdrStaleServerWarned }

    function Set-HerdrPaneEnv {
        param([string] $ActivePaneId, [string] $PaneId, [string] $ActiveCwd)
        $env:HERDR_ACTIVE_PANE_ID = $ActivePaneId
        $env:HERDR_PANE_ID = $PaneId
        $env:HERDR_ACTIVE_PANE_CWD = $ActiveCwd
    }

    # ---- fixtures -----------------------------------------------------------

    # The real payload recorded in
    # pitfalls/herdr-keybind-failed-to-read-pane-protocol-mismatch.md.
    $script:ProtocolErrJson = '{"id":"cli:pane:list","error":{"code":"protocol_mismatch","message":"client protocol 17 is newer than server protocol 16; restart the Herdr server and try again"}}'
    $script:PaneNotFoundJson = '{"error":{"code":"pane_not_found","message":"pane no-such-pane-zzz not found"},"id":"cli:pane:read"}'
    # An unreachable socket is NOT JSON at all, and the message is OS-localized.
    $script:SocketErrLine = 'Error: Os { code: 2, kind: NotFound, message: "The system cannot find the file specified." }'

    # A pane showing this troubleshooting session. Every line here is user data.
    $script:PoisonPaneText = @(
        'PS C:\Code> herdr pane read w1:p6',
        'debugging the keybind: the server was reporting',
        $script:ProtocolErrJson,
        'client protocol 17 is newer than server protocol 16; restart the Herdr server',
        'fixed by relaunching herdr. protocol_mismatch gone.',
        'PS C:\Code>'
    )

    $script:TempCwd = Join-Path ([IO.Path]::GetTempPath()) "herdr-t-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Force -Path $script:TempCwd | Out-Null

    Set-HerdrStub
}

AfterAll {
    Remove-Item -Recurse -Force $script:TempCwd -ErrorAction SilentlyContinue
    $env:HERDR_SOCKET_PATH = $script:SavedEnv.Socket
    $env:HERDR_ACTIVE_PANE_ID = $script:SavedEnv.Active
    $env:HERDR_PANE_ID = $script:SavedEnv.Pane
    $env:HERDR_ACTIVE_PANE_CWD = $script:SavedEnv.Cwd
}

Describe 'herdr _common.ps1' {

    BeforeEach {
        Set-HerdrStub
        Set-HerdrPaneEnv -ActivePaneId $null -PaneId $null -ActiveCwd $null
    }

    Context 'the stub really is what gets called (no real herdr, ever)' {
        It 'resolves herdr to a function, not the installed executable' {
            (Get-Command herdr).CommandType | Should -Be 'Function'
        }
        It 'satisfies Test-HerdrPresent without herdr being installed' {
            Test-HerdrPresent | Should -BeTrue
        }
    }

    Context 'Resolve-HerdrPane (bug #1: unexpanded $VAR from a keybind)' {
        It 'returns the env var, not the literal "$HERDR_ACTIVE_PANE_ID"' {
            # The regression: herdr handed the script the placeholder verbatim,
            # which was then used as a pane id and every read failed.
            Set-HerdrPaneEnv -ActivePaneId 'w1:p6'
            Resolve-HerdrPane -PaneId '$HERDR_ACTIVE_PANE_ID' | Should -BeExactly 'w1:p6'
        }
        It 'skips a placeholder that leaked into the env var itself' {
            Set-HerdrPaneEnv -ActivePaneId '$HERDR_ACTIVE_PANE_ID' -PaneId 'w9:p9'
            Resolve-HerdrPane -PaneId '$HERDR_ACTIVE_PANE_ID' | Should -BeExactly 'w9:p9'
        }
        It 'never asks the server when a placeholder is recoverable from the env' {
            Set-HerdrPaneEnv -ActivePaneId 'w1:p6'
            $null = Resolve-HerdrPane -PaneId '$HERDR_ACTIVE_PANE_ID'
            (Get-HerdrStubCalls).Count | Should -Be 0
        }
        It 'prefers an explicit real id over the env var' {
            Set-HerdrPaneEnv -ActivePaneId 'w1:p6'
            Resolve-HerdrPane -PaneId 'w2:p3' | Should -BeExactly 'w2:p3'
        }
        It 'falls back to $HERDR_ACTIVE_PANE_ID for an empty id' {
            Set-HerdrPaneEnv -ActivePaneId 'w1:p6' -PaneId 'w9:p9'
            Resolve-HerdrPane -PaneId '' | Should -BeExactly 'w1:p6'
        }
        It 'falls back to the ambient $HERDR_PANE_ID when the keybind var is unset' {
            Set-HerdrPaneEnv -PaneId 'w9:p9'
            Resolve-HerdrPane -PaneId '' | Should -BeExactly 'w9:p9'
        }
        It 'falls through to `herdr pane current` when nothing is in the env' {
            Set-HerdrStub -Out '{"result":{"pane":{"pane_id":"w3:p1"}}}'
            Resolve-HerdrPane -PaneId '' | Should -BeExactly 'w3:p1'
            (Get-HerdrStubCalls)[0] -join ' ' | Should -BeExactly 'pane current'
        }
        It 'returns $null when the server cannot answer either' {
            Set-HerdrStub -Err $script:PaneNotFoundJson -Exit 1
            Resolve-HerdrPane -PaneId '' | Should -BeNullOrEmpty
        }
    }

    Context 'Resolve-HerdrCwd (bug #1: unexpanded $VAR from a keybind)' {
        It 'ignores the literal "$HERDR_ACTIVE_PANE_CWD" and uses the env var' {
            Set-HerdrPaneEnv -ActiveCwd $script:TempCwd
            Resolve-HerdrCwd -Cwd '$HERDR_ACTIVE_PANE_CWD' | Should -BeExactly $script:TempCwd
        }
        It 'prefers an explicit existing path' {
            Set-HerdrPaneEnv -ActiveCwd ([IO.Path]::GetTempPath())
            Resolve-HerdrCwd -Cwd $script:TempCwd | Should -BeExactly $script:TempCwd
        }
        It 'ignores an explicit path that does not exist' {
            Set-HerdrPaneEnv -ActiveCwd $script:TempCwd
            Resolve-HerdrCwd -Cwd (Join-Path $script:TempCwd 'no-such-dir') |
                Should -BeExactly $script:TempCwd
        }
        It 'asks the pane for its foreground cwd when the env is empty' {
            Set-HerdrStub -Out ('{"result":{"pane":{"foreground_cwd":"' +
                ($script:TempCwd -replace '\\', '\\') + '"}}}')
            Resolve-HerdrCwd -Cwd '$HERDR_ACTIVE_PANE_CWD' -PaneId 'w1:p6' |
                Should -BeExactly $script:TempCwd
            (Get-HerdrStubCalls)[0] -join ' ' | Should -BeExactly 'pane get w1:p6'
        }
        It 'ends at the process cwd, without calling herdr, when there is no pane' {
            Resolve-HerdrCwd -Cwd '$HERDR_ACTIVE_PANE_CWD' -PaneId '' |
                Should -BeExactly (Get-Location).Path
            (Get-HerdrStubCalls).Count | Should -Be 0
        }
    }

    Context 'Get-HerdrPaneText (bug #3: pane CONTENT is not diagnostics)' {
        # This is the false positive that shipped. A pane displaying the word
        # "protocol_mismatch" — a shell showing this very troubleshooting
        # session — was reported as a broken server, and the user's real pane
        # text was thrown away. It must never regress.
        It 'returns text containing "protocol_mismatch" verbatim on a successful read' {
            Set-HerdrStub -Out $script:PoisonPaneText -Exit 0
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeExactly ($script:PoisonPaneText -join "`n")
        }
        It 'does not warn about a stale server for that pane' {
            Set-HerdrStub -Out $script:PoisonPaneText -Exit 0
            $null = Get-HerdrPaneText -PaneId 'w1:p6'
            Test-HerdrWarnedStale | Should -BeFalse
            Get-HerdrHostText | Should -Not -Match 'protocol versions differ'
        }
        It 'does not stall the pane on a bogus 5-second hold' {
            Set-HerdrStub -Out $script:PoisonPaneText -Exit 0
            $null = Get-HerdrPaneText -PaneId 'w1:p6'
            $script:HerdrSleptSeconds | Should -Be 0
        }
        It 'is not fooled by a whole error object sitting in the pane buffer' {
            # The strongest form: the pane's only content IS the error payload,
            # e.g. someone cat'ing the pitfall doc.
            Set-HerdrStub -Out $script:ProtocolErrJson -Exit 0
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeExactly $script:ProtocolErrJson
            Test-HerdrWarnedStale | Should -BeFalse
        }
        It 'passes the documented argument vector through to the CLI' {
            Set-HerdrStub -Out 'hello'
            $null = Get-HerdrPaneText -PaneId 'w1:p6' -Source 'recent-unwrapped'
            (Get-HerdrStubCalls)[0] -join ' ' |
                Should -BeExactly 'pane read w1:p6 --source recent-unwrapped --format text'
        }
        It 'defaults to the visible source' {
            Set-HerdrStub -Out 'hello'
            $null = Get-HerdrPaneText -PaneId 'w1:p6'
            (Get-HerdrStubCalls)[0] -join ' ' | Should -Match '--source visible'
        }
        It 'returns $null for an empty read' {
            Set-HerdrStub
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-HerdrPaneText (bug #2: a REAL protocol mismatch is still caught)' {
        It 'returns $null and names the mismatch when the CLI fails' {
            # Measured shape: exit 1, structured object on STDERR, stdout empty.
            Set-HerdrStub -Err $script:ProtocolErrJson -Exit 1
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeTrue
            Get-HerdrHostText | Should -Match 'protocol versions differ'
        }
        It 'tells the user how to fix it (relaunch, then check the CLI path)' {
            Set-HerdrStub -Err $script:ProtocolErrJson -Exit 1
            $null = Get-HerdrPaneText -PaneId 'w1:p6'
            $text = Get-HerdrHostText
            $text | Should -Match 'relaunch'
            $text | Should -Match 'herdr --version'
        }
        It 'also catches the prose form with no machine-readable code' {
            Set-HerdrStub -Err 'client protocol 17 is newer than server protocol 16' -Exit 1
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeTrue
        }
        It 'catches a mismatch reported on stdout of a FAILED call' {
            # Defence in depth: 0.7.5-preview puts the payload on stderr, but a
            # failed call's stdout is by definition not pane text either.
            Set-HerdrStub -Out $script:ProtocolErrJson -Exit 1
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeTrue
        }
        It 'returns $null WITHOUT blaming the protocol for an unrelated failure' {
            Set-HerdrStub -Err $script:PaneNotFoundJson -Exit 1
            Get-HerdrPaneText -PaneId 'no-such-pane-zzz' | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeFalse
        }
        It 'survives the non-JSON failure class (unreachable socket)' {
            # No structured object exists in this class, and the OS message is
            # localized — anything that assumes JSON on failure breaks here.
            Set-HerdrStub -Err $script:SocketErrLine -Exit 1
            Get-HerdrPaneText -PaneId 'w1:p6' | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeFalse
        }
    }

    Context 'Invoke-HerdrJson' {
        It 'parses a success payload' {
            Set-HerdrStub -Out '{"result":{"panes":[{"pane_id":"w1:p6"},{"pane_id":"w1:p7"}]}}'
            $j = Invoke-HerdrJson pane list
            $j.result.panes[0].pane_id | Should -BeExactly 'w1:p6'
            $j.result.panes.Count | Should -Be 2
        }
        It 'forwards every argument verbatim' {
            Set-HerdrStub -Out '{"result":{}}'
            $null = Invoke-HerdrJson pane read w1:p6 --source visible --format json
            (Get-HerdrStubCalls)[0] -join ' ' |
                Should -BeExactly 'pane read w1:p6 --source visible --format json'
        }
        It 'returns $null for a structured {"error":{"code":...}} response' {
            Set-HerdrStub -Out $script:PaneNotFoundJson -Exit 1
            Invoke-HerdrJson pane get no-such-pane-zzz | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeFalse
        }
        It 'returns $null and warns for a structured protocol_mismatch' {
            Set-HerdrStub -Err $script:ProtocolErrJson -Exit 1
            Invoke-HerdrJson pane list | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeTrue
        }
        It 'is not fooled by a pane TITLE containing the marker (bug #3, JSON path)' {
            # The other half of bug #3: `pane list` payloads carry user-chosen
            # titles. A successful list must parse, not trip the detector.
            Set-HerdrStub -Out '{"result":{"panes":[{"pane_id":"w1:p6","title":"debugging protocol_mismatch"}]}}'
            $j = Invoke-HerdrJson pane list
            $j.result.panes[0].title | Should -BeExactly 'debugging protocol_mismatch'
            Test-HerdrWarnedStale | Should -BeFalse
        }
        It 'returns $null for the non-JSON socket failure' {
            Set-HerdrStub -Err $script:SocketErrLine -Exit 1
            Invoke-HerdrJson pane list | Should -BeNullOrEmpty
            Test-HerdrWarnedStale | Should -BeFalse
        }
        It 'returns $null for empty output' {
            Set-HerdrStub
            Invoke-HerdrJson pane list | Should -BeNullOrEmpty
        }
        It 'returns $null for unparseable success output instead of throwing' {
            Set-HerdrStub -Out 'not json at all'
            Invoke-HerdrJson pane list | Should -BeNullOrEmpty
        }
    }

    Context 'Split-HerdrStream (the mechanism bug #3 relies on)' {
        It 'classifies ErrorRecords as diagnostics and everything else as payload' {
            $raw = @(
                'payload line 1',
                (New-StubStderrLine 'diag line A'),
                'this pane shows protocol_mismatch',
                (New-StubStderrLine 'diag line B')
            )
            $s = Split-HerdrStream $raw
            $s.Out | Should -BeExactly "payload line 1`nthis pane shows protocol_mismatch"
            $s.Err | Should -BeExactly "diag line A`ndiag line B"
        }
        It 'keeps a marker word on stdout out of the diagnostics channel' {
            $s = Split-HerdrStream @('this pane shows protocol_mismatch')
            Assert-HerdrServerFresh $s.Err | Should -BeFalse
        }
        It 'handles a stream with no output at all' {
            $s = Split-HerdrStream @()
            $s.Out | Should -BeExactly ''
            $s.Err | Should -BeExactly ''
        }
    }

    Context 'Test-HerdrProtocolMismatch / Assert-HerdrServerFresh' {
        It 'matches the machine-readable code' {
            Test-HerdrProtocolMismatch $script:ProtocolErrJson | Should -BeTrue
        }
        It 'matches the prose form in either direction' {
            Test-HerdrProtocolMismatch 'client protocol 16 is older than server protocol 17' |
                Should -BeTrue
        }
        It 'does not match an unrelated error' {
            Test-HerdrProtocolMismatch $script:PaneNotFoundJson | Should -BeFalse
        }
        It 'does not match empty or absent text' {
            Test-HerdrProtocolMismatch '' | Should -BeFalse
            Test-HerdrProtocolMismatch $null | Should -BeFalse
        }
        It 'keeps reporting a mismatch after the banner has been printed once' {
            # The banner is latched to once-per-process to avoid spamming a
            # closing pane; the VERDICT must not be latched with it.
            Assert-HerdrServerFresh $script:ProtocolErrJson | Should -BeTrue
            Assert-HerdrServerFresh $script:ProtocolErrJson | Should -BeTrue
            $script:HerdrSleptSeconds | Should -Be 5
        }
    }

    Context 'stub fidelity against a real native command' -Skip:(-not $HaveCmd) {
        It 'splits genuine 2>&1 output the same way the stub does' {
            # Pins the whole suite to reality: pwsh emits one ErrorRecord per
            # real stderr line, and stdout stays [String] even when it contains
            # the marker word. Exit 0 so no NativeCommandExitException is
            # possible under _common.ps1's $ErrorActionPreference = 'Stop'.
            $raw = @(& cmd.exe /c "echo payload protocol_mismatch& echo diagnostic>&2" 2>&1)
            $s = Split-HerdrStream $raw
            $s.Out | Should -Match 'payload protocol_mismatch'
            $s.Err | Should -Match 'diagnostic'
            $s.Err | Should -Not -Match 'protocol_mismatch'
            Assert-HerdrServerFresh $s.Err | Should -BeFalse
        }
        It 'leaves $LASTEXITCODE intact through the array wrap and redirect' {
            # Invoke-HerdrJson's `$ok` check is built on this.
            $null = @(& cmd.exe /c "echo hi& exit 7" 2>&1)
            $LASTEXITCODE | Should -Be 7
            $global:LASTEXITCODE = 0
        }
    }
}
