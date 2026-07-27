# Agent completion sounds (`agentSounds`)

How a coding agent tells you it finished on Windows: a toast, a game-character
voice line, both, or nothing. Chosen at `chezmoi init` with the `agentSounds`
prompt.

This is the Windows counterpart of the cross-platform repo's
[`docs/tools/agent-sounds.md`](https://github.com/daviddwlee84/dotfiles/blob/main/docs/tools/agent-sounds.md),
which carries the full ecosystem write-up (OpenPeon vs peon-ping vs CESP). Read
that for the "what is this" part; this page covers what differs here.

## The four tiers

| `agentSounds` | Wires | You get |
|---|---|---|
| `none` | nothing | silence |
| `notify` | `notify.ps1` → apprise → `windows://` toast | Windows toast |
| `peon` | peon-ping's 9 hook events | game voice lines + peon's overlay |
| `both` | both of the above | toast + voice (two banners) |

Default is `notify` on the `workstation` role and `none` on `minimal`. It gates
**hook wiring only** — the `peon` CLI installs alongside the coding agents
regardless, so `peon preview task.complete` / `peon packs list` are always
available to experiment with.

Default pack is `league_of_legends` (League of Legends champion voice lines).
The installer downloads it and then activates it (`peon packs use
league_of_legends`) so sounds fire on first run — the raw installer otherwise
leaves the empty `peon` pack active.

Two banners at `both` is expected. Trim it at runtime instead of changing tier:
`peon notifications off` keeps the sound and drops peon's overlay.

## What differs from the macOS/Linux repo

The design is the same; three implementation details are not.

**1. The event set differs.** peon-ping's Windows adapter registers
`PreToolUse` and does **not** register `UserPromptSubmit` — the reverse of the
POSIX side. Both are 9 events. Taken from upstream's `install.ps1`, not its
README (the README's documented command shape is wrong on the POSIX side, so it
isn't trusted here either).

**2. The hook command shape.** Windows entries carry `timeout = 10` and no
`async` field:

```
powershell -NoProfile -NonInteractive -Command "if (Test-Path '<peon.ps1>') { & '<peon.ps1>' }"
```

The `Test-Path` guard is deliberate — an unguarded `-File <missing>` makes
Claude Code surface a hook error on every event on a box where the install
hasn't run. Same role as the `command -v workmux` guard in the parent repo.

**3. peon-ping lives under `~/.openpeon`, not `~/.claude`.** It is installed
with `-OpenPeon`, which reroots its whole tree to a tool-agnostic root so the
installer never touches `~/.claude/settings.json` — hook wiring is ours to
declare. `peon.ps1` is therefore at
`~/.openpeon/hooks/peon-ping/peon.ps1`.

Note the installer's parameter block is
`param([string[]]$Packs, [switch]$All, [string]$Lang, [switch]$Local, [switch]$Global, [switch]$OpenPeon, [switch]$InitLocalConfig)`
— there is **no `-NoRc`** (that is the bash `install.sh` flag), and it does not
touch `$PROFILE`.

## Where the wiring lives

| Concern | File |
|---|---|
| The prompt | `.chezmoi.toml.tmpl` |
| Hook entries + prune | `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl` |
| Binary install | `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` |
| Non-hook overlay (statusLine, plugins) | `claude/settings-overlay.json` |

The hook entries had to move **out** of `claude/settings-overlay.json` and into
the run_onchange: that JSON is `include`d verbatim, so it cannot carry the
Go-template conditionals the tiers need.

## The one place we subtract

The merge is additive so foreign hook entries (CodeIsland, anything you add by
hand) survive. One exception: entries matching **our own** command fingerprints
(`notify\.ps1`, `peon\.ps1`) are pruned when the current tier disables them.

Without it `agentSounds` is a one-way ratchet — switching `notify` → `none`
would leave `notify.ps1` wired forever, so `none` wouldn't actually silence a
machine that previously had sound. Upstream's own `install.ps1` strips the same
two fingerprints before re-adding, so this matches its behaviour.

## peon's config is deliberately unmanaged

`peon volume` / `notifications` / `packs use` write `~/.openpeon/config.json` at
runtime. chezmoi does not manage that file, so tweaking any of it produces
**no** drift. The installer seeds and activates `league_of_legends` once and is skipped on later applies
(guarded on `peon.ps1` existing), so a pack you switch to later sticks.

## Verify

```powershell
peon status
peon preview task.complete       # should say "Job's finished!"
Get-Content ~/.claude/settings.json | ConvertFrom-Json | Select-Object -Expand hooks | Get-Member -MemberType NoteProperty
peon volume 0.4; chezmoi diff    # must be empty
```

**None of those four lines proves a sound will actually fire.** That exact
combination once passed on a fully silent macOS machine in the parent repo
(→ [`peon-hooks-wired-but-no-sound`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/peon-hooks-wired-but-no-sound.md)).
`peon status` only inspects `~/.openpeon`; `preview` bypasses the hook entirely;
and the settings keys can all be present while the hook target is missing,
because the `Test-Path` guard turns a missing `peon.ps1` into a *successful*
no-op that Claude Code reports as `completed successfully`.

That matters more here than on macOS: if the `install.ps1 -OpenPeon` step in
`run_onchange_after_10_packages.ps1.tmpl` fails it calls `Register-Failure` and
the apply carries on — leaving hooks wired against a player that was never
installed. Check the artifact, then fire the hook the way Claude Code does:

```powershell
Test-Path "$HOME\.openpeon\hooks\peon-ping\peon.ps1"   # must be True
'{"hook_event_name":"Stop","session_id":"probe","cwd":"."}' |
  & "$HOME\.openpeon\hooks\peon-ping\peon.ps1"
Get-Content "$HOME\.openpeon\.state.json" | ConvertFrom-Json |
  Select-Object -Expand last_played                    # -> task.complete = sounds/JobsFinished.mp3
```

`last_played` is the only machine-checkable proof that audio dispatched; exit
code 0 is not.

Two upstream behaviours worth knowing before blaming this repo, both confirmed
on macOS with peon 2.35.1:

- **The overlay is suppressed while your terminal is focused** — the sound
  plays, the banner doesn't. Switch to another window before the turn ends.
- **`peon notifications test` is a no-op** — it runs `PEON_TEST=1`, which
  disables the installer-layout fallback in peon's script resolver, so it
  reports success without notifying. Test with a real unfocused turn instead.

## Verification status

The template rendering, PowerShell parse, and the merge/prune behaviour were
verified on macOS by rendering all four tiers and executing them under `pwsh`
(cross-platform) against fixtures — foreign entries survive, our entries prune,
and the tier matrix is exact.

**Not yet verified on a real Windows host**: the peon-ping install itself
(`install.ps1 -OpenPeon -Packs league_of_legends`), the toast/voice actually firing, and
`$env:TEMP` behaviour. Those need a Windows box.
