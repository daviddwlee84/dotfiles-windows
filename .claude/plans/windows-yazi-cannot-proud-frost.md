# Fix yazi "Cannot find `file` to detect the file's MIME type" on Windows

## Context

On Windows, launching yazi errors on every entry with:

```
Cannot find `file` to detect the file's MIME type. Set it up correctly as per the Windows Installation Guide.
```

yazi delegates MIME detection to the MSYS `file(1)` command. Unlike macOS/Linux
(where `file` is on PATH), Windows has no `file` unless you point yazi at the one
**bundled with Git for Windows**. yazi's official [Windows install guide](https://yazi-rs.github.io/docs/installation/#windows)
tells you to either add Git's `usr\bin` to PATH or — cleaner — set the
`YAZI_FILE_ONE` environment variable to the full path of `file.exe`.

This repo installs **git via scoop** (`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
core CLI list), so `file.exe` lives at
`~/scoop/apps/git/current/usr/bin/file.exe` — **not** the generic
`C:\Program Files\Git\usr\bin\file.exe` the yazi docs assume. scoop shims
`~/scoop/shims` onto PATH but does **not** shim MSYS `usr/bin`, so `file.exe` is
invisible to yazi by default. The repo currently sets `YAZI_CONFIG_HOME` in
`00_env.ps1` but has **no** `YAZI_FILE_ONE` anywhere (confirmed: 0 hits repo-wide).

Intended outcome: a fresh pwsh session automatically exposes `file.exe` to yazi
so MIME detection works, with no manual step, robust to git being installed via
scoop **or** a system/winget installer.

## The change

### Single file: `dot_config/powershell/profile.d/00_env.ps1`

Add a `YAZI_FILE_ONE` block immediately after the existing `YAZI_CONFIG_HOME`
line (line 22). This is the correct home: `00_env.ps1` is the env/PATH fragment,
it already owns the yazi config var, and it loads (order `00`) well before the
`y` wrapper in `35_yazi.ps1` (order `35`). Match the fragment's existing idioms
(`Where-Object { Test-Path … }` + `Select-Object`, as used by the PATH block at
lines 36–40):

```powershell
# yazi needs the MSYS `file.exe` (bundled with Git) for MIME detection; without
# it every entry errors "Cannot find `file` … Set it up per the Windows guide".
# scoop doesn't shim git's usr/bin, so point YAZI_FILE_ONE at file.exe directly;
# fall back to a system/winget Git install. First existing candidate wins.
if (-not $env:YAZI_FILE_ONE) {
    $fileOne = @(
        (Join-Path $HOME 'scoop/apps/git/current/usr/bin/file.exe'),
        'C:\Program Files\Git\usr\bin\file.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($fileOne) { $env:YAZI_FILE_ONE = $fileOne }
}
```

Notes on the design:
- **`if (-not $env:YAZI_FILE_ONE)`** — respect a user override (mirrors the XDG
  guards above) and keep it idempotent across re-sourcing.
- **`if ($fileOne)` guard before assigning** — if no candidate exists, leave the
  var unset. Assigning `$null`/`''` would set `YAZI_FILE_ONE=""`, which is worse
  than unset (yazi would try to exec an empty path).
- **Session-scope `$env:` (not User-scope persistence)** — deliberately
  consistent with `YAZI_CONFIG_HOME`, which is also session-only. yazi's intended
  entry point here is the `y` wrapper (`35_yazi.ps1`), always inside a
  profile-sourced pwsh; a yazi launched outside pwsh wouldn't find its config
  either, so persisting only `YAZI_FILE_ONE` would be half a solution. No change
  to `run_onchange_after_03_xdg_env.ps1`.
- **Forward-slash path in `Join-Path`** — matches the existing `scoop/shims`
  usage in this same file; `Join-Path`/`Test-Path` normalize separators.

## Out of scope (with reasons)

- **No packages-script change** — `file.exe` ships with git, which is already in
  the always-installed core scoop list. Nothing new to install.
- **No docs mirror** — yazi already has its row in `docs/tools.md` /
  `docs/tools.zh-TW.md`; this adds no new installer tool, prompt, or docs page,
  so the CLAUDE.md cross-file-mirror invariants don't trigger.
- **No `pitfalls/` doc** — per `pitfalls/README.md` "When NOT to add": the symptom
  is documented in yazi's own install guide (googleable) and, once this lands, the
  profile fixes it automatically so it can't recur on a configured box.
- **No Pester test** — asserting the var would require `file.exe` present on the
  CI host; PSScriptAnalyzer (`-Recurse`, which lints this non-`.tmpl` file) already
  covers syntax, and this is pure env plumbing.

## Verification

Off-Windows (this checkout — logic + syntax, no real `file.exe`):

1. **Lint** (must report no new Errors):
   ```bash
   pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path ./dot_config/powershell/profile.d/00_env.ps1 -Settings ./PSScriptAnalyzerSettings.psd1"
   ```
2. **Parse** the fragment:
   ```bash
   pwsh -NoProfile -c "\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ./dot_config/powershell/profile.d/00_env.ps1), [ref]\$null, [ref]\$e); if (\$e){throw \$e}"
   ```
3. **Logic smoke test** — stub the scoop path under a throwaway `$HOME` and
   dot-source, asserting `YAZI_FILE_ONE` resolves to the stub (and that a missing
   file leaves it unset):
   ```bash
   pwsh -NoProfile -c '
     $HOME = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())) -Force
     New-Item -ItemType Directory -Force -Path (Join-Path $HOME "scoop/apps/git/current/usr/bin") | Out-Null
     Set-Content (Join-Path $HOME "scoop/apps/git/current/usr/bin/file.exe") "stub"
     . ./dot_config/powershell/profile.d/00_env.ps1
     if (-not $env:YAZI_FILE_ONE) { throw "not set" }
     "OK -> $env:YAZI_FILE_ONE"'
   ```

On the real Windows box (the actual gate):

4. `chezmoi apply` (or `just apply`), open a **fresh** pwsh, confirm
   `echo $env:YAZI_FILE_ONE` prints the scoop `file.exe` path.
5. Run `y` (the yazi wrapper); browse a folder with mixed file types — the
   "Cannot find `file`…" banner is gone and previews/MIME-based open rules work.
6. `windows-latest` CI (`.github/workflows/windows.yml`) stays green
   (PSScriptAnalyzer + init/apply).
