# Windows dotfiles — standalone, pure-Windows chezmoi repo

## Context & direction change

Original idea was to graft native-Windows support into the existing macOS/Linux chezmoi repo (`~/.local/share/chezmoi`). Rejected by the user: it forces too many `{{ if eq .chezmoi.os "windows" }}` branches and, worst of all, a mechanical line-by-line port of the POSIX `dot_config/shell/*.sh` layer into PowerShell that would be unmaintainable. Those edits have been **restored** (repo back on clean `main`).

New direction: build a **self-contained, Windows-only chezmoi dotfiles repo in the cwd** (`/Users/david/src/tries/2026-07-09-windows-dotfiles`). PowerShell config is written **natively and idiomatically**, not as a translation of the Unix files. No OS branching (the repo assumes Windows). Genuinely-portable static configs (starship.toml, alacritty.toml, editor settings/keybindings) are **copied in** as the single small files they are — the maintenance cost the user worried about is the *shell* layer, which we now author fresh.

## Confirmed decisions (carried over)

- **Shell**: PowerShell 7 (`pwsh`). WSL is out of scope (that's the existing Linux repo's job).
- **Package manager**: **scoop** (user-scoped, no-admin) for CLI tools + **winget** for GUI apps. Chocolatey documented as fallback only.
- **Prompt**: **starship** (`starship init powershell`), config copied verbatim.
- **Testing**: GitHub Actions `windows-latest` CI is the real gate; local `pwsh` (brew-installed) for PSScriptAnalyzer/Pester + `chezmoi execute-template` render checks. A `dockur/windows` compose is included but flagged x86-Linux-host-only (won't run on this Apple-Silicon Mac).
- **Raycast vs PowerToys**: both default to Alt+Space — Raycast owns it, disable PowerToys Run. Documented + handled in installer.
- **Roles/bundles**: init prompts (name/email + `installX` toggles) like the parent repo, but Windows-scoped; a small set of bundles (workstation / minimal).

## Feature scope (from the request)

Essentials: PowerShell 7, starship, scoop+winget, core CLIs (git, neovim, lazygit, zoxide, fzf, bat, eza, ripgrep, fd, gh, delta, jq, yazi, btop), runtimes (uv required; mise, node, bun). AI agents: claude-code, opencode, codex, github-copilot-cli, specstory, antigravity. Editors: VSCode, Cursor, Notepad++. Apps: Windows Terminal, Alacritty, Raycast, PowerToys, Steam. Native PowerShell rewrite of the `copilot-proxy` tool series (`*.ps1`). Bilingual mkdocs docs.

## Repo layout (cwd is the chezmoi source root)

```
.chezmoi.toml.tmpl                 # init prompts: name/email + installX toggles + bundle
.chezmoiignore                     # keep docs/, mkdocs, README, .github, scripts, bootstrap out of $HOME
.chezmoiscripts/
  run_onchange_after_10_packages.ps1.tmpl        # scoop + winget install, toggle-gated, idempotent
  run_onchange_after_20_editor_overlays.ps1.tmpl # deep-merge VSCode/Cursor settings.json in %APPDATA%
Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tmpl   # $PROFILE loader → dot-sources profile.d/*
dot_config/
  powershell/
    profile.d/                     # native pwsh fragments (NOT a port): 00_env, 10_tools, 20_aliases,
                                    #   30_apps (app*/sys*/clipboard helpers), 40_copilot, 90_psreadline
    modules/Copilot/               # Copilot.psm1 + Copilot.psd1 (copilot-proxy series port)
    copilot-throttle-shim.js       # bun shim, copied verbatim from parent repo
  starship.toml                    # copied verbatim
  alacritty/alacritty.toml         # copied + Windows shell arm
  windows-terminal/settings.json   # Windows Terminal profile (fragment-merged)
editors/                           # VSCode/Cursor settings.json + keybindings.json (shared, applied by script)
bootstrap.ps1                      # irm <raw>/bootstrap.ps1 | iex  → installs scoop, pwsh7, chezmoi, uv, init
justfile                           # just recipes (just is on scoop): apply/diff/upgrade-scoop/upgrade-winget/lint
mkdocs.yml  pyproject.toml         # bilingual mkdocs-material site (en + zh-TW)
docs/                              # *.md + *.zh-TW.md
.github/workflows/{windows.yml,docs.yml}
docker/windows/compose.yml         # dockur/windows, flagged x86-only
README.md  .gitignore
```

## Phases (each = one commit in the cwd repo)

**Phase 1 — Scaffold + shell + prompt.** Repo skeleton, `.chezmoi.toml.tmpl` (prompts + bundles), `.chezmoiignore`, `$PROFILE` loader + `profile.d` fragments (env/PATH, starship, zoxide, fzf, atuin, mise, aliases, PSReadLine), `dot_config/starship.toml`. `README.md` skeleton. `bootstrap.ps1` (installs scoop→pwsh7→chezmoi→uv→`chezmoi init --apply`). Local verify: `pwsh` lint + `chezmoi execute-template`.

**Phase 2 — Packages + manifests + tasks.** `run_onchange_after_10_packages.ps1.tmpl` (scoop CLIs + winget GUI, toggle-gated, idempotent via `scoop list`/`winget list`), reference `scoopfile.json` + `winget` DSC manifest, `justfile` recipes, `.github/workflows/windows.yml` CI (chezmoi apply + PSScriptAnalyzer + Pester). AI agents (npm/winget) wired to `installCodingAgents`.

**Phase 3 — copilot-proxy PowerShell module.** Port `43_copilot_proxy.sh` + `44_copilot_embed.sh` to `Copilot.psm1` exporting `copilot-proxy`/`copilot-run`/`claude-copilot`/`claude-copilot-once`/`copilot-here`/`copilot-model`/`copilot-embed`/`semsearch`. Preserve contract: token `~/.local/share/copilot-api/github_token`, ports 4141/4142, state dir, per-project `.claude/settings.local.json` pin, model `claude-opus-4-8[1m]`, `ANTHROPIC_*` env block. Reuse the JS shim. Pester tests with mocked `Invoke-RestMethod`.

**Phase 4 — Editors + apps + helpers.** VSCode/Cursor/Notepad++ settings + keybindings (deep-merge into `%APPDATA%`), Windows Terminal + Alacritty configs, Raycast/PowerToys/Steam via winget with the Alt+Space resolution, and native `applaunch`/`appquit`/`sysvol`/`sysmute`/clipboard (`x`) helpers in `profile.d/30_apps.ps1`.

**Phase 5 — Docs + CI polish.** Bilingual mkdocs-material site (en + zh-TW): setup guide, tool index (scoop/winget), and rationale pages (**why scoop over Chocolatey, why starship over oh-my-posh, why pwsh over cmd/DOS** — per the user's note). `docs.yml` GitHub Pages workflow. Final README.

## Verification

- Local: `pwsh -c 'Invoke-ScriptAnalyzer -Recurse .'`, `Invoke-Pester`, `chezmoi execute-template` on each `.tmpl`.
- CI: `windows.yml` green (chezmoi init --apply minimal bundle + lint + Pester).
- `uv run mkdocs build --strict`.
- New device: `irm .../bootstrap.ps1 | iex` end-to-end.

## Open choice (proceeding with a sensible default; user can veto)

Shared static configs (starship.toml, alacritty.toml, editor settings) are **copied** into this repo rather than submodule/symlink to the parent dotfiles — they're small and stable, and copying keeps this repo self-contained. Revisit if the user wants a true single source across both repos.
