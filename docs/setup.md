# Setup

## One-line install

From a fresh Windows PowerShell (or PowerShell 7) session:

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

`bootstrap.ps1` does the following, idempotently:

1. Sets the execution policy to `RemoteSigned` for the current user.
2. Installs [scoop](https://scoop.sh) (user-scoped, no admin — but if the shell
   is already elevated it auto-passes `-RunAsAdmin`, which the installer
   otherwise refuses with *"Running the installer as administrator is disabled
   by default"*).
3. Installs `git`, PowerShell 7 (`pwsh`), `chezmoi`, and `uv` via scoop.
4. Re-launches under `pwsh` if it started in Windows PowerShell 5.1.
5. Runs `chezmoi init --apply` against this repo.

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
| Utility apps | on (workstation) | CPU-Z, GPU-Z, TreeSize, VLC, Everything, ShareX, HWiNFO |
| Gaming apps | off | Steam |
| Extra runtimes | on (workstation) | rust, go, ruby via mise (node/bun/uv are baseline) |
| Media CLIs | off | ffmpeg, imagemagick |
| Local LLM tools | off | Ollama, LiteLLM |
| Tunnel tools | off | ngrok, cloudflared |
| IaC tools | off | Azure CLI, Terraform, OpenTofu |
| OpenSSH server | off | install + enable sshd (needs admin; opens inbound TCP 22) |
| herdr multiplexer | off | native Windows terminal multiplexer (preview beta) |
| China mirrors | off | pip / npm / cargo / go / node via GFW mirrors |
| Managed machine | off | skip apps org policy usually blocks (Tailscale, Grammarly) |
| Backup mode | `smart` | snapshot existing files before the first apply (`smart`/`full`/`off`) |
| PSReadLine vi mode | on | vi editing in the shell |

Re-run the prompts later with `chezmoi init` again, or edit
`%USERPROFILE%\.config\chezmoi\chezmoi.toml`.

## Day-to-day

```powershell
chezmoi diff          # preview pending changes
chezmoi apply         # apply
chezmoi update        # git pull + apply
just upgrade-scoop     # upgrade CLI tools
just upgrade-winget    # upgrade GUI apps
```

## Local overrides

Drop machine-specific tweaks or secrets in
`~/.config/powershell/local.ps1` — it is dot-sourced last by `$PROFILE` and is
never managed by chezmoi.

## The Raycast / PowerToys clash

Raycast and PowerToys Run both default their launcher to **Alt+Space**. Pick one:
disable PowerToys Run (PowerToys Settings → PowerToys Run → off) or rebind its
hotkey. The installer prints a reminder.
