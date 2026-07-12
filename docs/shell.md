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
| `20_aliases.ps1` | aliases + helpers (`reload`, `cas`/`cau`, modern-CLI shims) |
| `21_git.ps1` | oh-my-zsh `git`-plugin aliases ported to pwsh (`gst`, `gco`, `gl`=pull, `gcam`, `glol`, …) |
| `28_tldr.ps1` | `tldrf` — tldr with a `zh_TW → zh → en` language fallback |
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

## cmd.exe via Clink

pwsh is the default and primary shell here — but `cmd.exe` still shows up (some
tools spawn it, and muscle memory dies hard). The **opt-in `installClink` toggle**
gives the DOS prompt a starship prompt plus `z` dir-jumping and Ctrl-R/Ctrl-T
fzf. It reuses what pwsh already has: the **same `~/.config/starship.toml`**, and
the `XDG_*` vars that `run_onchange_after_03_xdg_env.ps1` persists to the **User
registry** — so cmd inherits them with no profile of its own.

cmd's line editor is **[Clink](https://chrisant996.github.io/clink/)** — its
PSReadLine analog. With `installClink` on, the packages script installs Clink
(scoop `main`), registers a per-user cmd **AutoRun** (`clink autorun install`, no
admin), and populates the Clink profile dir (`%LocalAppData%\clink`):

| File | Source | Gives you |
|---|---|---|
| `starship.lua` | managed by chezmoi (ours) | starship prompt (`starship init cmd`) |
| `zoxide.lua` | fetched from `clink-zoxide` at apply | `z` / `zi` directory jumping |
| `fzf.lua` | fetched from `clink-fzf` at apply | Ctrl-R history · Ctrl-T files · Alt-C dirs |

`starship.lua` is the only piece committed to this repo (a one-line loader that
runs `starship init cmd`). The two community bridges have no scoop/winget
manifest — and zoxide has no native cmd target — so, like herdr, they're fetched
from upstream into `%LocalAppData%\clink` at apply time (network failures are
non-fatal; starship still works offline).

!!! note "Prompt parity, not feature parity"
    cmd gets the **prompt + navigation**, not the pwsh feature set. atuin, direnv,
    and Television have no cmd/Clink path, and every PowerShell function/module —
    the `ll`/`gs`/`reload` aliases, `y` (yazi), `sysvol`, the `copilot-proxy`
    module — is pwsh-only. For the full experience use pwsh; Clink just makes an
    unavoidable cmd session pleasant. Inspect it with `clink info` (lists the
    profile dir + loaded scripts).

## Git aliases

`profile.d/21_git.ps1` ports the whole [oh-my-zsh `git` plugin](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/git)
to native pwsh functions, so the ~200 aliases the macOS/Linux dotfiles get for
free (`gst`, `gco`, `gcam`, `gp`, `gl`, `glol`, `grbom`, `gwip`, …) mean the same
here. Fuzzy-browse the live set with `tv aliases`; preview shows each definition.

Three deliberate Windows-only differences from upstream omz:

| Difference | Why |
|---|---|
| `gcm` / `gm` are **not** defined | They stay the PowerShell built-ins `Get-Command` / `Get-Member`. Use `gswm` (switch to main) and the `gma`/`gmc`/`gms`/`gmff` merge family instead. |
| `gl` = `git pull` | Matches upstream omz (replacing this repo's earlier `gl` = `git log`). For a graph log use `glo` / `glog` / `glol` / `glola`. `gs` is kept as a bonus `git status` alias; `gst` is the canonical one. |
| `gbD` / `gcB` / `gbgD` collapse to `gbd` / `gcb` / `gbgd` | pwsh command names are case-**insensitive**, so the force variants can't be distinct — only the safe lowercase form is defined (a mistyped `gbD` never force-deletes). Force via the explicit flag: `gbd --force <b>`, `gco -B <b>`. |

Because a built-in alias outranks a same-named function, the fragment first drops
the shadowing aliases for `gc` (Get-Content), `gcb` (Get-Clipboard), `gcs`
(Get-PSCallStack), `gl` (Get-Location), `gp` (Get-ItemProperty) and `gpv`
(Get-ItemPropertyValue). Reach those cmdlets by their full name if you need them.

## herdr workspace helpers (`hvibe` / `hcode` / …)

When the opt-in **herdr** multiplexer is installed, `profile.d/25_herdr.ps1` adds
PowerShell analogs of the macOS/Linux dotfiles' `24_herdr.sh` helpers — the same
muscle-memory for spinning up agent workspaces. The fragment is inert if `herdr`
isn't on PATH.

| Command | Alias | What it does |
|---|---|---|
| `herdr-vibe` | `hvibe` | New `vibe/<repo>` workspace: N agent panes + a lazygit tab + an nvim tab. E.g. `hvibe 3 codex`, `hvibe --agents claude,codex`, `--tab-per-agent`. |
| `herdr-code` | `hcode` | New `coding-agent/<repo>` workspace: nvim + agent split + a monitor tab (btop). E.g. `hcode`, `hcode codex`. |
| `herdr-here` | `hhere` | Plain workspace at `$PWD` (+ optional command) and attach. No git repo needed. |
| `herdr-root` | `hroot` | Like `hhere`, but opens at the git-root. |
| `herdr-mark` / `herdr-unmark` | `hmark` / `hunmark` | Flag / clear a pane's ⭐ "review-pending" status (defaults to `$env:HERDR_PANE_ID`). |

Run from **outside** herdr these attach a client so the new workspace is visible;
from **inside** they just focus it. `--no-attach` builds in the background;
`--on-exit shell\|kill\|restart` controls each pane after its command exits;
`--session NAME` targets a running `herdr --session NAME`.

Differences from the Unix original: no `jq` (native `ConvertFrom-Json`); each
pane's on-exit wrapper is a pwsh script passed as `pwsh -EncodedCommand …` rather
than a bash `trap`; and SpecStory auto-wrapping only engages if a `specstory` CLI
is on PATH (no Windows build yet, so agents run raw).

!!! warning "herdr is preview/beta"
    herdr's Windows build is opt-in (`installHerdr`) and preview-only; these
    helpers drive its CLI scripting surface (`herdr workspace|tab|pane`), which is
    validated on a real Windows box, not in CI.
