# A `function gp { … }` still runs `Get-ItemProperty` (and `gbD`/`gbd` collapse into one)

**Symptoms** (grep this section): you define `function gp { git push @args }` (or `gc`, `gl`, `gcb`, `gcs`, `gpv`) in your `$PROFILE`, reload, type `gp` — and instead of `git push` you get a `Get-ItemProperty` prompt: `cmdlet Get-ItemProperty at command pipeline position 1 / Supply values for the following parameters: Path[0]:` and the shell hangs waiting for input; `gc` opens `Get-Content`, `gl` prints the current path (`Get-Location`); `Get-Command gp` shows `Alias` not `Function`; also: defining both `function gbd {…}` and `function gbD {…}` (or `gcb`/`gcB`) silently keeps only one — `Duplicate keys 'gbD' are not allowed in hash literals` if they're hashtable keys, or the second definition just wins with no error; a mistyped upper/lower alias runs the wrong one.

**First seen**: 2026-07 (porting the oh-my-zsh `git` plugin to pwsh — `profile.d/21_git.ps1`)
**Affects**: PowerShell 7 on any OS; any dotfiles that define functions whose names collide with a built-in alias or differ only in case.
**Status**: fixed in `21_git.ps1` — `Remove-Item Alias:<name>` before defining each function; case-only omz variants (`gbD`/`gcB`/`gbgD`) intentionally collapsed to their lowercase twin.

## Symptom

A same-named function does **not** shadow a built-in alias:

```powershell
function gp { git push @args }
gp                       # -> prompts "Supply values ... Path[0]:" (Get-ItemProperty), hangs
Get-Command gp           # CommandType = Alias, Definition = Get-ItemProperty
```

And two functions differing only in case are the same command:

```powershell
$h = @{ gbd = 'branch --delete'; gbD = 'branch --delete --force' }
# ParseError: Duplicate keys 'gbD' are not allowed in hash literals.
function gbd { 'safe' }; function gbD { 'force' }
gbd                      # -> 'force'  (the gbD definition won; no error, no warning)
```

## Root cause

**Aliases outrank functions.** PowerShell command resolution order is
**Alias → Function → Cmdlet → Application** (see `about_Command_Precedence`). The
default session ships built-in aliases on many two/three-letter `g*` names, so a
function you define with the same name is *dead on arrival* — the alias always
wins. The colliding built-ins (pwsh 7):

| Name | Built-in alias | (omz wants) |
|---|---|---|
| `gc`  | `Get-Content`           | `git commit --verbose` |
| `gcb` | `Get-Clipboard`         | `git checkout -b` |
| `gcs` | `Get-PSCallStack`       | `git commit --gpg-sign` |
| `gl`  | `Get-Location`          | `git pull` |
| `gp`  | `Get-ItemProperty`      | `git push` |
| `gpv` | `Get-ItemPropertyValue` | `git push --verbose` |
| `gcm` | `Get-Command`           | (kept — not overridden) |
| `gm`  | `Get-Member`            | (kept — not overridden) |

**Command names are case-insensitive.** `gbd` and `gbD` are the *same* command
name to PowerShell, as are `gcb`/`gcB` and `gbgd`/`gbgD`. As hashtable keys they
throw `Duplicate keys … are not allowed`; as separate `function` statements the
last one silently wins. oh-my-zsh relies on case sensitivity (`gbD` = force-
delete, `gcB` = `checkout -B`) that pwsh cannot express.

## Workaround

Remove the shadowing alias **before** defining the function, and pick one case:

```powershell
foreach ($name in $GitAliases.Keys) {
    Remove-Item -Path "Alias:$name" -Force -ErrorAction SilentlyContinue
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("git $($GitAliases[$name]) @args"))
}
```

For case-only pairs, define **only the safe (lowercase) form** so a mistype can't
do the destructive thing — `gbD` then resolves (case-insensitively) to `gbd`
(`branch --delete`, which refuses an unmerged branch) rather than a force delete.
Reach the force variant through the explicit flag: `gbd --force <b>`, `gco -B <b>`.

Never `Remove-Item Alias:` a name you want to keep — `gcm`/`gm` are simply never
added to the table, so `Get-Command`/`Get-Member` stay intact.

## Prevention

- Any dotfile function on a short `g*`/`s*`/`r*` name: check `Test-Path Alias:<name>`
  first; if it's a built-in alias you must `Remove-Item Alias:<name> -Force` (the
  repo already does this for `ls`, `cat` in `20_aliases.ps1`).
- Treat function names as case-insensitive: never rely on case to disambiguate.
- A Pester test (`tests/GitAliases.Tests.ps1`) asserts `gp`/`gl`/… resolve to
  `Function`, that `gcm`/`gm` stay `Alias`, and that `gbD` maps to the non-force
  `gbd` — so a regression fails CI instead of silently hanging a shell.

## Related

- `dot_config/powershell/profile.d/21_git.ps1` (the fix in context)
- `dot_config/powershell/profile.d/20_aliases.ps1` (`Remove-Item Alias:ls` / `:cat` precedent)
- `tests/GitAliases.Tests.ps1`
- PowerShell docs: `about_Command_Precedence`, `about_Aliases`
