# Pitfalls

Past traps we've stepped on. **Symptoms-first** knowledge base — when a
problem recurs (on a new machine, after an upgrade, with a new tool combo),
grepping the symptom here lands you on the root cause and workaround in
seconds, instead of re-debugging from scratch.

This folder is excluded from <DEPLOYMENT/PACKAGING MECHANISM, e.g. chezmoi via
.chezmoiignore.tmpl, Python via MANIFEST.in, npm via .npmignore> — it is repo
metadata for maintainers, not user-facing config to deploy.

## Pitfalls vs the rest

| Surface | Time direction | Question it answers | Access pattern |
|---|---|---|---|
| `docs/<tool>.md` | Present | "How does this tool work / how do I configure it?" | Read top to bottom |
| `pitfalls/<slug>.md` | **Past** | **"I see error X — has this happened before?"** | **Grep symptoms** |
| `backlog/<slug>.md` | Future | "We thought about doing Y — what was the analysis?" | Index in `TODO.md` |
| `AGENTS.md` Hard invariants | Present | "What rules MUST agents follow?" | Read top to bottom |

A pitfall **graduates** to a Hard invariant when the trap is serious enough
that you can't rely on memory or grep — typically when (a) it recurs across
machines, (b) it silently corrupts state, or (c) the workaround is non-obvious
and easy to undo by accident. When graduating, leave a `pitfalls/<slug>.md`
as historical record and link to it from the new invariant.

## When to add a pitfall doc

Add `pitfalls/<slug>.md` when you've spent more than ~15 minutes on something
that wasn't googleable, AND any of:

- The symptom is non-obvious from the root cause (silent state, weird side
  effect, behaviour change without error)
- The fix is "do nothing different but in a specific order"
- The same trap could be hit by a new agent / new machine / new contributor
- An upstream bug exists with no ETA — workaround needs to outlive memory
- A specific tool version is required (or forbidden) and failure at the
  wrong version is silent / confusing

## When NOT to add a pitfall doc

- Trivially googleable (next person solves in 30 seconds)
- Already covered in `docs/<tool>.md` — cross-link from this README's
  "Cross-referenced pitfalls" table below instead of duplicating
- Already a Hard invariant (cross-link only)
- One-off transient (network glitch, machine-specific config rot)

## File template

