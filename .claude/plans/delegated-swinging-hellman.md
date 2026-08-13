# Context

The current Windows setup has four independent regressions:

1. A failed `npm install @jeffreycao/copilot-api@2.1.0` can be reported as successful because an older package tree/binlink satisfies the current weak postcondition; the requested spec is then stamped and the stale package is launched.
2. `copilot-proxy auth` passes `auth --provider copilot`, so Citty interprets the option value `copilot` as the subcommand and reports `Unknown command copilot`. The supported argv is `auth login --provider copilot`.
3. `doctor --live` probes the first alphabetically sorted model instead of the effective pin, discards structured error bodies, and therefore reports only `HTTP 402`. `billing_not_configured` is an account-wide GitHub Copilot billing configuration error, not a model-specific or retryable failure.
4. The Codex `modify_` overlay mishandles a leading UTF-8 BOM and does not preserve malformed input byte-for-byte. The failed Actions run additionally lacked `uv`/`tomlkit`, so every non-empty TOML merge silently failed closed.

The intended outcome is deterministic package/auth behavior, an actionable and honest live diagnostic, a byte-safe Codex overlay, and a Windows workflow that exercises the real non-empty merge path. Keep the exact `@jeffreycao/copilot-api@2.1.0` pin: it exists on public npm, while the reported `ETARGET` is consistent with the configured corporate mirror lagging. Do not hide the billing error with automatic model replay.

One account-side action cannot be automated by this repository: the account holder must select an organization or enterprise in GitHub’s **Usage billed to** setting at <https://github.com/settings/copilot/features>. The code change will identify this precisely and stop suggesting ineffective model/shim retries.

Current baseline is `7c0843c`; preserve its Codex-always-uses-shim changes in `Copilot.psm1` and the Responses tool-description normalization in `copilot-throttle-shim.js`. The only untracked item is the current SpecStory transcript; leave it untouched unless a later commit request invokes `agent-history-hygiene`.

# Implementation

## 1. Make the installed package metadata authoritative

Modify `dot_config/powershell/modules/Copilot/Copilot.psm1` around the package helpers and installer:

- Add private helpers to parse the requested package selector and read the installed package’s `node_modules/<name>/package.json` with its actual `name` and `version`.
- Replace `Test-CopilotPkgPresent`’s directory/binlink-only check with a strong predicate:
  - installed package name matches the requested package;
  - an exact requested version such as `2.1.0` matches installed metadata;
  - a runnable launch path exists.
- Change `.installed-spec` to verified JSON containing `requestedSpec`, installed `name`, and installed `version`. `Test-CopilotPkgReady` must require the current selector, stamp metadata, live package metadata, and launch path to agree.
- Migrate a valid legacy one-line stamp without network: when the live package metadata already satisfies the current exact pin and is runnable, rewrite the verified JSON stamp and return ready. A stale `1.13.14` tree must not qualify for the `2.1.0` pin.
- Keep filesystem metadata as the authoritative install postcondition. Do not rely on `Start-Process.ExitCode`, which this module already documents as unreliable for the npm/Bun child shape. A failed attempt with a stale tree must return false, proceed to the existing no-proxy retry, and never write a new stamp.
- After a successful attempt, re-read metadata and write only the verified values. The existing `start` guard then correctly prevents launch when installation failed.
- Have `doctor` and `reinstall` report the actual installed version/mismatch rather than echoing the desired spec as proof.
- Correct the module header that still says the maintained fork runs via `bunx`; launch uses the installed prefix. Do not bump `Copilot.psd1`’s module version and do not change the throttle shim for HTTP 402.

## 2. Fix foreground authentication and propagate failure

In `copilot-proxy`’s `auth` branch:

- For the maintained fork, invoke `Invoke-CopilotPkgCommand auth login --provider copilot` in that exact order. Both upstream `1.13.14` and `2.1.0` use this command shape; no version compatibility branch is needed.
- Retain the existing bare `auth` path for the separately supported original unscoped package flavor.
- Keep `Invoke-CopilotPkgCommand` as a foreground native invocation so device-login prompts inherit the terminal. Capture `$LASTEXITCODE` immediately, surface a concise nonzero error, return failure without terminating the caller’s PowerShell session, and do not retry alternate argv.
- Never add `--show-token`, redirect auth output to proxy logs, or include token contents in diagnostics.

