# Plan — manage `~/.gitconfig`, fix the npm registry script, wire up the TODO helpers

## Context

Three unrelated gaps surfaced while cleaning up a GitHub PAT leak on 2026-07-29:

1. **`~/.gitconfig` is not managed at all.** No `dot_gitconfig*` exists in the
   source tree, so `core.autocrlf=input` (load-bearing — it prevents
   `scoop update` from wedging, see `pitfalls/scoop-local-changes-overwritten-by-merge.md`)
   and `pull.rebase=true` live only on this machine. `pitfalls/git-add-fatal-crlf-would-be-replaced-by-lf.md`
   already ends with *"a fresh clone on another box will hit the same `fatal:`"* —
   the gap has bitten once already. The parent repo solves this with
   `modify_dot_gitconfig.tmpl`; we want parity, including auto-filled
   `user.name` / `user.email`.
2. **`scripts/setup-internal-npm.ps1` (added in `5351411`) would break a
   working machine.** It hardcodes `O365Infra_NPM` — which returns `E401`
   today — and deletes the `registry=` line that currently works.
3. **The TODO helper scripts documented in `AGENTS.md` don't exist at the
   documented path.** They were vendored to
   `.agents/skills/project-knowledge-harness/scripts/`, but the skill's
   cwd-relative prose (`scripts/add-todo.sh`) was copied verbatim into
   `AGENTS.md` + `TODO.md`, where `scripts/` means the repo-root PowerShell dir.

Intended outcome: a fresh Windows box reproduces the git config automatically;
`just setup-internal-npm` can only help, never harm; and every documented
`scripts/*.sh` command actually runs.

## Key facts established (do not re-derive)

- `.chezmoi.toml.tmpl:14-15` **already** defines the `name` / `email` prompts,
  and `.github/workflows/windows.yml:57-58` already carries their CI flags.
  **No new init prompt** → no `InitPrompts.Tests.ps1` change, no `windows.yml`
  change, no docs prompt-table row. Invariant #1 is already satisfied.
- Stored data: `name='hanruzhou'`, `email='hanruzhou@microsoft.com'`,
  `managedMachine=true`. Live `~/.gitconfig` uses
  `hanruzhou+odspmdb@microsoft.com` — **decision: keep `+odspmdb`**, so the
  stored value must be synced first.
- Persisted config lives at `C:\Users\hanruzhou\.config\chezmoi\chezmoi.toml`
  (`[data]` block). `promptStringOnce` never re-asks, so this is a direct edit.
- CI renders **and parses** every `*.ps1.tmpl` (`windows.yml:104-116`), and
  `chezmoi apply --exclude scripts` (`:118-126`) excludes `.chezmoiscripts` but
  **not** `modify_` scripts — so `modify_dot_gitconfig` **will execute in CI
  against a fresh destination with EMPTY stdin.**
- `core.hooksPath` must **not** be emitted: no `dot_config/git/` and no
  `~/.config/git/hooks` wrapper exists here, and setting it makes git ignore
  `.git/hooks/`, silently disarming the `pre-commit` hook just installed.
- `run_once_before_01_backup.ps1.tmpl:10-25` does **not** back up `.gitconfig`.
- npm: `registry=https://packagefeedproxy.microsoft.io/npm/` is set at the
  **global** level in `Q:\.tools\.npm-global\etc\npmrc` (corp-provisioned);
  the `~/.npmrc` line is a redundant **duplicate**. All 3 npm CLIs are
  installed; `~/.local/share/copilot-api/pkg` is **empty** (copilot-api never
  installed). `registry.npmjs.org` direct is blocked (TLS handshake failure).
- `scripts/` and `tests/` are chezmoi-ignored (`.chezmoiignore:40-43`) —
  source-dir only, never deployed. So adding `scripts/*.sh` has no deploy impact.
- Invariant #6 forbids symlinks/junctions on Windows → wrappers, not symlinks.

---

## Workstream A — manage `~/.gitconfig`

### A0. Sync the stored email first (machine-local, not a repo change)

Edit `C:\Users\hanruzhou\.config\chezmoi\chezmoi.toml`:

```toml
email = "hanruzhou+odspmdb@microsoft.com"
```

Must happen **before** the first apply, otherwise the overlay rewrites
`user.email` to the plain address. Not a repo file — call it out in the commit
body so other machines know to do the same.

### A1. New `modify_dot_gitconfig.ps1.tmpl` (source root → `~/.gitconfig`)

Follow the `dot_config/herdr/modify_config.toml.ps1.tmpl` idiom:

