# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding
agents when working with code in this repository. `CLAUDE.md` is a symlink to this file.

## What this is

Standalone, **Windows-only** dotfiles managed by [chezmoi](https://chezmoi.io),
targeting **PowerShell 7 (pwsh)**. It is a companion to the cross-platform
macOS/Linux repo `daviddwlee84/dotfiles` — the PowerShell layer is written
natively, **not** ported from that repo's POSIX shell config. No ansible;
packages install via **scoop** (CLI) + **winget** (GUI). Published at
`github.com/daviddwlee84/dotfiles-windows`.

**Dev box vs target:** the deploy target is Windows, but this checkout is usually
edited on macOS/Linux. You therefore **cannot execute the `.ps1` run-scripts
here** (they call winget / `%APPDATA%`). Validate with the isolated-apply +
render/parse pattern below; the `windows-latest` CI is the real gate.

## Commands

Real machine:

- `chezmoi apply` / `chezmoi diff` (or `just apply` / `just diff`)
- `just upgrade-scoop` / `just upgrade-winget`

Validate locally (needs a local pwsh, e.g. installed to `~/.local/bin/pwsh`):

- Lint: `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"` (fails only on Error; the excludes are deliberate — see the settings file header)
- Tests: `pwsh -NoProfile -c "Invoke-Pester -Path ./tests"` (single file: `Invoke-Pester -Path ./tests/Copilot.Tests.ps1`)
- Docs: `just docs-build` (= `uv run --with mkdocs-material --with mkdocs-static-i18n mkdocs build --strict`)

Isolated apply + template render (the core idiom for testing without a Windows
box — all chezmoi state is redirected to a temp dir, so it never touches your
real setup):

```bash
TMPD=$(mktemp -d); mkdir -p "$TMPD/home"
chezmoi init --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
  --destination="$TMPD/home" --no-tty \
  --promptChoice='Role: workstation (full desktop) or minimal (shell only)=minimal' \
  --promptString='Your full name (git)=T' --promptString='Your git email=t@e.com' ...  # EVERY prompt, exact text
chezmoi apply --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
  --destination="$TMPD/home" --exclude=scripts   # scripts can't run off-Windows
chezmoi execute-template --config="$TMPD/c.toml" --source="$PWD" < some.ps1.tmpl > r.ps1  # then parse r.ps1 with pwsh
```

## Architecture (big picture)

- **Init** — `.chezmoi.toml.tmpl` `[data]` prompts once (`role` → coarse defaults, then `installX` toggles) and sets `[interpreters.ps1] = pwsh` so chezmoi runs `.ps1` scripts under pwsh. Prompts are hand-authored here (the parent repo generates them; this repo does not).
- **Shell** — `Documents/PowerShell/Microsoft.PowerShell_profile.ps1` is a thin `$PROFILE` loader that dot-sources `dot_config/powershell/profile.d/*.ps1` in numeric order (env → tool activation → aliases → apps/audio/clipboard → copilot import → yazi → tv cache → psreadline). Add a shell feature = a new numbered fragment. User overrides go in the untracked `~/.config/powershell/local.ps1`.
- **Packages** — `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` is the single source of truth for installs: scoop (CLI), winget (GUI), npm (AI agents), PSGallery (PSFzf / AudioDeviceCmdlets), all gated by init toggles. Fault-tolerant (see invariants).
- **copilot-proxy** — `dot_config/powershell/modules/Copilot/` is a native PowerShell port of the parent's `43_copilot_proxy.sh` / `44_copilot_embed.sh` (runs the copilot-api fork so GitHub Copilot can back Claude Code). Reuses the Bun `copilot-throttle-shim.js` verbatim.
- **Config surfaces** — Alacritty (`AppData/Roaming/alacritty/`), Windows Terminal (a run_onchange that merges `profiles.defaults` non-destructively), editors (a run_onchange that deep-merges `editors/*.json` into `%APPDATA%\{Code,Cursor}\User`), television channels (`AppData/Roaming/television/`), starship + yazi (`~/.config`, yazi via `YAZI_CONFIG_HOME`).
- **Docs** — bilingual mkdocs-material (`docs/X.md` + `docs/X.zh-TW.md`), deployed to GitHub Pages by `.github/workflows/docs.yml`. `docs/rationale.md` records the design choices (scoop > Chocolatey, starship > oh-my-posh, pwsh > cmd, native pwsh tree > ported shell layer).
- **CI** — `.github/workflows/windows.yml` on `windows-latest` is the real gate: PSScriptAnalyzer, non-interactive `chezmoi init --apply`, render+parse of every `.ps1.tmpl`, and Pester.

## Conventions & hard invariants

1. **A new/renamed init prompt must update the CI flags in the same commit.** `chezmoi init --promptBool/--promptChoice "<text>=value"` matches the prompt's exact TEXT (3rd arg to `promptXOnce` in `.chezmoi.toml.tmpl`), used non-interactively by `.github/workflows/windows.yml`. Forget it → CI's init hangs/EOFs. Corollary: **never put `=` in a prompt's text** — the `name=value` parser splits on the first `=` (this broke the `role` prompt once).
2. **Run-scripts must never abort the apply.** The installer + editor/terminal/backup/skill scripts use `$ErrorActionPreference='Continue'` (+ `PSNativeCommandUseErrorActionPreference=$false`), collect failures via `Register-Failure`, print a summary, and exit 0. One bad scoop/winget manifest (e.g. btop's stale `.conf`) must not stop the rest.
3. **Preserve raw escapes when authoring config with control chars.** Alacritty CSI-u (`[…u`), VSCode `sendSequence`, tv `\t` — hand-typing tends to drop them. Generate via a throwaway Python script and re-parse (`tomllib` / `json`) to confirm the escape landed.
4. **tv channel commands are `pwsh -NoProfile -Command "…"` inside TOML literal (`'''…'''`) strings** — runs regardless of tv's shell, sidesteps nested-quote escaping; placeholders `{split: :0}` (space) / `{split:\t:0}` (tab). tv reads config from `%APPDATA%\television\` on Windows.
5. **Editors use a run_onchange pwsh merger, not `modify_`** (`modify_` interpreter selection is unreliable on Windows). Overlay sources live in `editors/` (chezmoi-ignored, embedded via `{{ include }}`).
6. **The agent skill body lives once** in `.chezmoitemplates/dotfiles-windows-skill.md`; both `dot_agents/skills/dotfiles-windows/SKILL.md.tmpl` and `dot_claude/skills/dotfiles-windows/SKILL.md.tmpl` render it via `{{ "{{" }} template … {{ "}}" }}` → real files at `~/.agents/skills/` and `~/.claude/skills/`. Edit the shared template, not the two one-line renderers (no symlink/junction — those need elevation/Developer Mode on Windows).
7. **PSScriptAnalyzer exclusions are intentional** (`PSScriptAnalyzerSettings.psd1`): hyphenated command names, `Write-Host`, `Invoke-Expression` for tool init, no-BOM UTF-8. Don't "fix" these; do fix real Errors.

### Cross-file mirrors (same commit)

- New installer tool → `docs/tools.md` **and** `docs/tools.zh-TW.md`.
- New init prompt → `.chezmoi.toml.tmpl` + `windows.yml` flags + `docs/setup.md`/`setup.zh-TW.md` tables + the "What's enabled" block in `.chezmoitemplates/dotfiles-windows-skill.md`.
- New `docs/**/*.md` → its `.zh-TW.md` twin + `nav` + `nav_translations` in `mkdocs.yml`; `just docs-build` must stay green.

<!-- project-knowledge-harness:agent-guidance -->
<!-- Snippet for the project's agent contract file (AGENTS.md / CLAUDE.md /
     similar). The bundled scripts/init.sh appends this between sentinel
     markers; safe to re-run. -->

### Long-term backlog → `TODO.md` + `backlog/`

When the user surfaces an idea explicitly **not** being implemented this
session (signals: "maybe later", "nice to have", "if I'm interested",
"工程量太大需要再評估", "先記下來"), add an entry to [`TODO.md`](TODO.md) using
the priority + effort tag schema. Do **not** create new `ROADMAP.md` /
`IDEAS.md` / `BACKLOG.md` files — `TODO.md` is the single index.

The bundled `scripts/todo-kanban.sh` validates the format. Run it
(`scripts/todo-kanban.sh --validate-only TODO.md`) after editing so syntax
drift is caught immediately.

#### Three ways to add a TODO entry (preferred order)

1. **Structured CLI — `scripts/add-todo.sh`** (default):

   ```
   scripts/add-todo.sh --priority P3 --effort M \
     --title "Title" --description "Description"
   ```

   Inserts a canonically-formatted line into the right `## P*` lane and
   re-runs the validator. Add `--backlog` to also scaffold
   `backlog/<slug>.md` from the bundled template.

2. **Quick capture — `backlog/inbox.md`** (when priority/effort unclear):

   ```
   echo "- maybe add docs versioning with mike" >> backlog/inbox.md
   ```

   When the user asks "sweep the inbox", run
   `scripts/sweep-inbox.sh`. It prompts for the missing fields per loose
   line and calls `add-todo.sh`. Use `--batch` for non-interactive runs
   that only formalize lines with parseable `key=value` pairs.

3. **Direct edit of `TODO.md`** — fine if the format is fresh; run
   `scripts/todo-kanban.sh --validate-only` afterwards.

Add a `backlog/<slug>.md` companion doc when the item meets any of:

- carries a `P?` tag (record what was tried so it doesn't need re-investigation)
- captures a paused troubleshooting session that you intend to fix later
  (preserve the error trace + root cause analysis before context evaporates)
- weighs multiple options (record trade-offs, not only the winner)
- is `[L]` or `[XL]` (architectural; needs design before code)

`[S]` items rarely need a backlog doc — a file path in the `TODO.md` line is
usually enough. See [`backlog/README.md`](backlog/README.md) for the full
template and "when to add a doc" rules.

When implementing a `TODO.md` item, in the same commit:

1. Run `scripts/promote-todo.sh --title "<substring>" --summary "<what shipped>"`
   to move the entry into `## Done` with the dated syntax and re-validate.
2. Mark the corresponding `backlog/<slug>.md` (if any) `Status: shipped`
   and keep it as a historical record (don't delete — future-you may
   revisit adjacent decisions).

`backlog/` is excluded from chezmoi (see .chezmoiignore); it
is repo metadata for maintainers, not user-facing config to deploy.

### Past pitfalls → `pitfalls/`

When you spend more than ~15 minutes debugging something that wasn't
googleable and the fix is non-obvious, write a `pitfalls/<slug>.md`
capturing:

1. **Verbatim symptom** — copy-paste error messages exactly, do not
   paraphrase (preserves grep-ability for future-you / future agent)
2. **Root cause** — why this happens (with source / docs / upstream issue link)
3. **Workaround** — copy-pasteable commands or config diff
4. **Prevention** — how to avoid stepping on this again

Title the doc by the **symptom**, not the root cause (you'll search by what
you're seeing, not by what you eventually learned). See
[`pitfalls/README.md`](pitfalls/README.md) for the full template and
when-to-add rules.

**Pitfall vs Hard invariant**: a pitfall *graduates* to a Hard invariant in
this file when it (a) recurs across machines/agents/sessions despite being
documented, (b) silently corrupts state, or (c) the workaround is non-obvious
enough that "remember to do X" isn't safe. When graduating, leave the
`pitfalls/<slug>.md` as historical record and link to it from the new
invariant.

`pitfalls/` is excluded from chezmoi (see .chezmoiignore) and
**not** auto-redacted; review for secrets before committing.
<!-- project-knowledge-harness:agent-guidance --> (end)