## 3. Probe the effective model and classify GitHub billing errors

Refactor the model section of `Invoke-CopilotDoctor` in the same module:

- Fetch one `/v1/models` catalog snapshot and derive both raw IDs and Claude Code aliases from it, so counts, pin validation, role validation, and live-probe selection use consistent data.
- Add a pure live-probe target helper:
  - remove the Claude Code-only `[1m]` suffix from the effective configured main model;
  - probe that raw model when served;
  - only if it is absent before the request, use `Select-CopilotBestModel` and label the target explicitly as a **catalog fallback**, including why the configured pin was not used.
- Send exactly one inference request. Do not replay a failed request on another model.
- Add a response-body parser that handles direct and nested gateway shapes (`code`/`message`, `error.code`/`error.message`, and JSON encoded inside `error.message`). Preserve a compact raw-body fallback for unknown shapes.
- Classify HTTP 402 plus `billing_not_configured` as nonretryable, account-wide GitHub Copilot configuration. Print the GitHub settings URL and state that changing the model, running `copilot-model --auto`, or toggling the shim does not repair it.
- Reserve model-switch hints for genuine unavailable/unsupported-model errors. Change catalog wording from “Claude available” to “Claude advertised/served aliases”; catalog presence is not proof of successful inference.
- Remove the claim that role-aware OpenAI fallback happens automatically at request time. Describe `copilot-model --auto` as an explicit pin-selection command only.

## 4. Rebuild the Codex modifier around raw bytes

Refactor `dot_codex/modify_config.toml.ps1.tmpl`:

- Read stdin through `Console.OpenStandardInput()` into a byte array and retain the original bytes until a successful merge exists.
- On a separate parsing copy, accept/remove exactly one UTF-8 BOM and decode with strict UTF-8. Decode failure emits a diagnostic to stderr and writes the original bytes unchanged.
- Treat only TOML-legal blank bytes (space, tab, LF, CRLF) as an empty config. A second BOM, NBSP, or other Unicode “whitespace” must not be silently overwritten.
- Remove the unprovisioned bare-Python path. Use `uv run --no-project --quiet --with tomlkit==0.13.3 --python '>=3.11' python`; if `uv`, the parser, or the merge fails, emit the original bytes unchanged and exit zero so chezmoi apply remains fail-closed.
- Parse the checked-in overlay separately from the live TOML. A broken managed overlay is an internal diagnostic, not “invalid live TOML,” and must not replace the target.
- For valid input, preserve all unrelated tables/keys and replace only `tui.status_line` using the existing `tomlkit` merge pattern.
- Define successful output canonically as UTF-8 without BOM, LF line endings, and exactly one final LF. Only successful merges normalize encoding/newlines; every failure path preserves stdin byte-for-byte.
- Keep temporary-file and environment cleanup in `finally`.

## 5. Strengthen regression tests

Extend `tests/Copilot.Tests.ps1` with isolated `XDG_DATA_HOME` fixtures and mocked process/catalog behavior:

- Package metadata: stale `1.13.14` plus a binlink is rejected for `2.1.0`; exact name/version is accepted; missing/corrupt metadata, mismatched or legacy stamps are handled; valid legacy state is migrated without network; failed installs cannot restamp or launch stale contents; success stamps verified metadata.
- Auth: maintained fork emits `auth, login, --provider, copilot`; original flavor keeps bare `auth`; nonzero child status is surfaced once; no fallback argv or `--show-token` is used.
- Doctor helpers: configured main wins over alphabetic Gemini/Haiku; `[1m]` is stripped; an absent pin produces a labeled catalog fallback; direct and nested `billing_not_configured` bodies receive the account-wide diagnosis and URL; ordinary 4xx/model errors do not.

