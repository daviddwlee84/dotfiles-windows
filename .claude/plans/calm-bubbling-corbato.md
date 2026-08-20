# Context

The current Claude integration enables `claude-hud` and installs a status-line command, but it never manages the plugin’s stable `plugins/claude-hud/config.json`; the machine therefore receives HUD defaults rather than the documented Full display preset. The status-line launcher can also emit errors during the first-launch gap before Claude materializes the plugin cache. Separately, `claude-copilot` promises a hands-off bypass-permissions flow, but its SpecStory zero-argument branch delegates to a create-seeded, user-editable TOML file and can launch plain `claude`. The goal is to make the HUD Full preset deterministic while preserving advanced user settings, and to make the Copilot wrapper enforce its own bypass contract without converting SpecStory’s user config into a fully managed file.

## 1. Manage the Claude HUD Full preset as a narrow overlay

- Add `claude/hud-full-overlay.json`, embedded into the existing run-onchange script so its content participates in chezmoi’s rendered-script hash (`claude/**` is intentionally ignored as a direct deployment source).
- Define and document the owned key set as **“Full as of claude-hud 0.7.1”**, because upstream exposes Full only as prose in `/claude-hud:configure`, not as a JSON Schema or preset constant.
- Own only the documented Full leaves:
  - core/activity: model, project, added directories, context, tools, skills, MCP, agents, todos;
  - information: config counts, token breakdown, usage/reset label, cost, duration, session name/tokens, effort, output style, memory, prompt cache, Claude Code version, compactions, advisor;
  - Git: enabled + dirty, with ahead/behind disabled;
  - Jujutsu: enabled + dirty/conflicts.
- Preserve all advanced and future live keys, including layout/order, colors, thresholds, prompt-cache TTL, routed cost, speed, auth/provider fields, external usage paths, custom text, model/advisor overrides, and unknown nested keys.

## 2. Extend and harden the existing Claude JSON merger

Modify `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`; do not add a second run script.

- Embed both `claude/settings-overlay.json` and `claude/hud-full-overlay.json` at render time.
- Refactor reusable JSON operations into helpers:
  - read an absent/blank file as an empty object and reject malformed/non-object JSON;
  - recursively merge objects with overlay leaves winning and live-only keys surviving;
  - retain the existing special additive/deduplicating `Merge-ClaudeHooks` behavior for `settings.json` only;
  - serialize, parse-validate, and atomically replace through a same-directory temporary file using BOM-free UTF-8; avoid rewriting when bytes are already normalized.
- Process two independent transactions under separate `try/catch` blocks:
  1. `$CLAUDE_CONFIG_DIR/settings.json`, including sound-hook creation/pruning;
  2. `$CLAUDE_CONFIG_DIR/plugins/claude-hud/config.json`, using ordinary recursive merge.
- Fail closed per target: malformed settings must remain byte-for-byte untouched while HUD still updates, and malformed HUD config must not block settings. Warnings remain nonfatal so chezmoi apply never aborts.
- Harden both JSON targets with the shared atomic writer rather than leaving the existing direct `Set-Content` path for settings.

## 3. Make the status-line launcher safe during plugin bootstrap

Update `claude/settings-overlay.json` while retaining its Git Bash/Cygwin, `CLAUDE_CONFIG_DIR`, semantic-version cache selection, width fallback, and Node behavior.

- Silence the whole `/dev/tty`/`stty` probe when no controlling TTY exists.
- Resolve Node and the newest cached `claude-hud/dist/index.js` first.
- Exit successfully with no output when Node, the cache directory, or `dist/index.js` is missing.
- Execute Node only after all prerequisites are present. This turns the first-launch cache race into a temporary blank status line instead of a module-not-found error.

## 4. Keep SpecStory config user-owned and harden the wrapper

Modify `dot_config/powershell/modules/Copilot/Copilot.psm1`; leave `private_dot_specstory/private_cli/create_config.toml` and project `.specstory/cli/config.toml` unchanged.

- Reuse `Get-SpecstoryClaudeCmd` for project → user → `claude` precedence and `ConvertTo-CopilotShQuote` for every appended argument.
- Add one private pure command builder that:
  - starts from the resolved configured base command;
  - recognizes the normal unquoted base `--dangerously-skip-permissions` token and an exact matching user argument;
  - guarantees one bypass flag, suppressing only duplicate exact bypass arguments;
  - preserves all other argument order and duplicates and does not attempt to implement a general shell parser.
