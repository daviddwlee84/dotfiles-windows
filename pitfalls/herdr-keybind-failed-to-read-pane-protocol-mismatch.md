# herdr keybind helpers fail with "failed to read pane <id>" after a herdr update

**Symptoms** (grep this section): a herdr `[[keys.command]]` helper flashes an error and the pane closes; `url-pick: failed to read pane w3:pR`; `path-pick: failed to read pane <id>`; `pane-copy: failed to read process info for <id>`; `new-tab-at-space-root: could not resolve workspace for pane <id>`; prefix+m / review-mark appears to do nothing (or claims success while the ⭐ flag never appears); running any `herdr pane list` / `herdr pane current` / `herdr pane read` by hand returns `{"id":"cli:pane:list","error":{"code":"protocol_mismatch","message":"client protocol 17 is newer than server protocol 16; restart the Herdr server before using this command. Stop the old server to use the new version.\nStopping exits pane processes."}}`; `protocol_mismatch`; `client protocol 17 is newer than server protocol 16`.
**First seen**: 2026-07
**Affects**: herdr on Windows (seen upgrading to `0.7.5-preview.2026-07-21`), any time the CLI is updated while a herdr server keeps running. Not Windows-specific in principle — the version handshake is cross-platform — but it bites here because Windows is preview-only, so updates are frequent.
**Status**: workaround documented (restart the server); helpers now name the real cause.

## Symptom

After `herdr update --handoff` succeeded, every keybind that touches a pane failed. `prefix+u` showed:

```
url-pick: failed to read pane w3:pR
```

Note the pane id **is** correct (`w3:pR`) — this is NOT the unexpanded-`$VAR` bug (that one printed the literal `$HERDR_ACTIVE_PANE_ID`; see the Related section). `prefix+m` failed too fast to read.

Running the same call by hand reveals what the helpers were hiding:

```console
$ herdr pane list
{"id":"cli:pane:list","error":{"code":"protocol_mismatch","message":"client protocol 17 is newer than server protocol 16; restart the Herdr server before using this command. Stop the old server to use the new version.\nStopping exits pane processes.\nRun `HERDR_SOCKET_PATH=C:\\Users\\<you>\\.config\\herdr\\herdr.sock herdr server stop`, then restart Herdr with the same socket override."}}
```

## Root cause

The herdr CLI and the herdr **server** negotiate a numbered protocol. `herdr update` replaces the CLI binary immediately, but the **already-running server keeps the old protocol** until it restarts — exactly what the updater means by its closing line *"Restart any running Herdr sessions to use \<version\>"*. Until then the new CLI (protocol 17) refuses to talk to the old server (protocol 16) and returns a `protocol_mismatch` JSON error for every pane command.

The keybind helpers made this much harder to diagnose than it should have been:

- `Invoke-HerdrJson` / `Get-HerdrPaneText` ran herdr with `2>$null` and returned `$null` on **any** failure, so a protocol error was indistinguishable from "pane has no text".
- Callers then printed their own generic message (`failed to read pane <id>`), which reads like a *pane addressing* problem and sends you chasing pane ids.
- `review-mark.ps1` piped to `| Out-Null` and printed `review flag set on <pane>` unconditionally — reporting success on a call that had actually errored.
- A command pane closes the instant the script exits, so whatever was printed vanished before it could be read.

## Workaround

**Restart the herdr server.** ⚠️ This exits pane processes — save work in your panes first.

Simplest: quit herdr entirely and relaunch it. Or stop the server explicitly (use the socket path herdr names in the error — this repo sets `HERDR_CONFIG_PATH`/socket under `~/.config/herdr/`):

```powershell
$env:HERDR_SOCKET_PATH = "$HOME\.config\herdr\herdr.sock"
herdr server stop
# then start herdr again
```

Verify CLI and server agree again:

```powershell
herdr pane list      # expect JSON with a "result", NOT "protocol_mismatch"
herdr --version
```

## Prevention

- After **any** `herdr update`, restart herdr before trusting keybinds. The updater says so, but the failure surfaces much later and in an unrelated-looking form.
- `dot_config/herdr/_common.ps1` now detects this explicitly: `Test-HerdrProtocolMismatch` / `Assert-HerdrServerFresh` scan herdr's output (both streams) for `protocol_mismatch`, print *"herdr server is STALE — quit herdr and relaunch"*, and hold the pane ~5s so it is readable. `Invoke-HerdrJson` and `Get-HerdrPaneText` route through it.
- `review-mark.ps1` no longer swallows output with `| Out-Null`; it checks the exit code and the JSON `"error"` key and only claims success when the call actually succeeded.
- General rule for these helpers: **never** `2>$null` + generic message. A pane that closes on exit needs the real error printed and held.

## Related

- [`herdr-update-asr-access-denied`](herdr-update-asr-access-denied.md) — the Defender ASR trap that blocks `herdr update` in the first place; fixing that leads directly into this one.
- `backlog/herdr-windows-port-verification.md` item #3 — the *other* pane-id failure (herdr does not expand `$VAR` inside a `[[keys.command]]` string on Windows, so helpers received the literal `$HERDR_ACTIVE_PANE_ID`). Same generic symptom text, completely different cause: check whether the id in the message is a real pane id (`w3:pR`) or the literal.
- `dot_config/herdr/_common.ps1` — `Test-HerdrProtocolMismatch`, `Assert-HerdrServerFresh`, `Resolve-HerdrPane`.
