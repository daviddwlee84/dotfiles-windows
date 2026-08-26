# PowerShell testing with Pester

[Pester](https://pester.dev/) is PowerShell's test and mock framework. It runs
PowerShell test files, provides assertions through `Should`, and can replace
commands with mocks so scripts can be tested without changing the real machine.
This repository uses it to protect PowerShell functions, rendered templates,
merge behavior, and regressions that are difficult to verify by inspection.

The upstream project and full reference are available from the
[Pester GitHub repository](https://github.com/pester/Pester) and the
[official documentation](https://pester.dev/docs/quick-start).

## Install and run

Install Pester for the current user if it is not already available:

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser
```

From the repository root, run the whole suite or one file:

```powershell
# All tests
Invoke-Pester -Path ./tests

# One test file, with individual test results shown
Invoke-Pester -Path ./tests/GitConfig.Tests.ps1 -Output Detailed

# The form used by CI
Invoke-Pester -CI -Path . -Output Detailed
```

Test files use the `*.Tests.ps1` suffix and live under `tests/`. The Windows CI
workflow installs Pester and runs every matching test after chezmoi rendering and
PowerShell parsing checks.

## Anatomy of a test

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'gitconfig-merge.ps1')
}

Describe 'Merge-GitConfig' {
    Context 'empty live configuration' {
        It 'emits the managed baseline' {
            $result = Merge-GitConfig -BaselineText $baseline -LiveText ''

            $result | Should -Match 'autocrlf = input'
            $result | Should -Not -Match 'hooksPath'
        }
    }
}
```

The main building blocks are:

| Block | Purpose |
|---|---|
| `Describe` | Groups tests for a function, script, or behavior. |
| `Context` | Groups scenarios within a `Describe` block. It is optional. |
| `It` | Defines one observable behavior and its expected result. |
| `BeforeAll` / `AfterAll` | Set up or clean up once for a scope. |
| `BeforeEach` / `AfterEach` | Set up or clean up around every `It` block. |
| `BeforeDiscovery` | Prepares data needed while Pester discovers test cases, such as a `-Skip` decision. |

Keep each `It` focused on one behavior. A useful test name completes the
sentence “it …”, such as “it preserves unmanaged keys” or “it does not rewrite
an aligned file”.

## Assertions with `Should`

Pester sends the actual value through the pipeline to `Should`:

```powershell
$result.ExitCode | Should -Be 0
$text | Should -Match 'expected pattern'
$items | Should -HaveCount 2
$path | Should -Exist
{ Invoke-RiskyParser $text } | Should -Not -Throw
```

Assertions commonly used in this repository include:

| Assertion | Checks |
|---|---|
| `Should -Be` | Value equality. |
| `Should -BeExactly` | Exact string equality, including case. |
| `Should -Match` / `-Not -Match` | Regular-expression matching. |
| `Should -Contain` | Collection membership. |
| `Should -HaveCount` | Collection size. |
| `Should -BeTrue` / `-BeFalse` | Boolean results. |
| `Should -Exist` | File or directory existence. |
| `Should -Throw` / `-Not -Throw` | Whether a script block raises an error. |

Use `-Because` when the invariant is not obvious from the assertion alone. Its
message is included in the failure output:

```powershell
$missing.Count | Should -Be 0 -Because 'every init prompt needs a CI flag'
```

## Isolate external effects with mocks

Mocks replace a command only inside the test scope. They keep tests fast and
prevent calls to the network, services, installers, or the live filesystem:

```powershell
Describe 'Start-WorkerIfNeeded' {
    BeforeEach {
        Mock Test-WorkerReady { $false }
        Mock Start-Sleep {}
        Mock Start-Worker {}
    }

    It 'starts the worker when it is not ready' {
        Start-WorkerIfNeeded

        Should -Invoke -CommandName Start-Worker -Times 1 -Exactly
    }
}
```

Prefer mocking at a small wrapper or “seam” around an external program rather
than mocking every internal function. The SSH and pueue tests in this repository
follow this pattern: parsing and state transitions remain real, while remote SSH,
service, sleep, and process calls are replaced.

## Patterns used in this repository

### Dot-source the implementation

Load a real `.ps1` implementation in `BeforeAll` so the test exercises the same
code that ships:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'gitconfig-merge.ps1')
}
```

For a `.ps1.tmpl`, prefer moving reusable logic into a normal `.ps1` file and
including that file from the template. It becomes directly testable without
requiring a Windows apply.

### Assert rendered policy as text

Some tests read templates or configuration as raw text and assert load-bearing
rules. This is useful for gates, package lists, and settings that would otherwise
need a real Windows host:

```powershell
$template = Get-Content -Raw $templatePath
$template | Should -Match 'Start-PueuedIfNeeded -InstallService'
$template | Should -Not -Match 'core\.hooksPath'
```

### Use temporary fixtures

Create files under a unique temporary directory and remove them in `AfterEach`.
Never use a developer's real `$HOME`, registry, credentials, SSH configuration,
or application settings as a test fixture.

```powershell
BeforeEach {
    $TestRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
}

AfterEach {
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}
```

### Parameterize repeated cases

Use `-TestCases` when the behavior is identical and only inputs and expected
outputs change:

```powershell
It 'parses <Input>' -TestCases @(
    @{ Input = 'host:22'; Host = 'host'; Port = '22' }
    @{ Input = 'alias';   Host = 'alias'; Port = '' }
) {
    param($Input, $Host, $Port)

    $result = Split-Target $Input
    $result.Host | Should -BeExactly $Host
    $result.Port | Should -BeExactly $Port
}
```

Angle brackets in a Pester test name are always interpreted as data
placeholders. Use them only for keys that really exist in `-TestCases`; text
such as `<->`, `<T>`, or `<div>` can be evaluated as an invalid placeholder and
make the entire test block fail before its assertions run.

!!! note "Discovery happens before test execution"
    Values used to create tests or evaluate `-Skip` must exist during discovery.
    Put those values in `BeforeDiscovery`, not `BeforeAll`. Runtime setup such as
    dot-sourcing the implementation belongs in `BeforeAll`.

## Adding a regression test

When fixing a bug, add the smallest test that reproduces the old failure:

1. Create or extend a `tests/<Feature>.Tests.ps1` file.
2. Load the production implementation in `BeforeAll`.
3. Arrange a deterministic fixture; mock only external effects.
4. Call the behavior under test.
5. Assert the observable result and the important negative condition.
6. Run the single file, then `Invoke-Pester -Path ./tests`.

For changes that also touch templates, finish with the repository's isolated
chezmoi render/parse validation. Pester complements that check: rendering proves
the generated PowerShell is valid, while tests prove the behavior and invariants
remain correct.
