# Rationale

Why this setup makes the choices it does.

## PowerShell 7, not cmd/DOS

`cmd.exe` (the DOS-lineage shell) has no real scripting story: no functions worth
the name, no structured data, awkward quoting. **PowerShell 7 (`pwsh`)** is the
modern default on Windows — an object pipeline, real modules, cross-platform, and
first-class `init` integration for every tool here (starship, zoxide, mise, atuin,
fzf, direnv). Windows PowerShell 5.1 still ships in-box but is frozen; we install
and target pwsh 7.

(WSL is great, but it's a Linux environment — handled by the cross-platform
dotfiles, not this repo. This repo is about a good *native* Windows shell.)

## scoop for CLIs + winget for apps, not Chocolatey

| | scoop | winget | Chocolatey |
|---|---|---|---|
| Admin required | no (user-scoped) | for machine-scope apps | usually yes |
| Best at | CLI/dev tools | GUI/Store apps | broad legacy coverage |
| Reproducible | `scoop export/import` | `winget export/import` | `packages.config` |
| Update model | `scoop update *` | `winget upgrade --all` | `choco upgrade all` |

**scoop** installs developer CLIs into a per-user directory with **no UAC prompts**,
easy version pinning, and clean uninstalls — ideal for the ~20 shell tools here.
**winget** is Microsoft's official manager and has the best catalog for GUI apps
and first-party installers (VSCode, PowerToys, Steam, …).

**Chocolatey** was the long-time default and still has the broadest package
coverage, but it's admin-heavy and less reproducible for a per-user dev setup. It
stays a documented fallback for the rare package missing from both scoop and winget.

## starship, not oh-my-posh

Both are prompt engines; running both is redundant. We use **starship** because the
exact same `starship.toml` already drives the macOS and Linux dotfiles — one config,
one behavior everywhere (`starship init powershell`). oh-my-posh is excellent and
very PowerShell-native, but adopting it would mean a second, Windows-only prompt
config to maintain for no functional gain here.

## A parallel PowerShell tree, not a ported shell layer

The macOS/Linux dotfiles have a large POSIX `shell/*.sh` layer. Mechanically
translating it to PowerShell would be a maintenance sink (two dialects of the same
logic drifting apart). Instead the PowerShell config is written **natively** in
`profile.d/*.ps1` — idiomatic pwsh, only the *behaviors* shared, not the code.

## Native `copilot-proxy`, not a bash shim

The `copilot-proxy` tool series is reimplemented as a real PowerShell module
(`Invoke-RestMethod`, `Start-Process`, `ConvertFrom-Json`) rather than shelling out
to the original bash. Only the Bun throttle shim (pure JS) is reused verbatim. See
[copilot-proxy](copilot-proxy.md).