- Read live target: `$liveText = [Console]::In.ReadToEnd()`
- Emit byte-exact stdout via `[Console]::OpenStandardOutput()` +
  `[System.Text.UTF8Encoding]::new($false)` (no BOM, stable LF) so
  `chezmoi diff` stays clean and the script is idempotent.
- **Merge model: key-level pull-through, not the parent's allowlist.** The
  parent preserves only `[credential "…"]` and destroys everything else; that
  would silently drop `[otel "trace2"]` and any future corp section. Instead:
  emit the baseline, then copy through **every live `section.key` not in the
  managed set**. This automatically preserves the five
  `[credential "azrepos:*"]` blocks, `[otel "trace2"]`, and anything IT adds
  later.
- **Pure PowerShell** INI parsing — no python/uv shell-out. gitconfig's
  INI-with-subsection grammar (`[filter "lfs"]`) is simple enough that the
  herdr tomlkit dependency isn't justified, and it removes a runtime that
  might be absent in CI.
- **Empty stdin** (fresh host / CI) → emit baseline only, no error.
  **Malformed live file** → warn on stderr, emit baseline (never crash the apply).

Managed keys (everything else pulled through):

| Section | Keys |
|---|---|
| `user` | `name` = `{{ .name }}`, `email` = `{{ .email }}` |
| `core` | `autocrlf = input` — **load-bearing**, absent from the parent baseline; comment why |
| `init` | `defaultBranch = main` |
| `pull` | `rebase = true` |
| `rebase` | `autoStash = true` |
| `filter "lfs"` | `clean` / `smudge` / `process` / `required` |
| `http` | `postBuffer = 524288000` |
| `include` | `path = ~/.gitconfig.local` (per-machine escape hatch) |

**Deliberately NOT emitted:** `core.hooksPath` — add an inline comment
explaining that it would disarm `.git/hooks/pre-commit` because this repo
ships no hooks wrapper. Also skip the parent's conditional `delta` blocks
unless `lookPath "delta"` is confirmed to work here (delta comes from scoop;
verify before including).

### A2. `.chezmoiscripts/run_once_before_01_backup.ps1.tmpl`

Add `$HOME/.gitconfig` to the fixed target list (`:10-25`). Without this,
first apply rewrites a file holding five corp credential blocks with no snapshot.

### A3. `bootstrap.ps1:120-127`

**Keep** the existing `core.autocrlf` write — bootstrap runs *before* chezmoi
is even installed, and scoop needs `input` set early. Add a one-line comment
noting the managed gitconfig now also asserts it, so the two don't look like
accidental duplication. Its guard ("only if unset or `true`") stays correct.

### A4. `tests/GitConfig.Tests.ps1`

The merge logic lives inside a `.tmpl`, so test it the way CI already exercises
templates: render with `chezmoi execute-template`, write to a temp `.ps1`, run
it with piped stdin, assert on stdout. Cases:

1. Empty stdin → baseline only; contains `autocrlf = input`; does **not**
   contain `hooksPath`.
2. Live file with `[credential "azrepos:org/x"]` → block preserved verbatim.
3. Live file with `[otel "trace2"]` → preserved.
4. Live `pull.rebase = false` → overridden back to `true` (managed key wins).
5. Idempotency: feeding the script's own output back produces identical bytes.
6. Malformed live input → still emits a valid baseline, exit 0.

---

## Workstream B — rewrite `scripts/setup-internal-npm.ps1` as verify/repair

### B0. Registry architecture (measured 2026-07-29, supersedes assumptions)

`packagefeedproxy.microsoft.io/npm/` is a **full pull-through npm registry**,
already configured at the global level in `Q:\.tools\.npm-global\etc\npmrc`:

| Probe | Result |
|---|---|
| `npm view undici version --registry .../npm/` | `8.8.0` ✓ |
| `npm view left-pad version --registry .../npm/` | `1.3.0` ✓ (arbitrary obscure pkg → **no allowlist**) |
| `npm view '@jeffreycao/copilot-api@1.13.14' version` | `1.13.14` ✓ |
| `npm view '@anthropic-ai/claude-code' version` | `2.1.217` ✓ |
| `npm ping --registry .../npm/` | **404** — ping endpoint not implemented |
| `npm view … --registry .../npm/registry/` | **404** — wrong base, one segment too deep |

Metadata rewrites `dist.tarball` to Microsoft's 1ES **public** mirror:
`https://ms-feed-25.pkgs.visualstudio.com/1es-public/_packaging/npm-public/npm/registry/<pkg>/-/<pkg>-<ver>.tgz`

