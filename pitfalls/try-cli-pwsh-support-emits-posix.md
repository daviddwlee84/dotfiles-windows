# `try` in pwsh: bareword `try foo` won't parse, and try-cli's output errors with `The term '\' is not recognized`

**Symptoms** (grep this section): you install `gem install try-cli` and add its shell integration, then in PowerShell `try foo` gives `The Try statement is missing its statement block`; or (once wrapped in a function) `try <name>` prints `The term '\' is not recognized as a name of a cmdlet, function, script file, or executable program`; the interactive selector never appears / renders into nowhere; `try init` claims to support pwsh but the resulting `try` command errors or does nothing; `& try foo` works but bareword `try foo` does not.
**First seen**: 2026-07 (porting tobi/try to this repo — `profile.d/32_try.ps1`)
**Affects**: PowerShell 7 on any OS; try-cli ≤ 1.9.3 (checked 1.7.1 installed + 1.9.3 source).
**Status**: worked around in `32_try.ps1` — bareword command renamed to **`tri`**; a native POSIX→pwsh translator replaces try's `eval`.

## Symptom

Two independent pwsh-specific breakages, one tool:

```powershell
# 1) `try` is a reserved keyword (try/catch), so it can never be a bareword command:
try foo
# ParserError: The Try statement is missing its statement block.

# 2) try-cli's runtime output is POSIX shell; Invoke-Expression chokes on it:
$out | Invoke-Expression
# The term '\' is not recognized as a name of a cmdlet, function, script file...
```

try-cli 1.9.3 *detects* pwsh (`ENV["PSModulePath"]`) and emits a `function try { $out | Invoke-Expression }` wrapper — but (a) `try` can't be called bareword, and (b) the `$out` it evaluates is still POSIX.

## Root cause

**`try` is a PowerShell language keyword.** At statement position the parser lexes `try` as the start of a `try {} catch {}` block and demands a `{`. A function or alias named `try` is only reachable via the call operator (`& try …`), never as a bareword — this is a parse-time fact, unaffected by command resolution.

**try-cli's runtime emitters are not shell-aware.** The Ruby `emit_script` / `script_*` helpers (`try.rb`) always print POSIX: commands joined by `` && \``+newline continuations, using `mkdir -p`, `touch`, `test -d`, `rm -rf`, `ln -s`, and `/usr/bin/env sh -c '…'`. pwsh's `Invoke-Expression` can't eval `` && \`` (backslash isn't a pwsh line-continuation — backtick is) or `mkdir -p` (pwsh `mkdir` has no `-p`). The pwsh `init` wrapper also redirects the selector TUI to a temp file (`2>$tempErr`), so the picker is invisible. In short: try-cli's pwsh support was never usable.

## Workaround

In `dot_config/powershell/profile.d/32_try.ps1`:

1. **Name the command `tri`** (bareword-safe). Also define `function try { tri @args }` so `& try …` works for muscle memory.
2. **Don't use `try init`.** Run `ruby try.rb exec --path $env:TRY_PATH @args` directly, capture stdout, and **translate** its POSIX commands into native pwsh executed in the live session (`Set-Location`, `New-Item -ItemType Directory`, `git clone`, `git worktree add --detach`, …). Keep the child's stderr on the console so the selector TUI stays visible. Only translate a genuine emit-script (exit 0 + the `you didn't launch try from an alias` marker); print anything else (`Cancelled.`, errors) verbatim.

```powershell
tri myproj              # create ~/src/tries/YYYY-MM-DD-myproj and cd in
tri https://github.com/user/repo   # clone into a dated dir and cd in
tri                     # fuzzy-select an existing trial
& try myproj            # the keyword-dodging alias, if you must type "try"
```

## Prevention

- **Never name a pwsh command after a keyword** (`try`, `if`, `for`, `switch`, `function`, `return`, `process`, `begin`, `end`, `data`, `filter`, `class`, `enum`, `hidden`, `trap`, …). Check with `[System.Management.Automation.Language.Parser]::ParseInput('name foo',[ref]$null,[ref]$errs)`.
- **Assume a POSIX tool's shell integration is POSIX-only** until proven otherwise; a "supports pwsh" claim can mean "emits a pwsh wrapper" while the payload is still `sh`. Test `$out | Invoke-Expression` on real output before trusting it.
- The translator is coupled to try's emit format — `tests/Try.Tests.ps1` locks it down against hand-built goldens that mirror `emit_script`, and warns-and-continues on unknown verbs so a new try-cli version degrades to "still lands in the right dir" rather than crashing.

## Related

- `dot_config/powershell/profile.d/32_try.ps1` (the fix)
- `tests/Try.Tests.ps1`
- upstream: [tobi/try](https://github.com/tobi/try) `try.rb` (`emit_script`, `cmd_init!` pwsh branch)
- PowerShell: `about_Language_Keywords`, `about_Command_Precedence`
