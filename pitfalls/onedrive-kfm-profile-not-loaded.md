# pwsh $PROFILE not loaded / "is not recognized" under OneDrive Known Folder Move

**Symptoms** (grep this section): `is not recognized as a name of a cmdlet, function, script file, or executable`; `Documents\PowerShell\Microsoft.PowerShell_profile.ps1`; a bare `PS C:\...>` prompt with no starship / no aliases; the error path shows `OneDrive - <tenant>\Documents\PowerShell`.
**First seen**: 2026-07
**Affects**: Windows with OneDrive "Known Folder Move" (Documents redirected) — common on corporate/managed machines; chezmoi-managed pwsh `$PROFILE`.
**Status**: fixed — `run_onchange_after_02_profile_redirect.ps1.tmpl` now writes the loader **content** (previously a dot-source pointer stub).

## Symptom

A new pwsh session errors on startup, then falls back to a bare prompt:

```
. : C:\Users\<user>\OneDrive - <tenant>\Documents\PowerShell\Microsoft.PowerShell_profile.ps1:4
Line |
   4 |  . "C:\Users\<user>\Documents\PowerShell\Microsoft.PowerShell_profi …
     |    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     | The term 'C:\Users\<user>\Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
     | is not recognized as a name of a cmdlet, function, script file, or executable program.
```

No starship prompt, no aliases — the managed profile never loaded.

## Root cause

chezmoi writes the managed loader to the **literal** `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1` (it joins `Documents` off `%USERPROFILE%`, unaware of shell Known Folders). But when OneDrive **Known Folder Move** redirects Documents, interactive pwsh resolves `$PROFILE` to `...\OneDrive - <tenant>\Documents\PowerShell\...` — a *different* path.

The old redirect script bridged this by writing a **stub** at the real `$PROFILE` that dot-sourced the literal path:

```powershell
. "C:\Users\<user>\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
```

Under KFM the literal `~/Documents` copy is **not guaranteed to exist** at `$PROFILE`-load time (OneDrive may have moved/removed it), so the dot-source target is missing → "is not recognized". The stub itself was written fine; only the thing it pointed at was gone. (This is pure path topology — not a privilege issue.)

## Workaround

Fixed in-repo: the redirect script now writes the managed loader's **content** into `$PROFILE`. The loader is location-independent (it only sources `~/.config/powershell`), so there is nothing left to point at. To recover a broken machine by hand:

```powershell
chezmoi cat "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1" |
    Set-Content -LiteralPath $PROFILE -Encoding utf8
. $PROFILE
```

`chezmoi cat` renders the managed file from source without needing the literal copy on disk. A following `chezmoi apply` re-runs the redirect script to keep the OneDrive copy in sync.

## Prevention

- The redirect writes **content, not a pointer**, so a missing literal `~/Documents` copy can no longer break `$PROFILE` load, and there's no self-source recursion risk.
- The loader is embedded via `{{ include }}`, so `run_onchange` re-fires whenever the loader changes and the OneDrive copy stays current (the old plain-`.ps1` stub never updated on loader edits).

## Related

- `.chezmoiscripts/run_onchange_after_02_profile_redirect.ps1.tmpl`
- `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` (the loader)
- Graduate to an `AGENTS.md` Hard invariant if it recurs across machines (see `pitfalls/README.md`).