Replace the string-pipe helper in `tests/CodexConfig.Tests.ps1` with `System.Diagnostics.Process` using redirected `StandardInput.BaseStream`/`StandardOutput.BaseStream`, while capturing stderr and exit code. Add byte-level cases for:

- zero-byte and TOML-legal whitespace input;
- BOM-only and BOM-prefixed valid TOML;
- double BOM and invalid Unicode whitespace;
- valid nested tables/providers;
- malformed LF/CRLF TOML and invalid UTF-8 preserved exactly;
- parser/overlay failure diagnostics;
- successful no-BOM/LF/single-final-LF output;
- byte-idempotent reapplication.

Tests must assert the expected stderr on fail-closed paths so a missing parser can no longer masquerade as a successful merge.

## 6. Make Windows CI exercise the production dependency and merge path

Update `.github/workflows/windows.yml`:

- Add `astral-sh/setup-uv@v6` before template rendering/apply/tests. Do not globally `pip install tomlkit`; the modifier’s pinned inline `uv --with` declaration remains the single dependency source.
- Before the isolated apply, seed the destination with a non-empty `.codex/config.toml` containing an unrelated setting and an old `tui.status_line`.
- After apply, parse/assert that the unrelated setting survived and the managed status line replaced the old one. This covers the path that failed in run `31573094501`; fresh empty input alone is insufficient.

## 7. Synchronize documentation and preserve the debugging record

Update the bilingual pairs together:

- `docs/copilot-proxy.md` / `docs/copilot-proxy.zh-TW.md`: canonical auth argv, verified installed metadata, exact `2.1.0` pin, `ETARGET`/configured-registry diagnosis, effective-model live probe, catalog-vs-inference distinction, nonretryable 402 action, and no automatic request-time fallback.
- Restore the corporate npm mirror paragraph removed from `docs/tools.md` / `docs/tools.zh-TW.md` while keeping the new Codex footer entry. Link the existing packagefeed/Bun pitfalls rather than duplicating their registry-probing guidance.
- `docs/codex-status-line.md` / `docs/codex-status-line.zh-TW.md`: `uv` parser requirement, one-BOM acceptance, exact fail-closed byte preservation, and successful output normalization.

Add two symptom-first records and index them alphabetically in `pitfalls/README.md`:

- Codex: verbatim `modify_config.toml: invalid TOML ... Empty key at line 1 col 0`, explaining the retained BOM, byte-safe workaround, and prevention tests.
- Copilot install: verbatim npm `ETARGET` followed by doctor claiming `@jeffreycao/copilot-api@2.1.0` installed, explaining the stale-tree/stamp false positive and metadata postcondition.

Keep historical `1.13.14` examples in existing pitfalls unchanged. The auth argv and GitHub billing message are adequately covered by code/tests/current docs and do not need separate pitfall files.

# Verification

Run in this order:

1. Targeted tests:
   - `pwsh -NoProfile -c "Invoke-Pester -Path ./tests/Copilot.Tests.ps1 -Output Detailed"`
   - `pwsh -NoProfile -c "Invoke-Pester -Path ./tests/CodexConfig.Tests.ps1 -Output Detailed"`
2. Full Pester suite.
3. PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1` unchanged.
4. Render and PowerShell-parse every `.ps1.tmpl` using the workflow’s existing loop.
5. Perform an isolated chezmoi apply against a pre-existing non-empty/BOM Codex config and inspect the rendered TOML.
6. Run `just docs-build` for strict bilingual nav/link validation.
7. Do not claim Windows runtime verification from macOS. The authoritative final gate is `windows-latest`; run/monitor it only after a separately approved commit/push.

# Critical files

- `dot_config/powershell/modules/Copilot/Copilot.psm1`
- `tests/Copilot.Tests.ps1`
- `dot_codex/modify_config.toml.ps1.tmpl`
- `tests/CodexConfig.Tests.ps1`
- `.github/workflows/windows.yml`
- `docs/copilot-proxy*.md`, `docs/codex-status-line*.md`, `docs/tools*.md`
- `pitfalls/README.md` and the two new symptom records
