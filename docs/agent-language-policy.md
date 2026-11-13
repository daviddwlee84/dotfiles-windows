# Agent language policy (`agentLanguagePolicy`)

Which language a coding agent writes in, decided by **who reads the output and
how long it lives**: chat in Traditional Chinese, plan files in Traditional
Chinese with English technical terms, long-lived artifacts in whatever the repo
already uses (English by default). Same key, prompt text and rule body as the
parent (macOS/Linux) repo.

> **TL;DR** — answer `zh-TW` to *Agent language policy (none|zh-TW)*.
> `chezmoi apply` then deploys `%USERPROFILE%\.claude\rules\language-policy.md`.
> Your own `~/.claude/CLAUDE.md`, if any, is never touched.

## What the rule says

| Output | Language |
|---|---|
| Conversation: replies, questions (incl. multiple-choice options), progress updates | 繁體中文 (Taiwan usage) |
| Plan-mode plan files | 繁體中文 prose; headings may be bilingual |
| README, `docs/`, ADRs, docstrings, code comments, commit messages, PRs | The repo's convention (its CLAUDE.md / AGENTS.md wins); English if none |
| Internal reasoning / thinking | Unconstrained — whatever is most effective (usually English) |

Technical terms whose translation could be ambiguous, identifiers and product
names stay in English inside Chinese text.

The source of truth is `.chezmoitemplates/agent-language-policy.md`. It is
byte-identical to the parent repo's copy. `.gitattributes` pins it to LF, so the
two stay identical on Windows checkouts too. `tests/AgentLanguagePolicy.Tests.ps1`
compares them whenever both repos are checked out side by side.

## How it is wired

- **Prompt**: `agentLanguagePolicy` (`none` | `zh-TW`, default `none`). It only
  has an effect together with `installCodingAgents`.
- **Target**: `~/.claude/rules/language-policy.md`. Claude Code loads every
  file in `~/.claude/rules/` as a user-level rule in every project, next to
  `~/.claude/CLAUDE.md`.
- **Gate**: `dot_claude/rules/language-policy.md.tmpl` renders empty unless the
  gate is on. chezmoi removes a target whose source renders empty, so switching
  back to `none` deletes the rule. This is a plain file, not a `modify_` script
  or deep-merger. Claude Code never writes to it, so there is no foreign writer
  to coexist with.

To change your answer, edit `agentLanguagePolicy` in
`%USERPROFILE%\.config\chezmoi\chezmoi.toml` (or re-run `chezmoi init --prompt`),
then run `chezmoi apply`. Verify with `/memory` in a new Claude Code session.

## Design choices

- **Not `settings.json` `language`**: Claude Code passes it verbatim as "always
  respond in X". That would also pull commits and docs into Chinese, and it
  changes the voice-dictation and session-title language.
- **Not `~/.claude/CLAUDE.md`**: that file is hand-authored. A separate rules
  file means no migration or merge. If your CLAUDE.md also has a language rule,
  both load and Claude may follow either one, so delete one side.
- **Plan files are named explicitly**, or "docs in English" would capture them.
- **Thinking is left alone**: forcing the thinking trace into the user's
  language costs accuracy (e.g. Qi et al. 2025).
- **Claude Code only** for now. A Codex extension is in `TODO.md`.