See [`pitfall-doc.md.template`] in the
[`project-knowledge-harness` skill](https://github.com/daviddwlee84/agent-skills/tree/main/skills/local/project-knowledge-harness)
for the per-doc template.

Key sections (different from `backlog/` template — symptom-first, not
context-first):

```markdown
# <Title describing the SYMPTOM, not the root cause>

**Symptoms** (grep this section): <verbatim error messages, observable behaviour>
**First seen**: YYYY-MM
**Affects**: <tool/version/OS combo>
**Status**: workaround documented / fixed upstream in vX.Y / WONTFIX

## Symptom

Full error messages (verbatim — preserves grep-ability).

## Root cause

Why this happens, with source/docs/upstream issue link.

## Workaround

Copy-pasteable commands or config diff.

## Prevention

How to avoid stepping on this again.

## Related

Links to docs, sibling pitfalls, TODO entries, upstream issues.
```

## Index

Pitfalls owned by this folder. Keep alphabetical.

| Slug | Symptom keywords | Status |
|---|---|---|
| [`clickfix-defender-flags-cmd-irm-iex`](clickfix-defender-flags-cmd-irm-iex.md) | `Trojan:Win32/ClickFix.R!ml`, cmd `powershell -c "irm\|iex"` blocked, VirusTotal clean but Defender blocks | workaround documented |
| [`codex-modify-config-empty-key-line-1-col-0`](codex-modify-config-empty-key-line-1-col-0.md) | `modify_config.toml: invalid TOML`, `Empty key at line 1 col 0`, valid/empty-looking `.codex/config.toml`, UTF-8 BOM at byte 0, status line not applied | fixed |
| [`copilot-api-connectionrefused-stale-bun-only-module`](copilot-api-connectionrefused-stale-bun-only-module.md) | `error: ConnectionRefused downloading package manifest @jeffreycao/copilot-api`, `Resolved, downloaded and extracted [6]`, copilot-proxy install fails both with and without proxy env, but plain `npm view` works, `chezmoi status` shows a modified `Copilot.psm1` | fixed |
| [`copilot-proxy-npm-etarget-but-doctor-says-installed`](copilot-proxy-npm-etarget-but-doctor-says-installed.md) | `npm error code ETARGET`, `No matching version found`, proxy still starts, doctor then says requested `@jeffreycao/copilot-api` version is installed, stale package tree/restamped pin | fixed |
| [`copilot-proxy-shim-port-held-by-another-process`](copilot-proxy-shim-port-held-by-another-process.md) | managed clients silently run against `:4141` while `copilot-proxy status` says `shim: ON but DOWN` — Responses `400 ... tool description ... empty` and the SSE keepalive both come back; or the inverse, `shim did not come up` with `EADDRINUSE` / `Is port 4142 in use?` only inside the detached log; plus `$env:COPILOT_SHIM_UPSTREAM` stuck in the session after one start | fixed (`Test-CopilotShimAlive` is reachability, not identity — this build has no `/_shim/health` and `-SkipHttpErrorCheck` accepts a 404. `Get-CopilotPortOwner` now classifies the port free/ours/foreign/unknown, `Start-CopilotShim` reclaims or refuses and tails the log inline, `Assert-CopilotShim` gates every managed client, and `COPILOT_SHIM_*` is restored in a `finally`) |
| [`git-add-fatal-crlf-would-be-replaced-by-lf`](git-add-fatal-crlf-would-be-replaced-by-lf.md) | `fatal: CRLF would be replaced by LF in .specstory/history/*.md`, `git add -A` stages nothing, `core.safecrlf` + `core.autocrlf=input`, `git ls-files --eol` shows `i/lf w/crlf` | workaround documented |
| [`herdr-keybind-failed-to-read-pane-protocol-mismatch`](herdr-keybind-failed-to-read-pane-protocol-mismatch.md) | `url-pick: failed to read pane <id>`, `protocol_mismatch`, `client protocol 17 is newer than server protocol 16`, keybind helpers silently no-op after `herdr update` | workaround documented |
| [`herdr-plus-action-does-not-support-platform-windows`](herdr-plus-action-does-not-support-platform-windows.md) | `custom command failed`, `cloudmanic.herdr-plus.quick-actions does not support the current platform (windows)`, plugin installed but prefix+y/prefix+O do nothing, clean `reload-config` | fixed |
| [`herdr-update-asr-access-denied`](herdr-update-asr-access-denied.md) | `herdr update` / `--handoff`, `Program 'herdr.exe' failed to run: Access is denied`, ASR `Use advanced protection against ransomware` (`C1DB55AB`), `Move-Item ... used by another process` | workaround documented |
| [`nvim-treesitter-no-c-compiler-despite-zig`](nvim-treesitter-no-c-compiler-despite-zig.md) | `No C compiler found`, `checkhealth nvim-treesitter`, `BrechtSanders.WinLabs.POSIX.UCRT`, zig installed but treesitter won't compile, `main` branch | fixed |
| [`onedrive-kfm-profile-not-loaded`](onedrive-kfm-profile-not-loaded.md) | `is not recognized as a name of a cmdlet`, `OneDrive - <tenant>\Documents\PowerShell`, bare prompt / no starship | fixed |
| [`packagefeedproxy-npm-404-wrong-base-path`](packagefeedproxy-npm-404-wrong-base-path.md) | `npm error 404` against `packagefeedproxy.microsoft.io`, `npm ping` 404s on a healthy registry, `/npm/registry/` vs `/npm/`, internal feed ahead of the public mirror, looks like "tarball proxy only" | not a bug — probing mistakes |
| [`pester-test-name-angle-brackets-command-not-found`](pester-test-name-angle-brackets-command-not-found.md) | `The term '$-' is not recognized`, `at <ScriptBlock>, <No file>:1`, `BeforeAll \ AfterAll failed`, whole Pester file fails, empty `ErrorRecord`, file parses clean | fixed |
| [`push-protection-blocks-pat-leaked-by-env-dump`](push-protection-blocks-pat-leaked-by-env-dump.md) | `GH013: Repository rule violations found`, `GITHUB PUSH PROTECTION`, `Push cannot contain secrets`, `GitHub Personal Access Token` in `.specstory/history/*.md`, push writes objects then rejects ref, `env \| grep -i git` matched `GITHUB_PERSONAL_ACCESS_TOKEN`, `.pre-commit-config.yaml` present but `pre-commit install` never run | workaround documented |
| [`scoop-local-changes-overwritten-by-merge`](scoop-local-changes-overwritten-by-merge.md) | `Your local changes to the following files would be overwritten by merge`, `bucket/*.json`, `Updating Buckets...`, scoop update/bootstrap stalls, CRLF | fixed |
| [`wsl-loginctl-enable-linger-no-systemd`](wsl-loginctl-enable-linger-no-systemd.md) | `loginctl enable-linger`, `System has not been booted with systemd as init system (PID 1)`, `Failed to connect to bus: Host is down`, WSL docker role, ansible exit status 2 | fixed |
| [`wsl-install-no-action-reboot-required`](wsl-install-no-action-reboot-required.md) | `No action was taken as a system reboot is required.`, `The requested operation requires elevation.`, Docker Desktop "WSL 2 is not installed" | workaround documented |
| [`wsl-ubuntu-oobe-and-wsl-l-encoding`](wsl-ubuntu-oobe-and-wsl-l-encoding.md) | `Enter new UNIX username`, `wsl -l` mojibake, `wsl.conf` default user ignored, `$'\r': command not found` | workaround documented |

## Cross-referenced pitfalls (still in their original homes)

These traps are documented elsewhere and aren't duplicated here — the table
exists so grepping `pitfalls/` still finds them. Move into this folder only
if their original location stops being a natural reading flow.

| Trap | Lives in | Why not here |
|---|---|---|
| (example: Tool X version Y bug) | `docs/tool-x.md` → "Known issues" | Already part of the tool's normal config narrative |
