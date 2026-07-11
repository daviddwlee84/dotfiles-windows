# Ctrl+R shows `bck-i-search:` instead of an fzf history pane (pwsh and cmd.exe)

**Symptoms** (grep this section): `bck-i-search:`; Ctrl+R opens the built-in incremental reverse search, not fzf; Ctrl+T / Alt-C do nothing; `fzf`, `PSFzf`, `clink`, `fzf.lua` are all installed and the bootstrap log shows "no failures"; starship still renders in cmd.exe (so clink autorun works) but fzf keys don't; pwsh Up/Down stop doing prefix history search.
**First seen**: 2026-07
**Affects**: this repo's pwsh profile (`PSFzf`) and the opt-in `installClink` cmd.exe integration (`chrisant996/clink-fzf`'s `fzf.lua`). Two independent bugs, one shared symptom.
**Status**: fixed — `90_psreadline.ps1.tmpl` reordered (EditMode first); `run_onchange_after_10_packages.ps1.tmpl` moved `clink set` after the `fzf.lua` download.

## Symptom

In a fresh pwsh **or** cmd.exe session, Ctrl+R shows the default incremental
search prompt instead of fzf:

```
bck-i-search:
```

Everything looks installed — `Get-Module -ListAvailable PSFzf` returns a
version, `fzf --version` works, `%LOCALAPPDATA%\clink\fzf.lua` exists, and the
bootstrap log ends with `package install complete — no failures`. In cmd the
starship prompt renders normally, which makes it look like the whole clink
integration is live.

## Root cause

Two separate ordering bugs that both leave the fzf key binding un-applied, so
each shell falls back to its readline/PSReadLine default (`bck-i-search:`).

**pwsh — `Set-PSReadLineOption -EditMode` resets key handlers.** Profile
fragments dot-source in numeric order (`10_tools` → `90_psreadline`).
`10_tools.ps1` bound the PSFzf chord (`Set-PsFzfOption … -PSReadlineChordReverseHistory 'Ctrl+r'`),
then `90_psreadline.ps1.tmpl` ran `Set-PSReadLineOption -EditMode Windows|Vi`
**afterward**. Setting `-EditMode` rebuilds PSReadLine's key-handler tables from
that mode's defaults, wiping the PSFzf chord (and the `UpArrow`/`DownArrow`
prefix-history handlers, which were also set before the `-EditMode` line in the
same fragment). This is the canonical PSFzf gotcha: chords must be applied
**after** `-EditMode`.

**cmd — `clink set` runs before `fzf.lua` is on disk.** The installer ran
`clink set fzf.default_bindings true` *before* the loop that downloads `fzf.lua`
into `%LOCALAPPDATA%\clink`. `fzf.default_bindings` is a setting **defined
inside `fzf.lua`** (`maybe_add(rl.setbinding and 'fzf.default_bindings', false, …)`;
keys bind only `if settings.get('fzf.default_bindings')`). Per the Clink docs,
*"scripts are also loaded every time `clink set` is run"* — so `clink set`
reloads the profile dir, `fzf.lua` isn't there yet, the setting name is unknown,
and the value is **silently not persisted** (`*> $null` swallowed the error). At
cmd runtime `fzf.lua` loads, re-registers the setting at its default `false`,
and never binds Ctrl-R/Ctrl-T/Alt-C.

## Workaround

Fixed in-repo. To recover a machine by hand without re-applying:

```powershell
# pwsh — bind after EditMode is already set for the session:
Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
```

```cmd
:: cmd — fzf.lua is already downloaded, so this now finds the setting:
clink set fzf.default_bindings true
:: then open a new cmd window (or `clink reload`)
```

Or just `chezmoi apply` on the fixed repo: the pwsh fragments redeploy, and the
`run_onchange` re-fires (its content hash changed) so `clink set` re-runs *after*
`fzf.lua` exists.

## Prevention

- **Apply key bindings after `Set-PSReadLineOption -EditMode`.** All PSReadLine
  key-table mutations now live in `90_psreadline.ps1.tmpl`, with `-EditMode`
  first and the PSFzf chord last. `10_tools.ps1` only imports PSFzf.
- **Register a script-defined Clink setting before writing it.** `clink set
  <name>` only recognizes settings whose defining `*.lua` is already in the
  profile dir — write the value *after* the download, not before.
- Verify on Windows: pwsh `Get-PSReadLineKeyHandler -Chord 'Ctrl+r'` should not
  be `ReverseSearchHistory`; cmd `clink set fzf.default_bindings` should print
  `true` and `clink info` should list `fzf.lua`.

## Related

- `dot_config/powershell/profile.d/90_psreadline.ps1.tmpl` (EditMode + PSFzf chord)
- `dot_config/powershell/profile.d/10_tools.ps1` (PSFzf import)
- `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (`installClink` block)
- Upstream: [chrisant996/clink-fzf `fzf.lua`](https://github.com/chrisant996/clink-fzf/blob/master/fzf.lua); [Clink docs](https://chrisant996.github.io/clink/clink.html) (scripts reload on `clink set`).
