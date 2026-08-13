# `modify_config.toml: invalid TOML ... Empty key at line 1 col 0`

**Symptoms** (grep this section): `chezmoi update --init` or `chezmoi apply`
prints:

```text
modify_config.toml: invalid TOML; preserving live config unchanged: Empty key at line 1 col 0
```

The existing `~/.codex/config.toml` looks empty or valid in an editor, and the
managed `tui.status_line` is not applied.
**First seen**: 2026-08
**Affects**: Windows dotfiles at the first `modify_`-based Codex footer release,
when the live config starts with a UTF-8 BOM.
**Status**: fixed — the modifier accepts one BOM, repairs the two exact mojibake
BOM signatures written by the old path, and preserves every other failure path
byte-for-byte.

## Symptom

The parser reports an empty key at the very first column even though line 1 does
not contain an empty TOML assignment. Missing and ordinary zero-byte files work;
an existing file created by a Windows editor can fail.

A separate CI symptom had the same outward result (the old status line survived):
Python existed on `windows-latest`, but `tomlkit` did not. The old Pester helper
discarded stderr, so the import failure was hidden. The modifier now uses Bun's
built-in TOML parser and has no apply-time Python/PyPI dependency.

## Root cause

The first implementation read stdin through `[Console]::In.ReadToEnd()`.
`Console.In` decoded the leading UTF-8 BOM into the literal character U+FEFF;
`[string]::IsNullOrWhiteSpace([char]0xFEFF)` is false, so the fresh-input shortcut
did not run. The parsing copy still began with U+FEFF. TOML permits space, tab,
LF, and CRLF as whitespace, not U+FEFF, so `tomlkit` attempted to parse a key,
consumed zero valid key characters, and raised `Empty key at line 1 col 0`.

The same text-mode path also made “preserving unchanged” weaker than advertised:
invalid UTF-8 could be replaced during decode, and Python universal-newline reads
could turn CRLF into LF. On a live Windows install the BOM was even observed after
two OEM/UTF-8 round trips as `Γê⌐ΓòùΓöÉ` before the first real key. Bun's parser
returned an empty object for that prefix rather than throwing, so the modifier now
repairs only this exact marker (and the direct `∩╗┐` form) before validation.

References:

- [TOML 1.0 whitespace and newline grammar](https://toml.io/en/v1.0.0)
- [.NET `Console` implementation](https://github.com/dotnet/runtime/blob/v8.0.0/src/libraries/System.Console/src/System/ConsolePal.Windows.cs)
- [`tomlkit` parser](https://github.com/python-poetry/tomlkit/blob/0.13.3/tomlkit/parser.py)

## Workaround

Apply the fixed modifier. It reads stdin as bytes, strips exactly one BOM only
from the parsing copy, and emits successful output as UTF-8 without BOM:

```powershell
chezmoi apply ~/.codex/config.toml
```

Before the fix, remove one BOM only after backing up the file:

```powershell
$p = Join-Path $HOME '.codex/config.toml'
Copy-Item $p "$p.bak"
$bytes = [IO.File]::ReadAllBytes($p)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 3, $bytes.Length - 3)
    [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false))
}
chezmoi apply $p
```

Do not replace or truncate a nonblank file merely because parsing failed; it may
contain providers, project trust, plugins, or credentials that the overlay must
preserve.

## Prevention

- Treat a `modify_` target as a byte stream until parsing succeeds.
- Decode with strict UTF-8 and retain the original bytes for every fail-closed
  return.
- Accept at most one leading BOM; do not use `.IsNullOrWhiteSpace()` as TOML’s
  whitespace grammar.
- Capture stderr and assert bytes in Pester. Include BOM-only, BOM-prefixed valid
  TOML, malformed CRLF, invalid UTF-8, double-BOM, and idempotence cases.
- Exercise Bun's built-in parser in CI and seed a non-empty target before
  `chezmoi apply`; an empty target does not exercise the merge path.

## Related

- [`docs/codex-status-line.md`](../docs/codex-status-line.md)
- [`dot_codex/modify_config.toml.ps1.tmpl`](../dot_codex/modify_config.toml.ps1.tmpl)
- [`tests/CodexConfig.Tests.ps1`](../tests/CodexConfig.Tests.ps1)
