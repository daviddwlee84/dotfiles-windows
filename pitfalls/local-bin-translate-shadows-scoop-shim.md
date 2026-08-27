# `~\.local\bin\translate.exe` shadows the scoop shim (scoop update succeeds, version never changes)

**Symptoms** (grep this section): `scoop update translate` says it succeeded but
`translate --version` still prints the old version; `scoop list` shows a newer
version than the binary actually running; a tool switched from `go install` to
scoop keeps its old behaviour; `Get-Command translate -All` prints two paths;
new CLI flags are "unknown" despite an up-to-date scoop install.
**First seen**: 2026-08-27, migrating `translate` from `go install` to the
`daviddwlee84` scoop bucket.
**Affects**: any tool this repo previously installed into `~\.local\bin` and
later moved to scoop.
**Status**: fixed — the packages script removes the stale copy once the shim
exists.

## Symptom

`PATH` on this repo's boxes puts `~\.local\bin` **before** `~\scoop\shims` (see
`dot_config/powershell/profile.d/00_env.ps1`). Until 2026-08-27 `translate` was
built from source with `go install` into `~\.local\bin`.

After the switch to scoop, both files exist and the *old* one keeps winning:

```powershell
PS> scoop update translate
translate: 0.5.2 -> 0.6.0
PS> translate --version
translate version v0.5.2 ...        # unchanged
PS> Get-Command translate -All | Select-Object -ExpandProperty Source
C:\Users\you\.local\bin\translate.exe
C:\Users\you\scoop\shims\translate.exe
```

Nothing errors. Scoop correctly updated *its* copy; it has no idea another
binary earlier on `PATH` is intercepting every invocation.

## Why it happens

Scoop installs a **shim**, it does not edit `PATH` ordering, and it never looks
for competing copies of the same command name. `~\.local\bin` is a general-purpose
user bin dir this repo puts first on purpose (so hand-built and `go install`
tools win over system ones) — which is exactly what makes it a trap when a tool
graduates to a package manager.

## Fix

Delete the stale binary:

```powershell
Remove-Item "$HOME\.local\bin\translate.exe"
```

`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` now does this on apply
— but **only when the scoop shim is already present**, so a failed or skipped
scoop install can never leave the box with no `translate` at all.

## When migrating any other tool off `~\.local\bin`

1. Install via scoop first, and confirm the shim exists.
2. Only then remove the `~\.local\bin` copy — guard on the shim, never delete
   unconditionally.
3. Add a `Should -Not -Match` test for the old install path so the repo can't
   drift back (see `tests/Translate.Tests.ps1`).

## Related

- `pitfalls/scoop-local-changes-overwritten-by-merge.md`
- The parent repo has the unix twin of this trap:
  `pitfalls/duplicate-translate-on-path-dotfiles-bin-shadows-local-bin.md` in
  the `translate` repo (`~/.dotfiles/bin` vs `~/.local/bin`).
