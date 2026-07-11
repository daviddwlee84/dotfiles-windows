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

Use `powershell`, **not** `pwsh` — pwsh isn't installed yet on a fresh box. The
bootstrap logic lives once, in PowerShell (`bootstrap.ps1`): cmd is a poor
language for the elevation / `PATH` / `chezmoi` steps, and these dotfiles are
PowerShell anyway, so a machine with *no* PowerShell couldn't use the repo.

!!! warning "Defender may flag the cmd irm|iex one-liner as ClickFix"
    Wrapping the cradle on a cmd command line —
    `powershell -ExecutionPolicy Bypass -Command "irm <url> | iex"` — can trip
    Defender's **`Trojan:Win32/ClickFix.*!ml`** machine-learning heuristic. It's a
    **false positive on the command-line _shape_**, not our script (a content scan
    is clean): a `powershell` process whose command line is a remote
    download-cradle (`irm|iex`) plus `-ExecutionPolicy Bypass` / `-NoProfile` is
    exactly the shape the
    [ClickFix](https://www.microsoft.com/en-us/security/blog/2025/08/21/think-before-you-clickfix-analyzing-the-clickfix-social-engineering-technique/)
    fake-CAPTCHA campaigns use. The two forms above avoid it — the cradle never
    lands on a process command line, or you run a file instead — and inside an
    already-open PowerShell the one-liner is fine. Bigger lesson: **never paste a
    `powershell -c "irm|iex"` handed to you by a web page or a "verify you're
    human" prompt — that request _is_ the attack.**

`bootstrap.ps1` does the following, idempotently:

1. Sets the execution policy to `RemoteSigned` for the current user.
2. Installs [scoop](https://scoop.sh) (user-scoped, no admin — but if the shell
   is already elevated it auto-passes `-RunAsAdmin`, which the installer
   otherwise refuses with *"Running the installer as administrator is disabled
   by default"*).
3. Installs `git`, PowerShell 7 (`pwsh`), `chezmoi`, and `uv` via scoop.
4. Refreshes `PATH` from the registry so the just-installed scoop shims
   (`chezmoi`, `pwsh`, `uv`) resolve in the same session.
5. Runs `chezmoi init --apply` (or `chezmoi update` if the source is already
   cloned) — chezmoi runs the repo's `.ps1` scripts under pwsh itself
   (`[interpreters.ps1]`), so it never relaunches the shell. Works from Windows
   PowerShell 5.1 or pwsh 7.

!!! warning "Behind the GFW"
    Keep a VPN on for the bootstrap — scoop downloads git / pwsh / chezmoi / uv
    from **GitHub releases**. The `China mirrors` option only redirects
    pip / npm / cargo / go / node at runtime, **not** scoop's own downloads.

## Init prompts

`chezmoi init` asks a few questions once (answers are stored and never re-asked):

| Prompt | Default | Meaning |
|---|---|---|
| Role | `workstation` | `workstation` = full desktop; `minimal` = shell only |
| Coding agents | on (workstation) | Claude Code, OpenCode, Codex, Copilot CLI, SpecStory |
| Windows GUI apps | on (workstation) | VSCode, Cursor, Notepad++, Terminal, Alacritty, PowerToys, Raycast, Docker Desktop, Discord |
| WSL2 backend | on (workstation) | WSL2 for Docker Desktop's backend; self-elevates (one UAC prompt), reboot required |
| WSL2 Ubuntu | off | install a WSL2 Ubuntu distro + bootstrap cross-platform dotfiles (needs `installWsl`) |
| WSL Ubuntu username | your Windows user | UNIX login for the WSL Ubuntu (passwordless sudo, auto-login) |
| WSL Ubuntu bootstrap | `headless` | dotfiles install mode: `headless` (frozen from Windows) / `interactive` / `none` |
| Utility apps | on (workstation) | CPU-Z, GPU-Z, TreeSize, VLC, Everything, ShareX, HWiNFO |
| Gaming apps | off | Steam |
| Extra runtimes | on (workstation) | rust, go, ruby via mise (node/bun/uv are baseline) |
| Media CLIs | off | ffmpeg, imagemagick |
| Local LLM tools | off | Ollama, LiteLLM |
| Tunnel tools | off | ngrok, cloudflared |
| IaC tools | off | Azure CLI, Terraform, OpenTofu |
| OpenSSH server | off | install + enable sshd (needs admin; opens inbound TCP 22) |
| herdr multiplexer | off | native Windows terminal multiplexer (preview beta) |
| Clink (cmd.exe) | off | starship + zoxide + fzf in `cmd.exe` via Clink (opt-in secondary shell) |
| China mirrors | off | pip / npm / cargo / go / node via GFW mirrors |
| Managed machine | off | skip apps org policy usually blocks (Tailscale, Grammarly) |
| Backup mode | `smart` | snapshot existing files before the first apply (`smart`/`full`/`off`) |
| PSReadLine vi mode | on | vi editing in the shell |

Re-run the prompts later with `chezmoi init` again, or edit
`%USERPROFILE%\.config\chezmoi\chezmoi.toml`.

## Day-to-day

```powershell
chezmoi diff            # preview pending changes
chezmoi apply           # apply local source edits only (no pull)
chezmoi update --init   # git pull + apply; --init re-asks any newly-added prompts (noop if none)
just upgrade-scoop     # upgrade CLI tools
just upgrade-winget    # upgrade GUI apps
```

Inside a loaded pwsh session, `cau` (= `chezmoi update --init` + reload
`$PROFILE`) and `cas` (= `chezmoi apply` + reload) are the shortcuts. Prefer
`cau` as the normal "sync my dotfiles" verb — `--init` means a machine that's
behind on newly-added init prompts gets asked them on the next pull.

## Local overrides

Drop machine-specific tweaks or secrets in
`~/.config/powershell/local.ps1` — it is dot-sourced last by `$PROFILE` and is
never managed by chezmoi.

## The Raycast / PowerToys clash

Raycast and PowerToys Run both default their launcher to **Alt+Space**. Pick one:
disable PowerToys Run (PowerToys Settings → PowerToys Run → off) or rebind its
hotkey. The installer prints a reminder.