- Collapse the SpecStory argument/no-argument split: always invoke `copilot-run specstory run claude -c <complete-command>`, including zero arguments.
- Replace the unsafe `1..0` slicing for lone `--specstory`/`--no-specstory` with the existing Codex pattern `@($Argv | Select-Object -Skip 1)`.
- Keep the direct non-SpecStory branch unchanged. `claude-copilot-once` remains a delegator and inherits the centralized fix.
- Preserve the ownership boundary: direct `specstory run claude` remains governed by user/project configuration; no TOML merger or full-file override is introduced.

## 5. Add regression coverage

### Claude settings/HUD

Create `tests/ClaudeSettings.Tests.ps1`, following the isolated child-process and byte-safety patterns in `tests/CodexConfig.Tests.ps1`.

- Render the run-onchange template with coding agents enabled and execute it against an absolute temporary `CLAUDE_CONFIG_DIR`.
- Cover fresh creation of both targets, every managed Full leaf, preservation of advanced/unknown HUD keys, reassertion of managed leaves, preservation of live Claude settings and foreign hooks, and subsequent byte idempotence.
- Verify strict BOM-free UTF-8 JSON and consistent final newline.
- Verify malformed settings/HUD files remain byte-identical and failures are isolated.
- Verify no writes escape the supplied config directory.
- Execute the deployed status-line command with no TTY/cache and assert silent exit 0.

### SpecStory/Copilot

Extend `tests/Copilot.Tests.ps1` with mocked complete-invocation tests for:

- zero-argument SpecStory use with explicit `-c` and bypass;
- custom project/user base commands and precedence;
- bypass already present in the base or user arguments without duplication;
- spaces and embedded single quotes;
- lone `--specstory` and `--no-specstory` consumption;
- missing-SpecStory direct fallback;
- `claude-copilot-once` delegation without duplicated construction logic.

No CI workflow change is needed because Windows CI already renders PowerShell templates and runs all Pester files.

## 6. Update documentation and architecture mirrors

Update existing pages only:

- `docs/tools.md` and `docs/tools.zh-TW.md`: stable HUD config path, managed Full-0.7.1 leaves, preserved advanced settings, Node-only launcher, and first-launch no-op behavior.
- `docs/rationale.md` and `docs/rationale.zh-TW.md`: two failure-isolated JSON transactions, recursive ownership, atomic/fail-closed writes, and the existing run-onchange caveat after manual `/claude-hud:configure` changes.
- `docs/copilot-proxy.md` and `docs/copilot-proxy.zh-TW.md`: wrappers always construct explicit SpecStory `-c`, preserve configured base-command precedence, and guarantee bypass; direct SpecStory remains configurable.
- `AGENTS.md`: record both managed Claude JSON surfaces and the SpecStory wrapper/config ownership boundary.

Do not add a new docs page or MkDocs navigation entry.

## Verification

Run in order:

1. `pwsh -NoProfile -c "Invoke-Pester -CI -Path ./tests/ClaudeSettings.Tests.ps1 -Output Detailed"`
2. `pwsh -NoProfile -c "Invoke-Pester -CI -Path ./tests/Copilot.Tests.ps1 -Output Detailed"`
3. `pwsh -NoProfile -c "Invoke-Pester -CI -Path ./tests -Output Detailed"`
4. `pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"`
5. Render/parse the updated `.ps1.tmpl` using the repository’s isolated chezmoi-init pattern with `installCodingAgents=true`.
6. `just docs-build`
7. `chezmoi diff`, confirming only the intended settings/HUD targets would change.
8. Check `git status` and leave the pre-existing `.specstory/.project.json`, `.specstory/statistics.json`, and active transcript changes untouched unless a later commit request explicitly includes artifact hygiene.

## Critical files

- `claude/hud-full-overlay.json` (new)
- `claude/settings-overlay.json`
- `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl`
- `tests/ClaudeSettings.Tests.ps1` (new)
- `dot_config/powershell/modules/Copilot/Copilot.psm1`
- `tests/Copilot.Tests.ps1`
- `docs/{tools,rationale,copilot-proxy}.{md,zh-TW.md}`
- `AGENTS.md`
