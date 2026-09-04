# Setup

## One-line install

From a fresh Windows PowerShell (or PowerShell 7) session:

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

Or from **cmd.exe** — there's no native-cmd bootstrap to maintain; you hand off to
the in-box **Windows PowerShell (5.1)**, present on every Windows machine. Start
it, then run the one-liner interactively:

```bat
powershell
```
```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

Or download the script, read it, and run the **file** (safer — and it sidesteps
the Defender warning below):

```bat
powershell -Command "irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 -OutFile $env:TEMP\bootstrap.ps1"
notepad "%TEMP%\bootstrap.ps1"
powershell -ExecutionPolicy Bypass -File "%TEMP%\bootstrap.ps1"
```

For an unattended **minimal** setup, download and inspect the file first, then
pass the role and Git identity explicitly. The canonical `irm | iex` form stays
interactive because it cannot safely accept script parameters:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$env:TEMP\bootstrap.ps1" `
  -NonInteractive -Role minimal `
  -Name 'Da-Wei Lee' -Email 'daviddwlee84@gmail.com'
```

`-NonInteractive` deliberately supports only `minimal`; it rejects a missing
role/name/email **or any existing chezmoi config/source** before changing execution
policy or installing anything. Existing `prompt*Once` data must be changed with
`chezmoi init --prompt` or by editing the config—an unattended rerun cannot
safely turn a stored workstation profile into minimal. This prevents automation
from silently selecting or retaining the full `workstation` bundle.

Use `powershell`, **not** `pwsh` — pwsh isn't installed yet on a fresh box. The
bootstrap logic lives once, in PowerShell (`bootstrap.ps1`): cmd is a poor
language for the elevation / `PATH` / `chezmoi` steps, and these dotfiles are
PowerShell anyway, so a machine with *no* PowerShell couldn't use the repo.

