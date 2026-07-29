# Rime/Weasel types 简体 after install; the input method is registered as Simplified Chinese

**Symptoms** (grep this section):
- After a scripted / silent install of Weasel（小狼毫）, Settings › Time & Language ›
  Language shows the IME under **中文（简体，中国）** instead of **中文（繁體，台灣）**.
- Typing produces **简化字** even though `default.custom.yaml` selects `bopomofo_tw`
  / the schema itself is a Traditional one.
- The 安裝選項 / "installation options" dialog (where you'd normally pick the input
  language) **never appeared** during install, so there was no chance to choose.
- `winget install --id Rime.Weasel -e --silent` "succeeds" but the language is wrong.
- Re-running the installer interactively and picking 中文（臺灣）fixes it — which is
  the tell that this is a *registration* problem, not a schema/config problem.

**First seen**: 2026-07
**Affects**: `Rime.Weasel` via winget (any version; NSIS installer), and any other
unattended install path that passes only `/S`
**Status**: fixed in this repo — `Install-Weasel` passes `--custom '/T'`

## Symptom

`Rime.Weasel`'s winget manifest is `InstallerType: nullsoft`, so winget's silent
install passes the standard NSIS `/S`. The install completes with exit code 0 and
Weasel works — but it is registered as **Simplified Chinese**, and the options
dialog that would have let you choose is skipped precisely *because* the install
was silent.

Changing `schema_list`, or picking a Traditional schema from `Ctrl+`` `, does not
fix it: the schema and the registered TSF text-service language are different
things. The candidate window will still be labelled 简体 and Windows will list the
IME under 中文（简体，中国）.

## Root cause

`rime/weasel@master:output/install.nsi` builds the argument for `WeaselSetup.exe`
from the installer's own command line:

```nsis
  ClearErrors
  ${GetOptions} $R0 "/S" $R1
  IfErrors +2 0
  StrCpy $R2 "/s"
  ${GetOptions} $R0 "/T" $R1
  IfErrors +2 0
  StrCpy $R2 "/t"

  ExecWait '"$INSTDIR\WeaselSetup.exe" $R2'
```

So `/S` alone → `WeaselSetup.exe /s`. And in
`rime/weasel@master:WeaselSetup/WeaselSetup.cpp`:

```cpp
  bool hans = !wcscmp(L"/s", lpCmdLine);
  if (hans)
    return install(false, silent);
  bool hant = !wcscmp(L"/t", lpCmdLine);
  if (hant)
    return install(true, silent);
```

`/s` is `install(hant = false, …)` — **Simplified**. The `/T` branch that would
set `hant = true` is only taken when `/T` is *also* on the installer's command
line, and `/T` is not documented anywhere in the README, the wiki, or the winget
manifest. There is no separate winget manifest for a Traditional build.

The same file also shows why the dialog vanishes — later in `install.nsi`:

```nsis
  IfSilent deploy_silently
  ExecWait "$INSTDIR\WeaselDeployer.exe /install"
  GoTo deploy_done

  deploy_silently:
  ExecWait "$INSTDIR\WeaselDeployer.exe /deploy"
```

Silent mode skips `/install` (the options dialog) entirely and goes straight to a
deploy. Convenient for automation, but it means the language default is silently
accepted.

## Workaround

Pass `/T` through winget with `--custom`. NSIS's `GetOptions` reads both flags and
the later `StrCpy` wins, so `/S /T` gives a silent install registered as
Traditional:

```powershell
winget install --id Rime.Weasel -e --silent --custom '/T' `
    --accept-source-agreements --accept-package-agreements
```

Note `--scope user` can never work here: the manifest is `Scope: machine` and
`install.nsi` declares `RequestExecutionLevel admin`, so the install always
elevates.

To fix a box that is *already* wrong, without reinstalling — `WeaselSetup.exe /t`
re-registers the text service (it self-elevates via `ShellExecuteEx runas`, so
expect a UAC prompt):

```powershell
$dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Rime\Weasel' -Name InstallDir).InstallDir
& "$dir\WeaselSetup.exe" /t     # register as Traditional (needs admin)
& "$dir\WeaselSetup.exe" /lt    # Weasel's own UI in 繁體 (HKCU, no admin)
```

## The rest of the undocumented `WeaselSetup.exe` CLI

Found the same way — reading `WeaselSetup/WeaselSetup.cpp`, because `/?` only pops
a GUI message box. Everything except `/t` `/s` `/u` `/i` writes only `HKCU` and
needs no elevation:

| Flag | Effect | Registry written |
|---|---|---|
| `/t` / `/s` | register TSF service as Traditional / Simplified (**admin**) | — |
| `/i` | interactive install options dialog | — |
| `/u` | uninstall (**admin**) | — |
| `/lt` `/ls` `/le` | Weasel UI language 繁體 / 简体 / English | `HKCU\Software\Rime\weasel\Language` |
| `/userdir:<dir>` | relocate the Rime user folder | `HKCU\…\RimeUserDir` |
| `/du` / `/eu` | disable / enable auto-update check | `HKCU\…\Updates\CheckForUpdates` |
| `/toggleascii` / `/toggleime` | what `Ctrl+Space` toggles | `HKCU\…\ToggleImeOnOpenClose` |
| `/testing` / `/release` | update channel | `HKCU\…\UpdateChannel` |

`WeaselDeployer.exe` accepts `/deploy` (= tray menu 重新部署), `/dict`, `/sync`,
`/install`. Both binaries compare `lpCmdLine` with `wcscmp` against the whole
string, so **exactly one argument** may be passed — appending anything else makes
the flag silently fall through to the default (GUI) branch.

## Prevention

- Never install Weasel through the repo's generic `Winget-Install` helper — it has
  no way to pass `--custom`. Use the bespoke `Install-Weasel` in
  `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`.
- After any manual Weasel install or repair, check Settings › Language before
  assuming a wrong-script problem is a config problem.
- Weasel's own auto-update can reinstall the package. A silent update takes the
  same code path, so re-verify the language after an in-place upgrade. (This repo
  leaves `CheckForUpdates=0`, which the silent install sets on its own.)
