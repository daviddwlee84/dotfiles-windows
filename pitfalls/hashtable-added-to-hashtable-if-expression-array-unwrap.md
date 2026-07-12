# "A hash table can only be added to another hash table" in the Claude settings merger

## Symptom

`chezmoi apply` (or a direct run of the rendered
`run_onchange_after_25_claude_settings.ps1`) aborts the settings merge with:

```
InvalidOperation: ...
Line |
  14 |          $base[$evt] = @($live + $additions)
     |          ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | A hash table can only be added to another hash table.
```

Only triggers when `~/.claude/settings.json` **already has** a `hooks.<event>`
array with exactly one entry (e.g. a user- or tool-added hook, or our own
overlay entry from a previous apply). A fresh file with no `hooks` merges fine,
so it hides during first-run testing and only bites on the second apply / on a
machine that already had hooks.

## Root cause

PowerShell **unwraps a single-element array when it flows out of an
`if`-expression**. This idiom:

```powershell
$live = if ($null -ne $base[$evt]) { @($base[$evt]) } else { @() }
```

looks array-safe because of the `@(...)`, but the `if` is an *expression* whose
output goes through the pipeline. When `$base[$evt]` is a 1-element array, the
`if` emits that single object to the pipeline and `$live` captures the **scalar**
(here a `[hashtable]` hook entry), not a 1-element array. Then `$live.Count`
returns the hashtable's *key count* (2), and `$live + $additions` becomes
`hashtable + array` → the error above. (With ≥2 live entries it stays an array
and the bug is invisible — another reason it's easy to miss.)

## Workaround

Use a plain two-line assignment. Direct `$x = @(...)` preserves array shape
because it is not an `if`-expression pipeline result:

```powershell
$live = @()
if ($null -ne $base[$evt]) { $live = @($base[$evt]) }
```

Fixed in `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`
(`Merge-ClaudeHooks`).

## Prevention

- Never write `$x = if (...) { @(...) } else { @() }` when `$x` must stay an
  array — split into an init + guarded assignment (as above), or wrap the whole
  `if` in `@( ... )`: `$live = @(if (...) { $base[$evt] } else { @() })`.
- Test the merger against a `settings.json` that **already contains** a
  single-entry `hooks.<event>` array (the idempotent + preserve cases), not just
  a fresh empty file. The isolated-apply harness in this session did exactly
  that and caught it.
- Related PowerShell quirk to keep in mind here: `ConvertTo-Json` can drop the
  brackets around a single-element array; `@(...)` on the final assignment plus
  a re-parse assertion (`isinstance(..., list)`) guards it.
