# Windows Defender flags the cmd bootstrap one-liner as Trojan:Win32/ClickFix

**Symptoms** (grep this section): `Trojan:Win32/ClickFix.R!ml`; `Trojan:Win32/ClickFix`; Windows Defender / "Threat detected" blocks or removes the command when running `powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://.../bootstrap.ps1 | iex"` from `cmd.exe`; the `irm` / `iwr` / `iex` one-liner is killed before it runs; VirusTotal shows the fetched script clean (0/NN) yet Defender still blocks.
**First seen**: 2026-07
**Affects**: Microsoft Defender Antivirus (ML / `!ml` cloud heuristic) on any Windows 10/11 — running the download-cradle bootstrap one-liner from cmd.exe. NOT specific to this repo (the script content is benign).
**Status**: workaround documented — `docs/setup.md` recommends two safe forms; the flagged `powershell -c "irm|iex"` cradle is NOT shipped as the recommendation.

## Symptom

Pasting the cmd bootstrap one-liner:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex"
```

is blocked by Windows Defender real-time protection with:

```
Trojan:Win32/ClickFix.R!ml
```

The command is killed before `bootstrap.ps1` runs. A content scan of the script itself is clean (community reports show the same shape scoring 0/62 on VirusTotal) — Defender is blocking the **command line**, not the payload.

## Root cause

`ClickFix.*!ml` is a Microsoft Defender **machine-learning heuristic** that keys off the *shape of the process command line*, not file content. The flagged shape is a `powershell` process whose arguments are a **remote download-cradle** — `irm`/`iwr` (`Invoke-RestMethod`/`Invoke-WebRequest`) piped into `iex` (`Invoke-Expression`) — combined with stealth/bypass flags (`-ExecutionPolicy Bypass`, `-NoProfile`, sometimes `-WindowStyle Hidden` / `-NonInteractive`).

That is exactly the dropper pattern used by the [ClickFix](https://www.microsoft.com/en-us/security/blog/2025/08/21/think-before-you-clickfix-analyzing-the-clickfix-social-engineering-technique/) social-engineering campaigns (fake CAPTCHA / "verify you're human" pages that tell victims to paste a PowerShell one-liner into Run or cmd). Those campaigns exploded in 2024–2025, so Defender flags the shape aggressively — a **false positive** on legitimate installers that use the same idiom (scoop, chezmoi, etc. all ship `irm|iex`). Community FP report: <https://github.com/DeusData/codebase-memory-mcp/issues/230>.

Two things make it worse — and both were briefly in this repo's docs:

- **`-ExecutionPolicy Bypass`** on the command line is a strong signal, and it is *unnecessary*: `iex` of a downloaded **string** isn't gated by execution policy anyway (policy governs `.ps1` *files*).
- **Wrapping the cradle in `powershell -Command "…"`** (the cmd form) puts the whole `irm|iex` onto a *process command line*. Typing `irm|iex` inside an already-open PowerShell does not, so the interactive form is far less likely to trip the model.

## Workaround

Don't run the cradle on a cmd command line. Either:

1. Start PowerShell first, then run the one-liner **interactively** (the cradle never lands on a process command line):

   ```bat
   powershell
   ```
   ```powershell
   irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
   ```

2. Download → inspect → run the **file** (a normal operation, not a download-execute — and you can read it first):

   ```bat
   powershell -Command "irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 -OutFile $env:TEMP\bootstrap.ps1"
   notepad "%TEMP%\bootstrap.ps1"
   powershell -ExecutionPolicy Bypass -File "%TEMP%\bootstrap.ps1"
   ```

Do **not** "fix" this by adding a Defender exclusion or clicking *Allow* on the blocked cradle — that reflex is precisely what a real ClickFix attack relies on. Only ever run an `irm|iex` you can trace to a source you trust.

## Prevention

- `docs/setup.md` + `docs/setup.zh-TW.md` ship the two safe forms above plus a `!!! warning` explaining the FP; they do **not** present `powershell -c "irm|iex"` as the recommended command.
- When authoring any Windows install one-liner: keep the cradle **interactive** (inside pwsh), drop `-ExecutionPolicy Bypass` / `-NoProfile` / `-WindowStyle Hidden` from anything on a `powershell -Command` line, and prefer download-to-file for the inspectable path.

## Related

- `docs/setup.md` / `docs/setup.zh-TW.md` — "One-line install" + the ClickFix warning admonition
- `bootstrap.ps1` — the (benign) script being fetched
- Microsoft, "Think before you Click(Fix)": <https://www.microsoft.com/en-us/security/blog/2025/08/21/think-before-you-clickfix-analyzing-the-clickfix-social-engineering-technique/>
- Community false-positive report: <https://github.com/DeusData/codebase-memory-mcp/issues/230>
