# Fix `tri` (try-cli) SIGWINCH crash on Windows + upstream PR

## Context

`tri` (the Ruby `try-cli` gem, v1.9.3, installed here via the `installTry` toggle and
driven by `profile.d/32_try.ps1`) crashes the moment its interactive picker opens:

```
try.rb:80:in 'Signal.trap': unsupported signal 'SIGWINCH' (ArgumentError)
    @old_winch_handler = Signal.trap('WINCH') { @needs_redraw = true }
```

**Root cause:** Windows Ruby (mingw/mswin) has no `SIGWINCH`. `try.rb` traps it
*unconditionally* in `TrySelector#setup_terminal`, so `Signal.trap('WINCH')` raises
`ArgumentError` and aborts before the main loop. `WINCH` is the **only** signal trapped
(no TSTP/CONT/INT), and the restore site (`try.rb:91`) is already nil-guarded
(`... if @old_winch_handler`, with `@old_winch_handler = nil` set at line 37), so a single
guard on line 80 fully fixes the crash without breaking teardown.

**Upstream:** `github.com/tobi/try` (Tobi Lütke), default branch `main`, active, README
claims Windows is in-scope, but **CI is Linux-only** (Ubuntu, Ruby 3.3, `rake`). No open
issue/PR addresses this crash — it's unclaimed. (PR #70 "Windows support" was closed
unmerged and explicitly punted on the Ruby version; PR #65 touched WINCH but for Unix
resize.) The gem is built from the single root `try.rb`; the C-port repo `tobi/try-cli` is
a decoy — **not** the target.

**Outcome:** `tri` works on this box immediately and stays working across `gem update` /
fresh machines, and the real fix lands upstream so `installTry` eventually needs no patch.

## The fix (one line, content-based)

In `try.rb`, guard the trap so it only runs where the signal exists:

```ruby
# before
@old_winch_handler = Signal.trap('WINCH') { @needs_redraw = true }
# after
@old_winch_handler = Signal.trap('WINCH') { @needs_redraw = true } if Signal.list.key?('WINCH')
```

`Signal.list.key?('WINCH')` is the idiomatic "trap only if supported" guard (portable, not
Windows-special-cased). Line 91 (restore) needs **no** change. Match on the substring, not a
line number, so it's robust to upstream drift.

> Caveat (not in scope for the crash fix): once the crash is gone, the picker's key-loop
> uses `IO.select([STDIN])` (L296), `STDIN.read_nonblock` (L307–308) and `STDIN.iflush`
> (L806), which can misbehave on the Windows console. We **verify the picker live** after
> patching; if it's broken, that's a separate follow-up, kept out of this focused PR to
> maximize merge odds (the maintainer has no Windows CI to validate a bigger change).

## Work items

### 1. Immediate local unblock (I do this)
Apply the guard to the live installed gem so `tri` works now:
- `C:\Users\hanruzhou\scoop\persist\ruby\gems\gems\try-cli-1.9.3\try.rb` (line 80).
- Write back as UTF-8 **no-BOM**, preserving existing EOLs (a BOM would corrupt the Ruby
  file) — same discipline as the earlier claude-hud `statusline.mjs` write.
- Note: reverted by a future `gem update try-cli` → that's what item 2 covers.

### 2. Durable self-healing patch in the chezmoi installer (I do this)
Add an idempotent post-`gem install` step to
`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`, inside the existing
`{{ if .installTry -}}` block (after the `gem install try-cli` block, ~line 406):
- Resolve the installed `try.rb` via `ruby -e "...Gem::Specification.find_by_name('try-cli').gem_dir..."`
  (same lookup `32_try.ps1` already uses).
- If it contains the unguarded needle `Signal.trap('WINCH') { @needs_redraw = true }`
  **and** it is not already followed by `if Signal.list.key?`, append the guard; else no-op.
- Reuse the script's existing `Have` / `Info` / `Register-Failure` helpers; wrap in
  try/catch → never abort the apply (invariant #2). Write with `[System.IO.File]::WriteAllText`
  + UTF-8-no-BOM.
- Self-disables the day upstream ships a fixed release (needle gone). Known limit: a bare
  `gem update` that doesn't re-trigger this run_onchange won't re-patch — acceptable; the
  real fix is upstream and this covers fresh-machine + re-apply.

### 3. Upstream PR to `tobi/try` (I prepare; you run the `!` git/gh steps)
Per this repo's contribution model (identity `freyazh` ≠ owner → fork + PR; external
writes are handed off):
1. **You:** `!gh repo fork tobi/try --clone --fork-name try` into e.g. `C:\Code\tobi-try`
   (creates `freyazh/try` + local clone). Then `!git -C C:\Code\tobi-try checkout -b fix/windows-sigwinch-crash`.
