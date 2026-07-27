# "The term '$-' is not recognized" from a Pester test file that parses clean

**Symptoms** (grep this section): `CommandNotFoundException: The term '$-' is not recognized as a name of a cmdlet, function, script file, or executable program.`, `at <ScriptBlock>, <No file>:1`, `BeforeAll \ AfterAll failed: 1`, every `It` in the file fails with an *empty* `ErrorRecord`, `[System.Management.Automation.Language.Parser]::ParseInput` says the file parses clean
**First seen**: 2026-07
**Affects**: Pester 6.0.0 (and Pester 5.x — `-ForEach` name expansion is not new), any OS
**Status**: by design upstream; avoid angle brackets in test names

## Symptom

A brand-new `tests/Foo.Tests.ps1` fails *entirely* — not one assertion, the
whole file:

```
Describing init prompts <-> CI flags (invariant #1)
[-] Describe init prompts <-> CI flags (invariant #1) failed
  CommandNotFoundException: The term '$-' is not recognized as a name of a cmdlet, function, script file, or executable program.
  Check the spelling of the name, or if a path was included, verify that the path is correct and try again.
  at <ScriptBlock>, <No file>:1
Tests Passed: 0, Failed: 6, Skipped: 0, Inconclusive: 0, NotRun: 0
BeforeAll \ AfterAll failed: 1
  - init prompts <-> CI flags (invariant #1)
```

Everything about the diagnosis points the wrong way:

- The error is attributed to `BeforeAll`, so you bisect the `BeforeAll` body —
  and **each half passes in isolation**.
- `Parser::ParseInput` on the file reports no syntax errors.
- `$result.Failed[0].ErrorRecord[0].Exception.Message` is **empty**, so the
  only place the real message appears is `-Output Detailed` console text.
- `$-` appears nowhere in the file.

## Root cause

Pester treats `<...>` inside a `Describe`/`Context`/`It` **name** as a data
placeholder for `-ForEach`/`-TestCases` templating: `It 'handles <name>'`
expands `<name>` to the value of `$name` from the test case. The expansion is
unconditional — it does not require `-ForEach` to be present.

So the name `init prompts <-> CI flags` contains the placeholder `<->`, which
Pester rewrites to the expression `$-` and evaluates. `$-` is not a PowerShell
automatic variable (that's a POSIX shell thing), so it resolves as a command
name and throws `CommandNotFoundException` — inside Pester's own name-expansion
scriptblock, which is why the location is the meaningless `<No file>:1` and why
the blame lands on the enclosing block rather than any line you wrote.

Upstream docs: [Pester — Data driven tests](https://pester.dev/docs/usage/data-driven-tests)
("`<name>` in the test name is replaced by the value").

## Workaround

Don't put angle brackets in test names. Use words or a different separator:

```powershell
# breaks: <-> is parsed as the placeholder `$-`
Describe 'init prompts <-> CI flags (invariant #1)' { }

# fine
Describe 'init prompts vs CI flags (invariant #1)' { }
```

Same trap for anything ASCII-arrow-ish or generic-ish in a name:
`'converts <T> to string'`, `'A -> B'` is fine but `'A <-> B'` is not,
`'renders <div>'` is not.

## Prevention

- Reach for `vs`, `->`, `to`, or backticked code spans in test names; keep
  `<...>` reserved for real `-ForEach` placeholders.
- When a whole Pester file dies in `BeforeAll` but each half of the
  `BeforeAll` body passes when run standalone, **suspect the block name before
  the block body** — Pester evaluates the name first.
- `-Output Detailed` is the only view that shows this error text; a
  `-PassThru` + `ErrorRecord` dump comes back empty. Check the console output
  before writing a debug harness.

## Related

- `tests/InitPrompts.Tests.ps1` — the test this bit; carries an inline comment
  so the name doesn't drift back.
- [`pitfalls/hashtable-added-to-hashtable-if-expression-array-unwrap.md`](hashtable-added-to-hashtable-if-expression-array-unwrap.md)
  — the other "PowerShell evaluated this somewhere you didn't expect" trap in
  this repo.