!!! warning "Defender may flag command-line irm|iex as ClickFix or Commando"
    Wrapping the cradle in cmd, SSH, WinRM, a scheduler, or another process
    launcher puts `irm <url> | iex` directly on a `powershell -Command` / `pwsh -c`
    command line. Defender can block that shape as
    **`Trojan:Win32/ClickFix.*!ml`** or **`Trojan:Win32/Commando.A!ml`**, even when
    the fetched script itself is clean. This is the same download-execute pattern
    used by
    [ClickFix](https://www.microsoft.com/en-us/security/blog/2025/08/21/think-before-you-clickfix-analyzing-the-clickfix-social-engineering-technique/)
    fake-CAPTCHA campaigns.

    The first form above is for an **already-open interactive PowerShell**; do not
    send it verbatim as `ssh host 'irm ... | iex'`. For remote automation, transfer
    or download the file first, inspect/verify its hash, then launch a separate
    `pwsh -File` process. Do **not** add a Defender exclusion or click Allow for the
    blocked command line. Maintainer details live in
    `pitfalls/clickfix-defender-flags-cmd-irm-iex.md`.

`bootstrap.ps1` does the following, idempotently:

1. Sets the execution policy to `RemoteSigned` for the current user.
2. Installs [scoop](https://scoop.sh) (user-scoped, no admin — but if the shell
   is already elevated it auto-passes `-RunAsAdmin`, which the installer
   otherwise refuses with *"Running the installer as administrator is disabled
   by default"*).
3. Installs `git`, `7zip`, PowerShell 7 (`pwsh`), `chezmoi`, and `uv` via
   scoop. When pwsh is missing, bootstrap first refreshes Scoop/bucket metadata,
   so the install uses the current **stable** manifest. An existing pwsh is not
   upgraded implicitly; use `scoop update pwsh` when you intend to upgrade it.
4. Refreshes `PATH` from the registry so the just-installed scoop shims
   (`chezmoi`, `pwsh`, `uv`) resolve in the same session.
5. Launches the resolved pwsh and requires `PSEdition=Core`, version 7 or newer.
   A failed/partial PowerShell install stops here instead of failing later inside
   chezmoi.
6. Runs `chezmoi init --apply` (or `chezmoi update` if the source is already
   cloned) — chezmoi runs the repo's `.ps1` scripts under pwsh itself
   (`[interpreters.ps1]`), so it never relaunches the shell. Works from Windows
   PowerShell 5.1 or pwsh 7.

!!! warning "Behind the GFW"
    Keep a VPN on for the bootstrap — scoop downloads git / pwsh / chezmoi / uv
    from **GitHub releases**. The `China mirrors` option only redirects
    pip/uv, npm, RubyGems, Go, and rustup at runtime, **not** scoop's own downloads.

## Init prompts

`chezmoi init` asks a few questions once (answers are stored and never re-asked).
`minimal` means the shell-only development baseline, **not** a tiny install: it
still installs the core CLI/toolchain set and is estimated around 2 GB before
Scoop download cache and temporary staging. See [Disk space](disk-space.md).

!!! note "Private pia checkout"
    `pi-agents` is private. Before enabling coding agents, make sure Git can
    clone it over HTTPS (for example, `gh auth login` followed by
    `gh auth setup-git`). On a completely fresh machine, you can apply once
    with coding agents off, authenticate after `gh` is installed, enable the
    toggle in chezmoi data, and apply again.

| Prompt | Default | Meaning |
|---|---|---|
| Role | `workstation` | `workstation` = full desktop; `minimal` = shell only |
| `Install coding agents (Claude Code, OpenCode, Codex, Copilot CLI, Pi, pia, OMP, SpecStory)` | on (workstation) | native and npm agents plus the Git-managed `pia` combo checkout; credentials and mutable sessions stay outside chezmoi |
| Agent completion feedback | `notify` (workstation) / `none` (minimal) | what a coding agent does when it finishes: `none` / `notify` (Windows toast) / `peon` (game voice line) / `both` — see [Agent completion sounds](agent-sounds.md) |
| SpecStory build | off | build the experimental SpecStory CLI for Windows from the unmerged PR #191 (needs git + go) |
| Windows GUI apps | on (workstation) | VSCode, Cursor, Notepad++, Terminal, Alacritty, PowerToys, Raycast, Docker Desktop, Discord |
| WSL2 backend | on (workstation) | WSL2 for Docker Desktop's backend; self-elevates (one UAC prompt), reboot required |
| WSL2 Ubuntu | off | install a WSL2 Ubuntu distro + bootstrap cross-platform dotfiles (needs `installWsl`) |
| WSL Ubuntu username | your Windows user | UNIX login for the WSL Ubuntu (passwordless sudo, auto-login) |
| WSL Ubuntu bootstrap | `headless` | dotfiles install mode: `headless` (frozen from Windows) / `interactive` / `none` |
| Utility apps | on (workstation) | CPU-Z, GPU-Z, TreeSize, VLC, Everything, ShareX, HWiNFO |
| Gaming apps | off | Steam |
| Extra runtimes | on (workstation) | rustup, go, and ruby via Scoop (node/bun/uv are baseline) |
| Media CLIs | off | ffmpeg, imagemagick |
| Local LLM tools | off | Ollama, LiteLLM |
| Tunnel tools | off | ngrok, cloudflared |
| IaC tools | off | Azure CLI, Terraform, OpenTofu |
| OpenSSH server | off | install + enable sshd (needs admin; opens inbound TCP 22) |
| herdr multiplexer | off | native Windows terminal multiplexer (preview beta) |
| Clink (cmd.exe) | off | starship + zoxide + fzf in `cmd.exe` via Clink (opt-in secondary shell) |
| try (ephemeral workspaces) | off | Ruby CLI (`gem try-cli`): dated trial dirs + fuzzy selector; pwsh command is `tri` |
| translate | on (workstation) | terminal translator CLI + TUI, built from source with `go install` (first build takes minutes) |
| Rime input method (Weasel) | off | Traditional Chinese IME. Machine-scope installer — expect a UAC prompt; deploys the shared Rime `*.custom.yaml` to `%APPDATA%\Rime` |
| China mirrors | off | pip/uv, npm, RubyGems, Go, and rustup via GFW mirrors |
| Managed machine | off | use company PyPI/npm registries and skip apps org policy usually blocks (Tailscale, Grammarly) |
| Public package fallback | off | on managed machines, retry eligible transient corporate PyPI/npm failures once against the isolated public source |
| Backup mode | `smart` | snapshot existing files before the first apply (`smart`/`full`/`off`) |
| PSReadLine vi mode | on | vi editing in the shell |

Re-run every prompt later with `chezmoi init --prompt`, or edit
`%USERPROFILE%\.config\chezmoi\chezmoi.toml`.

## Day-to-day

```powershell
chezmoi diff            # preview pending changes
chezmoi apply           # apply local source edits only (no pull)
chezmoi update --init   # git pull + apply; --init re-asks any newly-added prompts (noop if none)
just upgrade-scoop     # upgrade CLI tools
just upgrade-winget    # upgrade GUI apps
just upgrade-agents    # Pi/OMP/pia + npm coding agents; close running agents first
```

Inside a loaded pwsh session, `cau` (= `chezmoi update --init` + reload
`$PROFILE`) and `cas` (= `chezmoi apply` + reload) are the shortcuts. Prefer
`cau` as the normal "sync my dotfiles" verb — `--init` means a machine that's
behind on newly-added init prompts gets asked them on the next pull.

## Local overrides

Drop machine-specific tweaks or secrets in
`~/.config/powershell/local.ps1` — it is dot-sourced last by `$PROFILE` and is
never managed by chezmoi.

## Git configuration

`~/.gitconfig` is managed by a `modify_` overlay (`modify_dot_gitconfig.ps1.tmpl`).
`chezmoi apply` keeps a fixed set of keys in sync: `user.name` / `user.email`
from the init prompts, `core.autocrlf = input`, `init.defaultBranch`,
`pull.rebase`, `rebase.autoStash`, the Git-LFS filter and `http.postBuffer`.

Everything the overlay does **not** own is preserved untouched — including the
`[credential "..."]` blocks Git Credential Manager writes out of band. That is
precisely why it is an overlay and not a plain managed file: a plain file would
clobber those blocks on every apply and break corporate auth.

Put machine-specific settings in `~/.gitconfig.local`; the baseline wires it up
via `[include]` and chezmoi never touches it. Do not hand-edit `~/.gitconfig` —
managed keys are reverted on the next apply.

`core.hooksPath` is deliberately not set, because Git honours it *instead of*
`.git/hooks/` and it would silently disable per-repository hooks such as the one
`pre-commit install` writes.

## The Raycast / PowerToys clash

Raycast and PowerToys Run both default their launcher to **Alt+Space**. Pick one:
disable PowerToys Run (PowerToys Settings → PowerToys Run → off) or rebind its
hotkey. The installer prints a reminder.