2. **Me:** read `AGENTS.md` + `test/` conventions in the clone; apply the one-line guard to
   `try.rb`; add a focused Minitest under `test/` **only if** trivially expressible with the
   repo's existing harness (e.g. stub `Signal.list` to omit WINCH and assert `setup_terminal`
   doesn't raise) — otherwise skip it and explain in the PR why (Linux CI can't exercise the
   Windows path). Stage the PR body to a temp file.
3. **Me:** verify locally on this Windows box — `ruby C:\Code\tobi-try\try.rb` picker no
   longer crashes; run `rake test` / `bash spec/tests/runner.sh ./try.rb` if runnable.
4. **You:** `!git commit`, `!git push -u origin fix/windows-sigwinch-crash`,
   `!gh pr create --repo tobi/try --base main --head freyazh:fix/windows-sigwinch-crash --body-file <tmp>`.
   - Title: `Fix crash on Windows: guard POSIX-only SIGWINCH trap`
   - Body: verbatim crash, the one-line guard, why minimal, note Windows is claimed
     supported, note #70 punted on the Ruby version. Commit trailer:
     `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

### 4. Pitfall doc (I do this)
- New `pitfalls/try-cli-sigwinch-crash-windows.md`, symptom-first per
  `pitfalls/README.md` template. Symptom keywords (grep-able): `unsupported signal 'SIGWINCH'`,
  `Signal.trap`, `ArgumentError`, `try.rb:80`, `TrySelector#setup_terminal`, `tri`. Sections:
  Root cause (Windows Ruby lacks WINCH; unconditional trap), Workaround (the guard: upstream
  PR + installer stopgap), Prevention (guard signal traps with `Signal.list.key?`), Related
  (link `32_try.ps1`, the installer step, the sibling `try-cli-pwsh-support-emits-posix.md`,
  upstream repo/PR).
- Add its row to the `pitfalls/README.md` index (alphabetical, after `scoop-...`). While
  there, also add the **already-existing** `try-cli-pwsh-support-emits-posix.md` row (it's an
  unindexed file today) so the index is complete.
- Write both as CRLF (repo working tree is CRLF; `core.safecrlf=true` rejects lone-LF on
  `git add`) — normalize via `node -e` before staging, as done previously.

## Files touched
| File | Change |
|---|---|
| `scoop/.../try-cli-1.9.3/try.rb` (live gem, outside repo) | one-line WINCH guard — immediate unblock |
| `C:\Code\tobi-try\try.rb` (fork clone) | same guard — the PR |
| `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` | idempotent self-healing patch step |
| `pitfalls/try-cli-sigwinch-crash-windows.md` | new pitfall doc |
| `pitfalls/README.md` | index rows (new + the unindexed sibling) |

No new init prompt, tool, or docs page → no `.chezmoi.toml.tmpl` / `windows.yml` /
`docs/**` / mkdocs mirrors required (invariant cross-file rules don't trigger).

## Verification
1. **Crash gone (live):** `ruby "C:\Users\hanruzhou\scoop\persist\ruby\gems\gems\try-cli-1.9.3\try.rb"` opens the
   picker without the `ArgumentError`; then in a fresh pwsh, `tri` (bare) opens the picker and
   `tri scratch` creates+enters a dated dir. Note whether the picker's keys respond (the
   `IO.select` caveat) — report honestly; follow-up if broken.
2. **Installer patch is idempotent:** render the template
   (`chezmoi execute-template ... < run_onchange_after_10_packages.ps1.tmpl`) and parse the
   result with `[System.Management.Automation.Language.Parser]::ParseInput`; confirm the patch
   block no-ops when the guard string is already present.
3. **Lint/tests:** `Invoke-ScriptAnalyzer` on the changed `.tmpl` render (Errors only);
   `Invoke-Pester ./tests/Try.Tests.ps1` still green (translator untouched).
4. **PR fix (in clone):** `rake test` and/or `bash spec/tests/runner.sh ./try.rb` pass; the
   diff is the single guarded line (+ optional test).
5. **Pitfall:** `git add` succeeds (CRLF, no safecrlf rejection); README index still renders.
