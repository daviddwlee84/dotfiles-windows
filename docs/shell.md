# Shell & environment

How a PowerShell session is assembled — what loads, how to reload, and how
`PATH` and the XDG base dirs get set — **without ever touching the Windows
"Environment Variables" GUI**.

## Profile loading

`$PROFILE` (`~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`) is a thin
loader. It dot-sources every fragment under `~/.config/powershell/profile.d/*.ps1`
in sorted (numeric-prefix) order, then your untracked `local.ps1` last. All the
logic lives in the fragments; the loader stays boring.

| Fragment | Does |
|---|---|
| `00_env.ps1` | XDG base dirs, `$env:EDITOR`, PATH |
| `05_mirrors.ps1` | China package mirrors (when enabled) |
| `10_tools.ps1` | `init` hooks: starship, zoxide, mise, atuin, fzf, direnv, tv |
| `20_aliases.ps1` | aliases + helpers (`reload`, `cas`/`cau`, git shortcuts) |
| `30_apps.ps1` | app control (`applaunch`/`appquit`/…), audio, clipboard |
| `35_yazi.ps1` | `y` — launch yazi, cd to where you quit |
| `40_copilot.ps1` | import the `copilot-proxy` PowerShell module |
| `90_psreadline.ps1` | PSReadLine (vi mode, history) |

Modules under `~/.config/powershell/modules` are prepended to
`$env:PSModulePath` by the loader, so they import by name (e.g. `Copilot`).

## Reloading

`reload` **dot-sources** the profile back into the current session — the same
mechanism `$PROFILE` uses at startup:

```powershell
function reload { . $PROFILE }                    # re-source everything
function cas { chezmoi apply  @args; . $PROFILE } # apply, then reload
function cau { chezmoi update @args; . $PROFILE } # git pull + apply, then reload
```

!!! note "reload is additive, not a clean restart"
    Dot-sourcing **re-runs** the profile in place. PATH edits are idempotent
    (guarded, never double-added) and `Set-Alias` / `Import-Module` just
    re-apply — but anything a *previous* load defined that this load no longer
    defines is **not** removed. For a guaranteed-clean state, open a new pwsh
    session.

## PATH: Windows vs Unix

On **Unix**, `PATH` is a single colon-separated variable the shell rc
(`.zshrc` / `.bashrc`) assembles at startup — purely process-scoped, inherited
by child processes, no system database involved. Edit a dotfile, and it changes
on the next shell.

**Windows** has two *persistent* layers stored in the **registry**, plus the
in-process copy:

| Layer | Where | Scope |
|---|---|---|
| Machine PATH | `HKLM\…\Session Manager\Environment` | all users (needs admin) |
| User PATH | `HKCU\Environment` | your account, all your processes |
| `$env:PATH` | in memory, per process | this session + its children |

At logon Windows concatenates Machine + User into each process's `$env:PATH`.
Editing the registry does **not** update already-running processes.

### We change PATH without the GUI

This repo touches `PATH` two ways, both scripted — the System Properties
"Environment Variables" dialog is never opened:

1. **Persistent (registry User PATH) — scoop only.** When scoop installs, it
   writes `~/scoop/shims` into the User PATH programmatically
   (`[Environment]::SetEnvironmentVariable('Path', …, 'User')`), so scoop CLIs
   resolve in *every* shell and GUI app — no admin, no dialog.

2. **In-process only — our profile.** `00_env.ps1` prepends `~/.local/bin` and
   `~/scoop/shims` to `$env:PATH` on every shell start, idempotently and only
   when the directory exists:

   ```powershell
   $UserPaths = @(
       (Join-Path $HOME '.local/bin'),
       (Join-Path $HOME 'scoop/shims')
   ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
   foreach ($p in $UserPaths) {
       if (($env:PATH -split ';') -notcontains $p) { $env:PATH = "$p;$env:PATH" }
   }
   ```

`bootstrap.ps1` does a third, one-shot variant: right after scoop installs the
baseline tools it rebuilds `$env:PATH` from the `Machine + User` registry values
so the just-installed shims resolve **in the same session** (scoop persisted
them, but the running process's copy predates that write).

!!! warning "`~/.local/bin` is pwsh-session-scoped"
    `~/.local/bin` is the Windows home for your own scripts and binaries — same
    path name as Unix. But unlike `~/scoop/shims`, it is added to `$env:PATH`
    **only** by this profile; it is **never** persisted to the registry. So it's
    on PATH inside pwsh sessions that load the profile, but **not** in Windows
    PowerShell 5.1, in GUI apps, or in anything launched outside pwsh. To make a
    binary there visible everywhere, add `~/.local/bin` to the User PATH
    yourself (`setx` or `[Environment]::SetEnvironmentVariable(…, 'User')`).

Resolution order after the profile runs: `~/scoop/shims` → `~/.local/bin` →
inherited PATH (each is prepended, so the last one added ends up first).

## XDG base dirs on Windows

XDG and Windows split directories on **different axes** — XDG by *purpose*
(config / data / state / cache), Windows by *whether it roams* (Roaming vs
Local) — so there is no clean 1:1. The rough mapping:

| XDG (Unix) | Closest Windows folder |
|---|---|
| `XDG_CONFIG_HOME` (`~/.config`) | `%APPDATA%` = `AppData\Roaming` |
| `XDG_DATA_HOME` (`~/.local/share`) | `%APPDATA%` = `AppData\Roaming` |
| `XDG_STATE_HOME` (`~/.local/state`) | `%LOCALAPPDATA%` = `AppData\Local` |
| `XDG_CACHE_HOME` (`~/.cache`) | `%LOCALAPPDATA%` = `AppData\Local` |

`AppData\Roaming` bundles what XDG calls *config* and *data* into one folder;
`AppData\Local` bundles *cache*, *state*, and non-roaming data. ("Roaming" only
actually roams under domain Roaming Profiles / Enterprise State Roaming — on a
standalone PC it's just a folder with that name.)

Rather than live with the ambiguity, `00_env.ps1` sets the XDG variables to
Unix-style paths, so **XDG-aware tools keep a tidy `$HOME` shared with the
macOS/Linux dotfiles**:

```powershell
$env:XDG_CONFIG_HOME = Join-Path $HOME '.config'
$env:XDG_DATA_HOME   = Join-Path $HOME '.local/share'
$env:XDG_STATE_HOME  = Join-Path $HOME '.local/state'
$env:XDG_CACHE_HOME  = Join-Path $HOME '.cache'
$env:YAZI_CONFIG_HOME = Join-Path $env:XDG_CONFIG_HOME 'yazi'  # yazi defaults to %APPDATA%
```

starship, atuin, zoxide, and yazi then read `~/.config`. Apps that **hard-code
`%APPDATA%`** and ignore XDG — VSCode, Cursor, Alacritty — stay in
`AppData\Roaming`, which is why the repo tracks `AppData/Roaming/alacritty/…`
and the backup script's allowlist names `%APPDATA%\Code`, `%APPDATA%\Cursor`,
and `%APPDATA%\alacritty`.

So in this repo `AppData\Roaming` is **not** "Windows XDG" — it's simply where
the non-XDG native apps land. The real XDG role is played by the `~/.config`
paths we set explicitly.
