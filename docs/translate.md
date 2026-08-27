# translate

[`translate`](https://github.com/daviddwlee84/translate) is a terminal translator —
one-shot from the shell, or an interactive TUI — backed by a fallback chain over your
local LLM providers, a free web API, and an offline bilingual dictionary.

It is the same tool the cross-platform
[dotfiles](https://github.com/daviddwlee84/dotfiles) install on macOS (Homebrew tap) and
Linux (`go install`). This repo installs it from a Scoop bucket.

Enable it with the **translate** init prompt (on by default for the `workstation`
role).

## How it gets installed

From the author's own Scoop bucket — a prebuilt binary, so installing takes
seconds and needs no Go toolchain:

```powershell
scoop bucket add daviddwlee84 https://github.com/daviddwlee84/scoop-bucket
scoop install daviddwlee84/translate
```

`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` does both for you when
the **translate** toggle is on.

- The upstream repo's release workflow cross-compiles **windows/amd64** and
  **windows/arm64** on every tag (it's pure Go — `modernc.org/sqlite`, no cgo)
  and GoReleaser pushes the manifest to the bucket.
- The binary lands on `PATH` as a normal scoop shim (`~\scoop\shims\translate.exe`).
- There is **no version pin to bump** in this repo any more.

!!! warning "Migrating off the old go-install build"
    Until 2026-08 this repo built translate from source with `go install` into
    `~\.local\bin`, which comes **before** `~\scoop\shims` on `PATH`. A leftover
    `~\.local\bin\translate.exe` therefore shadows the scoop one forever:
    `scoop update translate` reports success while `translate --version` keeps
    printing the old build. The packages script removes the stale copy
    automatically — but only once the scoop shim exists, so a failed install never
    leaves you with no `translate` at all. Check with:

    ```powershell
    Get-Command translate -All | Select-Object -ExpandProperty Source
    ```

!!! tip "Upgrading"
    Install and upgrade are separate here, like everything else in this repo:

    ```powershell
    just upgrade-translate      # scoop update translate
    ```

    `just upgrade-scoop` also covers it once installed.

## Quick start

```powershell
translate init                        # guided setup; probes which providers are up
translate "hola mundo" --to en        # one-shot
echo bonjour | translate --to en      # pipe
translate                             # interactive TUI
translate define ephemeral            # dictionary lookup
translate history                     # recent translations
```

## Where its files live

`translate` honours the XDG base-dir variables, and this repo sets them both in-session
(`profile.d/00_env.ps1`) and in the **User** environment
(`.chezmoiscripts/run_onchange_after_03_xdg_env.ps1`) — so the Windows layout matches
macOS/Linux exactly:

| What | Path |
|---|---|
| Config | `%USERPROFILE%\.config\translate\config.toml` |
| History | `%USERPROFILE%\.local\share\translate\history.jsonl` |
| Dictionary data | `%USERPROFILE%\.local\share\translate\dict\` |
| Last-pair state | `%USERPROFILE%\.local\state\translate\state.json` |
| TUI debug log | `%USERPROFILE%\.local\state\translate\debug.log` |

The config is **not** chezmoi-managed (same choice as the parent repo): the tool
rewrites it itself, and `translate init` is the supported way to change it. Run
`translate config path` to confirm where it resolved.

## Engines

`--engine auto` walks `chain.order` and fails over **before the first token**:

| Engine | Endpoint | Notes |
|---|---|---|
| copilot-proxy | `http://localhost:4141/v1` | the local proxy this repo already ships — see [copilot-proxy](copilot-proxy.md). Start it (`copilot-proxy start`) and translate picks it up with no API key. |
| Ollama | `http://localhost:11434/v1` | offline; install via the **Local LLM tools** init prompt |
| Google | — | free, keyless; also reports the detected source language |

`smartauto` (what `translate init` recommends) routes by input shape: a single word goes
to the dictionary, a phrase to the LLM.

!!! warning "Copilot ToS"
    Backing non-GitHub tools with a Copilot subscription may violate Copilot's Terms of
    Service. Reorder `chain.order` (drop `copilot`, lead with `ollama`/`google`) if that
    matters to you.

## Offline dictionary

The dictionary tiers (CC-CEDICT for zh→en, ECDICT for en→zh) need a **one-time ~67 MB
download**, deliberately *not* done at apply time:

```powershell
translate dict update all      # download + build into ~\.local\share\translate\dict
translate dict reindex         # rebuild the SQLite index from an existing download
```

Until then English lookups fall back to dictionaryapi.dev and Chinese lookups prompt you
to run the update.

## TUI keys

| Key | Action |
|---|---|
| `Enter` | translate |
| `Tab` | move focus between the input and result boxes |
| `Ctrl+Y` | copy the result |
| `Ctrl+L` | toggle live (debounced auto-translate) |
| `Ctrl+E` | cycle engine |
| `Ctrl+T` | target language |
| `Ctrl+P` | model |
| `Ctrl+O` | prompt style |
| `Ctrl+G` | toggle pair (bidirectional) mode |
| `Ctrl+R` | history |
| `Ctrl+U` | clear |
| `Alt+Enter` | newline |
| `Ctrl+C` / `Esc` | quit |

## Shell integration

- **Tab completion** — `profile.d/10_tools.ps1` caches `translate completion powershell`
  under `~\.cache\pwsh-init\translate.ps1` (the same `Import-CachedInit` treatment as
  starship/zoxide/tv). It re-generates automatically after an upgrade.
- **`tv translate`** — a Television channel over your translation history:

    | Key | Action |
    |---|---|
    | `Enter` | copy the translation |
    | `Ctrl+Y` | copy the original text |
    | `Ctrl+S` | speak the translation (Windows SAPI, Google fallback) |

    Only deployed when the toggle is on (see `.chezmoiignore`).

## Other front-ends

Both work on Windows and are available without extra setup:

```powershell
translate serve       # loopback HTTP API on 127.0.0.1:4155, Swagger UI at /docs
translate mcp         # MCP server over stdio (translate / define / history tools)
```

To register the MCP server with an agent, point it at `translate` with the single
argument `mcp`. This repo does **not** wire it into `~/.claude/settings.json` for you.

## Notes

- `translate speak` uses the **Windows SAPI** voices offline, falling back to Google.
  The same backend powers `Ctrl+S` in the tv channel.
- `--debug` logs the routing decisions; the one-shot CLI writes them to stderr, the TUI
  to `~\.local\state\translate\debug.log` (its alt-screen hides stderr).
- Full flag/config reference lives in the tool's own
  [README](https://github.com/daviddwlee84/translate).
