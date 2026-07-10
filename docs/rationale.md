# Rationale

Why this setup makes the choices it does.

## PowerShell 7, not cmd/DOS

`cmd.exe` (the DOS-lineage shell) has no real scripting story: no functions worth
the name, no structured data, awkward quoting. **PowerShell 7 (`pwsh`)** is the
modern default on Windows — an object pipeline, real modules, cross-platform, and
first-class `init` integration for every tool here (starship, zoxide, atuin,
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

## Runtimes: scoop natives, not mise on Windows

The macOS/Linux dotfiles use **mise** to manage language runtimes. On Windows we
tried it and backed out — runtimes are installed **natively via scoop** (plus
**uv** for Python) instead.

Why mise didn't hold up here:

- **Shims / activate don't reliably expose global tools.** `mise activate`'s
  pwsh prompt-hook and the shims dir both failed to put globally-pinned tools
  (`bun`, `go`) on PATH in practice — `mise use -g bun` "succeeded" yet `bun`
  wasn't found.
- **Arch gaps.** On Windows-on-ARM, `mise use -g bun` records the version but
  ships **no windows-arm64 bun binary**, leaving a dead shim.
- **It fought the machine's existing node.** A pre-existing `nvm` shadowed
  mise's node, so npm used the wrong one.

scoop shims live in `~/scoop/shims`, which scoop persists to the user PATH (and
`profile.d/00_env.ps1` also prepends) — so `node` (`nodejs-lts`), `bun`, `go`,
`rustup`, `ruby` are simply **on PATH**, no activation dance. **Python** is
uv-managed (`uv python install --default`), which also drops unversioned
`python`/`python3` into `~/.local/bin`.

The tradeoff: **no per-project runtime pinning** (mise's headline feature). For a
Windows dev box that's a fair trade for "the tools are actually on PATH." If you
want per-project versions, `scoop install mise` and use it directly — nothing
here depends on it. The full debugging trail lives in
`backlog/windows-arm64-managed-machine-rough-edges.md`.

## Terminal multiplexer: WezTerm, not tmux/zellij

`tmux` and `zellij` are **Unix-only** — there are no native Windows builds — so
they're absent here (you can still run them inside WSL). For a native tmux-like
experience on Windows the options are:

| Option | Splits / tabs | Detach + persist | Notes |
|---|---|---|---|
| **WezTerm** | yes (panes/tabs, Lua `wezterm.mux`) | yes (mux server + `wezterm connect`) | native Windows; closest to tmux |
| Windows Terminal | yes (panes/tabs) | no | great terminal, no session persistence |
| Alacritty | no | no | fast, minimal; pair with a multiplexer |
| tmux / zellij | — | — | Unix-only; use under WSL |

We install **WezTerm** (`wez.wezterm`) as the multiplexer answer: a native
Windows terminal with a built-in multiplexer — split panes, tabs, and a
persistent mux server you can detach from and reconnect to (`wezterm connect`),
plus scriptable layouts via its Lua `wezterm.mux` API. It isn't a 1:1 tmux (the
session/persistence model differs), but it's the closest native experience.
Windows Terminal stays installed for its panes/tabs; Alacritty stays as the fast
minimal option.

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

## XDG paths, not `%APPDATA%`

Windows and XDG split directories on different axes — Windows by whether a
folder *roams* (`AppData\Roaming` vs `AppData\Local`), XDG by *purpose*
(config / data / state / cache) — so `%APPDATA%` is not a clean "Windows XDG".
Rather than map onto it, `profile.d/00_env.ps1` sets `XDG_CONFIG_HOME` and
friends to Unix-style `~/.config` / `~/.local/share` paths. XDG-aware tools
(starship, atuin, zoxide, yazi) then keep a tidy `$HOME` that mirrors the
macOS/Linux dotfiles — one mental model, shared configs. Apps that ignore XDG
and hard-code `%APPDATA%` (VSCode, Cursor, Alacritty) stay there and are managed
at that path. Full mapping, plus the `PATH` mechanics, are in
[Shell & environment](shell.md).