**Two traps this creates** (a parallel investigation on another company laptop
hit both and concluded, incorrectly, that the host was "a tarball proxy for
specific packages, not a full registry"):

- `npm ping` returns 404 even when the registry is fully functional. Never use
  it as the health probe — use `npm view <pkg> version`.
- The internal Azure Artifacts feed can be **ahead** of the public mirror. That
  investigation requested `undici-8.9.0.tgz` (a version only the internal feed
  had) and read the resulting 404 as "tarball not provided", when the mirror's
  latest was 8.8.0.

**Consequence for the premise**: `@jeffreycao/copilot-api` resolves through a
mirror named `npm-public`, so it is a **public** package. The script's
"internal npm authentication" framing is likely wrong, and the empty
`~/.local/share/copilot-api/pkg` probably has an unrelated cause (never ran
`copilot-proxy start`, or a bun/npm failure). **Confirm this before writing any
repair logic** — run `copilot-proxy reinstall` on the current, unmodified
config first. If it succeeds, workstream B shrinks to "delete the script and
document the registry", and the credential-provider path is dead code.

### B1. Script behavior

Current shape is "always reconfigure". New shape is **verify → no-op if healthy
→ repair only if broken → re-verify → roll back on failure**.

1. **Verify first**, using `npm view <pkg> version` (never `npm ping`). Probe
   one public package and the copilot package. If both resolve, print OK and
   **write nothing**.
2. **Gate on `managedMachine`.** This repo is public; writing
   `packagefeedproxy.microsoft.io` on a box with no `Q:` drive would break npm
   outright. Recommend an in-script guard so a direct `pwsh -File` invocation
   is protected too, not just the `just` target.
3. **Prefer removing a bad user-level override to adding one.** The global
   npmrc already carries the right value; a user-level `registry=` line is
   drift, because user config beats global and a stale duplicate silently wins
   if IT repoints the feed.
4. **Back up `~/.npmrc`** before any edit; **restore it** if post-repair
   verification fails.
5. **Delete lines 43-50** (the `$env:npm_config_registry` write into
   `local.ps1`). An env var overrides `.npmrc`, so `npm config get registry`
   reports one thing while npm uses another — a debugging trap.
6. **Delete lines 52-58** (hand-copying the chezmoi-managed `Copilot.psm1`
   over the deployed one). Replace with an instruction to run `just apply`.
7. **Single source of truth for the package pin.** `@jeffreycao/copilot-api@1.13.14`
   is duplicated at `Copilot.psm1:53` and `setup-internal-npm.ps1:61`. Import
   the module and call `Get-CopilotPkg`, or read `$env:COPILOT_API_PKG`.
8. **Keep the Azure Artifacts credential-provider install** only if B0 shows
   it is actually needed; trigger it solely on an auth-class failure.
9. Drop `always-auth=true` (no-op on npm ≥ 9).

### B2. New pitfall doc

`pitfalls/packagefeedproxy-npm-404-wrong-base-path.md` — symptom-titled, since
this cost a full investigation on another machine and is not googleable
(searches for the hostname return nothing). Record: the verbatim 404s, that
`npm ping` is unimplemented, that `/npm/registry/` is one segment too deep,
that the internal feed can be ahead of the public mirror, and the correct
probe (`npm view <pkg> version --registry https://packagefeedproxy.microsoft.io/npm/`).

Docs (invariant — EN + zh-TW together): add a subsection to `docs/tools.md`
and `docs/tools.zh-TW.md`. `setup-internal-npm` currently appears in **zero**
docs pages. No new page → no `mkdocs.yml` nav change.

---

## Workstream C — TODO helper wrappers + durable note

### C1. Four wrappers at repo root `scripts/`

`add-todo.sh`, `todo-kanban.sh`, `promote-todo.sh`, `sweep-inbox.sh` — each a
thin bash wrapper that resolves its own directory, `exec`s the real script in
`.agents/skills/project-knowledge-harness/scripts/`, forwards `"$@"`, and
fails with a clear message if the skill dir is missing.

This makes **all 11 existing references correct without editing a single line
of sentinel-managed prose** — `AGENTS.md:79,90,91,96,99,114,115,119,135` and
`TODO.md:14,61` all start working as written. That is the main reason to
prefer wrappers over repointing paths: a `project-knowledge-harness` re-run
regenerates the sentinel block and would re-break any edits inside it.

The wrapped scripts resolve their own siblings via `$script_dir` first
(`add-todo.sh:112-127`, `sweep-inbox.sh:70-84`), so delegation is safe.

### C2. Durable note **outside** the sentinel block

Add a short note in `AGENTS.md` **above** `<!-- project-knowledge-harness:agent-guidance -->`
(line 77) recording that `scripts/*.sh` are wrappers and the real
implementations live in `.agents/skills/project-knowledge-harness/scripts/`.
Outside the sentinels it survives regeneration.

---

## Cross-file mirror obligations

- `docs/tools.md` **and** `docs/tools.zh-TW.md` — the npm/internal-feed subsection.
- `pitfalls/packagefeedproxy-npm-404-wrong-base-path.md` — new pitfall (B2) +
  a row in the `pitfalls/README.md` index table.
- `docs/setup.md` **and** `docs/setup.zh-TW.md` — a short "Git configuration"
  note explaining the managed `~/.gitconfig` and `~/.gitconfig.local`.
- **No** new init prompt → no `.chezmoi.toml.tmpl`, `windows.yml`, or
  skill "What's enabled" changes.
- **No** new docs page → no `mkdocs.yml` nav / nav_translations changes.
- `TODO.md`: promote the existing gitconfig entry (line 34) to `## Done` and
  mark `backlog/manage-gitconfig-via-chezmoi.md` `Status: shipped`, keeping it
  as historical record.

## Verification

```bash
# STEP 0 — do this FIRST; it may collapse workstream B to a deletion.
# Does copilot-api install against the CURRENT, unmodified config?
copilot-proxy reinstall
ls ~/.local/share/copilot-api/pkg/node_modules/.bin   # expect copilot-api present
# If this succeeds, the "internal npm authentication" premise is wrong.

# Lint + tests + docs
just lint
just test                       # includes the new tests/GitConfig.Tests.ps1
just docs-build                 # must stay green (--strict)

# Render + parse the new template exactly as CI does
chezmoi execute-template --source "$PWD" < modify_dot_gitconfig.ps1.tmpl > /tmp/r.ps1
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseInput((Get-Content -Raw /tmp/r.ps1),[ref]\$null,[ref]\$null)"

# Isolated apply (never touches the real setup) — AGENTS.md idiom
TMPD=$(mktemp -d); mkdir -p "$TMPD/home"
chezmoi init --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
  --destination="$TMPD/home" --no-tty <every prompt flag>
chezmoi apply --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
  --destination="$TMPD/home" --exclude=scripts
# assert $TMPD/home/.gitconfig has autocrlf=input and NO hooksPath

# Real machine, in order
chezmoi diff ~/.gitconfig       # inspect BEFORE applying
chezmoi apply
git config --get user.email     # expect hanruzhou+odspmdb@microsoft.com
git config --get core.autocrlf  # expect input
git config --get core.hooksPath # expect EMPTY
ls .git/hooks/pre-commit        # must still exist (proves hooks not disarmed)

# npm script, healthy path must be a no-op
cp ~/.npmrc /tmp/npmrc.before
just setup-internal-npm
diff /tmp/npmrc.before ~/.npmrc # expect NO differences

# Wrappers
scripts/todo-kanban.sh --validate-only TODO.md
```

`chezmoi apply` currently has **7 pending target changes** (5 herdr `.ps1`,
`Copilot.psm1`, `lazygit/config.yml`) — all are targets lagging behind source
from commits `39e311d`..`5351411`. Run `chezmoi diff` first and confirm none
carry local edits worth keeping.

## Risks

- **Highest: first apply rewrites a `~/.gitconfig` holding five corp
  credential blocks.** Mitigations: A2 adds it to the backup targets, the
  pull-through merge preserves unmanaged keys by construction, and A4 case 2
  tests exactly this. Still — inspect `chezmoi diff ~/.gitconfig` before the
  first apply.
- **`modify_` on Windows**: invariant #5 warns interpreter selection is
  unreliable, but that concerns *extensionless* scripts; the `.ps1.tmpl` form
  works via `[interpreters.ps1] = pwsh` (herdr precedent). CI will prove it.
- **Workstream B may collapse to a deletion.** If B0's `copilot-proxy reinstall`
  test succeeds against the current unmodified config, the script is solving a
  non-problem: `@jeffreycao/copilot-api` is a public package served by the
  already-configured public mirror. Do that test **before** writing repair
  logic, so effort isn't spent on dead code.
- **Unknown**: what provisions `Q:\.tools\.npm-global\etc\npmrc` on a fresh
  box, and whether it lands before first login. If IT imaging guarantees it,
  the npm repair path is dead code on corp machines regardless of B0.
