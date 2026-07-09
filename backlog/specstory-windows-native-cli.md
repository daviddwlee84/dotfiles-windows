# SpecStory Windows-native CLI (track PR #191)

**Status**: P? — blocked on upstream (experimental build available)
**Effort**: M
**Related**: `TODO.md` · `scripts/build-specstory.ps1` · `justfile` (`specstory-build`) · `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (npm block) · `dot_config/powershell/modules/Copilot/`

## Context

2026-07. `npm i -g @specstory/cli` 404s — SpecStory has **no npm package** and
**no native-Windows CLI release**. Official install is macOS Homebrew
(`brew tap specstoryai/tap && brew install specstory`); Linux/WSL get GitHub
release binaries. The Copilot module (`claude-copilot`, session auto-save)
degrades gracefully when `specstory` is absent, so this is nice-to-have, not
blocking.

## Investigation (upstream status)

- **issue #132** — maintainer initially recommended running Claude Code +
  SpecStory under **WSL** on Windows; said native Windows CLI wasn't a
  near-term roadmap priority (no Windows users on the team) but "not
  impossible", later "We are working on this now."
- issue #132 was **closed** because the **VS Code extension** (`1.0.0`) added
  Windows support for exporting Claude Code sessions — but the comment
  explicitly notes **the CLI is still behind**, pointing at PR #191.
- **PR #191** — adds a Windows build target, WSL/SSH remote-workspace
  discovery, Cursor/Copilot IDE workspace-URI parsing, `--config-dir`,
  `--project-path`, `--git-origin`, etc.
- PR #191 state (at time of writing): **open, not merged, not draft,
  `mergeable=false`**. Large: ~67 commits, 38 files, +3159/−415. Visible
  review is mostly Copilot review comments (naming, unused fn, XML stripping);
  reviewer request → `belucid`. No confirmed human-maintainer approval.

## Routes (which SpecStory path works on Windows today)

| Route | Status |
|---|---|
| VS Code extension — export Claude Code sessions | supported (per issue #132) |
| Cursor / VS Code chat-history extension | should work |
| Native `specstory.exe` CLI | **PR #191, unmerged / no release** |
| SpecStory CLI under WSL + Claude Code | official stopgap |
| Self-build PR #191 | experimental (this repo: `just specstory-build`) |

## What this repo does now

- **Omitted** `@specstory/cli` from the npm install list (it 404s).
- Added an **opt-in experimental build** of PR #191:
  `just specstory-build` → `scripts/build-specstory.ps1` (git clone → fetch
  `pull/191/head` → `go build` → `~/.local/bin/specstory.exe`). Needs `git` +
  `go` (Extra runtimes toggle or `scoop install go`). Treated as experimental.

## Revisit criteria (when to promote out of backlog)

- **PR #191 merges / a Windows release ships** → replace the experimental build
  with the official install (npm if published, else scoop/winget/GitHub
  release), re-add to the standard installer, drop `scripts/build-specstory.ps1`
  + the `just` recipe (or repoint them at the release), update `docs/tools.md`
  + `.zh-TW`.
- If upstream publishes an **npm package** after all → simplest path: add it
  back to the `Npm-InstallGlobal` list.

## References

- getspecstory repo: https://github.com/specstoryai/getspecstory
- issue #132 (Windows support discussion): https://github.com/specstoryai/getspecstory/issues/132
- PR #191 (Windows/WSL/SSH support): https://github.com/specstoryai/getspecstory/pull/191
- SpecStory CLI docs (install): https://docs.specstory.com/quickstart
