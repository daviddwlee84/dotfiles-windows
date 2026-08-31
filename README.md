# dotfiles-windows

Native **Windows + PowerShell 7** dotfiles, managed by [chezmoi](https://chezmoi.io).
A self-contained, Windows-only companion to the cross-platform (macOS/Linux)
dotfiles at **[daviddwlee84/dotfiles](https://github.com/daviddwlee84/dotfiles)** —
the PowerShell layer is written natively rather than ported from the POSIX shell config.

> **Which repo do I install from?**
>
> | Your machine | Use |
> |---|---|
> | **Native Windows** (PowerShell) | **this repo** (`dotfiles-windows`) |
> | macOS / Linux / WSL | [daviddwlee84/dotfiles](https://github.com/daviddwlee84/dotfiles) |

> Status: work in progress. See [`docs/`](docs/) for the full handbook (bilingual
> EN / 繁體中文) once built.

## Quick start

From a fresh Windows PowerShell (or pwsh) session:

```powershell
irm https://raw.githubusercontent.com/daviddwlee84/dotfiles-windows/main/bootstrap.ps1 | iex
```

This installs [scoop](https://scoop.sh) (CLI tools) + [winget](https://learn.microsoft.com/windows/package-manager/)
(GUI apps), PowerShell 7, [chezmoi](https://chezmoi.io) and [uv](https://docs.astral.sh/uv/),
then applies the dotfiles.

## What you get

- **Shell**: PowerShell 7 with a modular `$PROFILE` (`~/.config/powershell/profile.d/*.ps1`).
- **Prompt**: [starship](https://starship.rs) (shared config with the macOS/Linux dotfiles).
- **CLI tools** (scoop): git, neovim, lazygit, zoxide, fzf, bat, eza, ripgrep, fd, gh, delta, jq, yazi (with guarded Git status signs), btop, mise, uv, node, bun.
- **AI agents**: Claude Code, OpenCode, Codex, GitHub Copilot CLI, Pi, Oh My Pi,
  the Git-managed `pia` combo selector, SpecStory, and Antigravity.
- **Editors**: VSCode, Cursor, Notepad++ (shared settings/keybindings).
- **Apps** (winget): Windows Terminal, Alacritty, Raycast, PowerToys, Steam.
- **Optional Herdr**: native preview multiplexer with `prefix+d` launching the
  `dev-cli` task/worktree dashboard, `prefix+Y` Yazi temporary pane, low-frequency copy helpers under `prefix+y`,
  `prefix+alt+e` safely editing, validating, and reloading the live runtime
  config, and a binary-matched official global agent skill.
- **`copilot-proxy`** tool series, rewritten as a native PowerShell module.

Herdr's `prefix+alt+e` edits the existing `HERDR_CONFIG_PATH` target (or
`~/.config/herdr/config.toml`) directly and never invokes chezmoi. A failed edit
is retained as a restrictive `config.toml.invalid-*` sibling while the prior
valid file is restored; a reload failure instead keeps both the valid edit and
its same-directory backup. A later `chezmoi apply` can reassert the canonical
`[theme]`, `[ui]`, `[terminal]`, and `[keys]` tables. To persist a runtime change,
manually and selectively edit `.chezmoitemplates/herdr/config.toml`; do not use
`chezmoi add` or `chezmoi re-add` on this `modify_` target, because either can
replace/bypass the merger and import runtime-owned state.

## Package manager

**scoop for CLIs, winget for GUI apps.** Rationale (why not Chocolatey, why
starship not oh-my-posh, why pwsh not cmd) lives in the docs.

## Layout

| Path | What |
|---|---|
| `.chezmoi.toml.tmpl` | Init prompts (role + feature toggles). |
| `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` | `$PROFILE` loader. |
| `dot_config/powershell/profile.d/` | Modular shell fragments. |
| `dot_config/powershell/modules/Copilot/` | `copilot-proxy` PowerShell module. |
| `dot_config/starship.toml` | Prompt config. |
| `dot_ssh/` | Create-only `~/.ssh/config` skeleton (`Include config.d/*`) + `config.d/` snippets. |
| `.chezmoiscripts/` | Package install + editor-overlay scripts. |
| `bootstrap.ps1` | One-line installer. |
| `docs/`, `mkdocs.yml` | Bilingual documentation site. |

## SSH

`dot_ssh/` ships a create-only OpenSSH skeleton, mirrored from the cross-platform
dotfiles and adapted for Windows:

- `~/.ssh/config` — `Include ~/.ssh/config.d/*` plus conservative `Host *`
  keepalives. **Create-only**: an existing `~/.ssh/config` is never overwritten
  (add the `Include` line by hand if so). chezmoi writes it owner-only so
  Windows OpenSSH won't reject it with "Bad owner or permissions".
- `~/.ssh/config.d/00-defaults` — commented-out global-defaults stub.
- `~/.ssh/config.d/01_git` — `github.com` over `ssh.github.com:443` (survives
  port-22 filtering) + `gitlab.com`, with commented multi-account / SOCKS5-proxy
  examples.

Agent handling differs from macOS/Linux: use the Windows **OpenSSH
Authentication Agent** service (`Set-Service ssh-agent -StartupType Automatic`;
`Start-Service ssh-agent`; `ssh-add`). The client uses the
`//./pipe/openssh-ssh-agent` named pipe by default — no `SSH_AUTH_SOCK` needed.

To get a key onto a remote (including a ProxyJump chain, or another Windows
sshd box), run `ssh-setup-remote <host>` — see
[docs/shell.md § SSH key setup](docs/shell.md#ssh-key-setup-ssh-setup-remote).

## Manual dotfiles ops

**First-time install** (fresh machine — no chezmoi yet): run the
[Quick start](#quick-start) one-liner. `bootstrap.ps1` installs scoop, git,
pwsh, chezmoi and uv, then runs `chezmoi init --apply` (asking the init prompts
once). You only do this once per machine.

**Day-to-day** (chezmoi already installed): pull the latest and re-apply.

```powershell
chezmoi update --init   # git pull + apply; --init re-asks any newly-added prompts (noop if none)
chezmoi diff            # preview pending changes without applying
chezmoi apply           # apply local source edits only (no pull)
just upgrade-scoop      # upgrade CLI tools
just upgrade-winget     # upgrade GUI apps
just upgrade-agents     # Pi/OMP/pia + npm agents (close running agents first)
just upgrade-dev        # upgrade the dev task/worktree CLI (Herdr stack)
just upgrade-herdr      # pane-preserving Herdr update + matching agent skill
just upgrade-yazi-plugins # upgrade Yazi/Ya, then git.yazi
```

Inside a loaded PowerShell session there are shortcuts (see
`profile.d/20_aliases.ps1`): **`cau`** = `chezmoi update --init` + reload
`$PROFILE`, **`cas`** = `chezmoi apply` + reload. Prefer `cau` as the normal
"sync my dotfiles" verb.

<!-- project-knowledge-harness:readme-roadmap -->
<!-- Snippet for project's README.md, placed near other meta sections like
     "Customization" or "Contributing". -->

## Roadmap & lessons learned

Forward-looking work — long-term ideas, deferred items, things needing
evaluation — lives in [`TODO.md`](TODO.md), prioritised P1 → P3 with effort
estimates (S/M/L/XL). Items with accompanying research, design notes, or paused
troubleshooting link to a corresponding [`backlog/<slug>.md`](backlog/) doc.

Backward-looking knowledge — past traps and non-obvious debugging — lives in
[`pitfalls/`](pitfalls/), titled by symptom so future-you can grep the error
message and land on the root cause + workaround instead of re-debugging from
scratch.
<!-- project-knowledge-harness:readme-roadmap --> (end)
