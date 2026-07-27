# Install `translate` (CLI/TUI translator) on the Windows dotfiles

## Context

`translate` (`github.com/daviddwlee84/translate`, local checkout at
`/Users/david/src/tries/2026-07-09-translate-cli-tui`) is already installed by the
companion unix repo (`/Users/david/.local/share/chezmoi`) two ways:

- **macOS** — `dot_config/homebrew/Brewfile.tmpl` → `brew "daviddwlee84/tap/translate"`
- **Linux** — `dot_ansible/roles/go_tools/{defaults,tasks}/main.yml` →
  `go install github.com/daviddwlee84/translate@v0.1.0` with `GOBIN=~/.local/bin`,
  `GOPATH=~/.local/share/go`
- plus `scripts/generate_completions.sh:129` → `regen translate "completion zsh" …`

Windows has neither brew nor ansible, so the tool is simply missing there. This
plan brings it to parity, Windows-native.

**Feasibility was verified, not assumed:**

- Cross-compiles clean for **windows/amd64 and windows/arm64** (`GOOS=windows go build`,
  27 MB / 26 MB) — pure Go, `modernc.org/sqlite` needs no cgo.
- Has real Windows branches already: `internal/tts/native.go` speaks via **PowerShell SAPI**,
  `internal/tts/player.go` plays via PowerShell MediaPlayer, `charmbracelet/x/windows` is a dep.
- `internal/xdgpath/paths.go` honours `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_STATE_HOME`,
  which this repo already sets **both** in-session (`profile.d/00_env.ps1:15-18`) and
  persisted to the User environment (`.chezmoiscripts/run_onchange_after_03_xdg_env.ps1`).
  → config lands at `~/.config/translate/config.toml`, exactly like unix.
- The module is public on the Go proxy; latest tag **v0.5.2** (2026-07-22).
- `translate completion powershell` works (cobra).
- Its default `copilot-proxy` provider is `http://localhost:4141/v1` — the same port
  this repo's `dot_config/powershell/modules/Copilot/Copilot.psm1:52` serves.

**Decisions taken with the user:** install now via `go install` **and** file a follow-up
for a proper scoop bucket; new `installTranslate` prompt defaults **on for `workstation`**;
integrate pwsh completion + a tv channel + a dedicated docs page (no Claude Code MCP
registration this round).

## Approach

`go install` at apply time, gated on a new toggle, mirroring the in-repo precedent of the
specstory build block (`run_onchange_after_10_packages.ps1.tmpl:340-375`) and the
self-contained-dependency habit of the `installTry` block (which `Scoop-Install @('ruby')`
itself rather than relying on `installExtraRuntimes`).

### 1. New init prompt — `.chezmoi.toml.tmpl`

Add after `installTry` (line 44):

```
installTranslate     = {{ promptBoolOnce . "installTranslate" "Install translate (terminal translator CLI and TUI, built from source with Go)" $full }}
```

No `=` in the prompt text (invariant #1 corollary).

### 2. CI flag — `.github/workflows/windows.yml`

**Same commit** (hard invariant #1). Add to the `$flags` array:

```
'--promptBool','Install translate (terminal translator CLI and TUI, built from source with Go)=true',
```

`true` — like `installSpecstoryBuild` — so the render+parse step covers the new block and
the apply step deploys the tv channel; `chezmoi apply --exclude scripts` means CI never
actually builds anything.

### 3. Installer block — `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`

Add `installTranslate` to the toggle comment header (lines 7-22), then a new gated block
next to the other opt-ins (after the `installTry` block, before the failure summary):

```powershell
{{ if .installTranslate -}}
# translate — terminal translator CLI+TUI (github.com/daviddwlee84/translate).
# No scoop/winget manifest and no prebuilt Windows release yet, so it is built from
# source with `go install` — the same path the parent repo uses on Linux
# (dot_ansible/roles/go_tools); macOS there uses the Homebrew tap. GOBIN/GOPATH match
# the unix convention: binary into ~/.local/bin (already on PATH via profile.d/00_env.ps1),
# module cache into ~/.local/share/go instead of recreating ~/go.
#
# Pure Go (modernc.org/sqlite, no cgo) and verified to cross-compile for windows/amd64
# and windows/arm64. The FIRST build is slow (several minutes: embedded swagger-ui +
# sqlite); later applies no-op via the version check. Bump $translateVersion to upgrade
# — changing it re-renders this script, which is what re-fires the run_onchange.
# go.mod requires go >= 1.26.4; GOTOOLCHAIN=auto (default) fetches it if scoop's go is older.
$translateVersion = 'v0.5.2'
Scoop-Install @('go')   # self-contained: installExtraRuntimes may be off
if (Have go) {
    $trBin  = Join-Path $HOME '.local\bin\translate.exe'
    $trHave = ''
    # `translate --version` prints "translate version v0.5.2 …"; a proxy build has no
    # VCS metadata, so token 3 is exactly the module version. An unparseable/absent
    # answer just falls through to a reinstall (cheap once the module cache is warm).
    if (Test-Path -LiteralPath $trBin) {
        try { $trHave = (((& $trBin --version 2>$null) -split '\s+')[2]) } catch { $trHave = '' }
    }
    if ($trHave -eq $translateVersion) {
        Info "translate $translateVersion already installed"
    } else {
        Info "go install translate@$translateVersion (first build takes several minutes)"
        $env:GOBIN  = Join-Path $HOME '.local\bin'
        $env:GOPATH = Join-Path $HOME '.local\share\go'
        go install "github.com/daviddwlee84/translate@$translateVersion" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $trBin)) {
            Register-Failure "go:translate@$translateVersion"
        }
    }
} else {
    Register-Failure 'translate (needs go; enable Extra runtimes or run: scoop install go)'
}
{{ end -}}
```

Fault-tolerance is inherited from the file's `Register-Failure` convention (invariant #2).
The `useChineseMirror` block at the top already sets `GOPROXY=https://goproxy.cn,direct`,
which also covers the toolchain fetch.

### 4. pwsh completion — `dot_config/powershell/profile.d/10_tools.ps1`

One line at the end, reusing the existing `Import-CachedInit` helper (which no-ops when the
exe is absent and re-caches when its timestamp changes):

```powershell
# translate — cobra completion for the terminal translator (opt-in installTranslate)
Import-CachedInit -Name 'translate' -Exe 'translate' -Generate { translate completion powershell }
```

This is the pwsh counterpart of the unix `scripts/generate_completions.sh` entry.

### 5. tv channel — `AppData/Roaming/television/cable/translate.toml` (new)

`translate history --tsv` emits 6 tab-separated columns:
`id · timestamp · pair · engine · source · translation`.

Follows invariant #4 (`pwsh -NoProfile -Command "…"` inside TOML literal `'''…'''`,
`{split:\t:N}` addressing). **Quoting hazard:** translations routinely contain `'`
(`it's`, `don't`), which would break a single-quoted pwsh action string. The source
command therefore appends two extra columns (6, 7) with `'` doubled, used by the actions;
columns 4/5 stay raw for display. Uses `[char]9`/`[char]39` rather than backticks or
inner double quotes — the same trick `channels.toml` uses with `[char]34`.

```toml
# translate — translation-history picker (`translate history --tsv`).
# Columns 0-5: id, timestamp, pair, engine, source, translation.
# Columns 6-7: source/translation with ' doubled, so the single-quoted pwsh action
# strings survive apostrophes ("don't"). [char]9 = TAB, [char]39 = '.

[metadata]
name = "translate"
description = "Translation history: fuzzy search, copy or speak the result"

[source]
command = '''pwsh -NoProfile -Command "$t=[char]9; $q=[char]39; translate history --tsv --limit 500 | ForEach-Object { $f=$_ -split $t; if ($f.Count -ge 6) { ($f + ($f[4] -replace $q,($q+$q)) + ($f[5] -replace $q,($q+$q))) -join $t } }"'''
display = '{split:\t:4}   →   {split:\t:5}'
output = '{split:\t:5}'

[preview]
command = '''pwsh -NoProfile -Command "'{split:\t:2}  [{split:\t:3}]  {split:\t:1}'; ''; '{split:\t:6}'; ''; '{split:\t:7}'"'''

[keybindings]
enter  = "actions:copy"
ctrl-y = "actions:copy-source"
ctrl-s = "actions:speak"

[actions.copy]
description = "Copy the translation to clipboard"
command = '''pwsh -NoProfile -Command "Set-Clipboard -Value '{split:\t:7}'"'''
mode = "fork"

[actions.copy-source]
description = "Copy the original text to clipboard"
command = '''pwsh -NoProfile -Command "Set-Clipboard -Value '{split:\t:6}'"'''
mode = "fork"

[actions.speak]
description = "Speak the translation (Windows SAPI, Google fallback)"
command = '''pwsh -NoProfile -Command "translate speak '{split:\t:7}'"'''
mode = "fork"
```

No registration needed — `channels.toml` globs `cable/*.toml` and picks up `[metadata]`.

*Deliberately not a dictionary type-ahead:* tv can't feed its prompt text into the source
command, so `translate dict search <prefix>` is not a fit; history is a static list tv can
fuzzy-filter natively.

### 6. Gate the channel — `.chezmoiignore`

Mirror the existing herdr gate so the channel doesn't appear in `tv` and return nothing
when the toggle is off:

```
{{ if not .installTranslate }}
AppData/Roaming/television/cable/translate.toml
{{ end }}
```

### 7. `Justfile`

Install and upgrade stay separate (the repo's stated rule). Add:

```
# upgrade the go-installed translate CLI to the latest release
upgrade-translate:
    $env:GOBIN = (Join-Path $HOME '.local\bin'); $env:GOPATH = (Join-Path $HOME '.local\share\go'); go install github.com/daviddwlee84/translate@latest
```

Left out of the `upgrade` aggregate on purpose — on a box without the toggle it would
*install* rather than upgrade.

### 8. Docs (cross-file mirrors, same commit)

- **New** `docs/translate.md` + `docs/translate.zh-TW.md` — what it is, install/toggle,
  `translate init` wizard (config is **not** chezmoi-managed, matching unix), the
  `~/.config` / `~/.local/share` / `~/.local/state` layout on Windows via the XDG vars,
  engines + the local copilot-proxy on :4141, `translate dict update all` (~67 MB, manual),
  the TUI keys, `translate serve` / `translate mcp`, the tv channel, upgrades.
- `mkdocs.yml` — `nav:` entry `- translate: translate.md` + `nav_translations: translate: translate`.
- `docs/tools.md` + `.zh-TW.md` — row in **Opt-in dev stacks**, row in **Television (tv)
  channels**, `just upgrade-translate` in **Upgrades**.
- `docs/setup.md` + `.zh-TW.md` — prompt-table row: `translate | on (workstation) | …`.
- `docs/index.md` + `.zh-TW.md` — one bullet under "What you get".
- `.chezmoitemplates/dotfiles-windows-skill.md` — append `· translate: {{ .installTranslate }}`
  to the "What's enabled" toggle line, and a one-line gotcha (built from source with
  `go install`, not scoop/winget).

### 9. Follow-up ticket — `TODO.md` + `backlog/`

`scripts/add-todo.sh` / `todo-kanban.sh` are unix-repo-only (not present here), so edit
`TODO.md` directly, matching the existing format:

```
- [ ] **[M] Ship prebuilt Windows binaries for `translate` and install via scoop** — … → [research](backlog/translate-windows-distribution.md)
```

under `## P2`, plus `backlog/translate-windows-distribution.md` recording the trade-off
(GoReleaser + release workflow in the `translate` repo — which today has **no** `.github/`
at all — plus a `scoop-bucket` repo; buys seconds-not-minutes installs, `scoop update *`
upgrades for free via the existing `just upgrade-scoop`, and drops the Go dependency).

## Verification

Off-Windows (this box), the repo's isolated-apply idiom — no real chezmoi state touched:

1. `Invoke-Pester -Path ./tests/InitPrompts.Tests.ps1` — proves the new prompt has its CI
   flag (invariant #1). Run this *first*; it's the failure mode that has broken CI before.
2. `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` — no Errors.
3. Isolated `chezmoi init --config=$TMPD/c.toml … --promptBool 'Install translate …=true'`
   (every prompt passed explicitly), then `chezmoi apply … --exclude=scripts`, and confirm
   `translate.toml` lands under `AppData/Roaming/television/cable/`; re-run with the toggle
   `false` and confirm it does **not**.
4. `chezmoi execute-template … < .chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl > r.ps1`
   for both toggle values, then parse `r.ps1` with
   `[System.Management.Automation.Language.Parser]::ParseInput` (what CI does).
5. Parse `translate.toml` with Python `tomllib` to confirm the `\t` escapes and literal
   strings survived authoring (invariant #3).
6. Dry-run the channel's source pipeline logic against the real
   `translate history --tsv` output (a local `translate` build exists at `/tmp/translate-native`)
   to confirm the 8-column reshape and apostrophe doubling.
7. `just docs-build` (mkdocs `--strict`) — catches a missing zh-TW twin or nav entry.

On a real Windows box (the actual gate for the install itself):

8. `chezmoi apply` → `translate --version` prints `v0.5.2`; `where.exe translate` →
   `~\.local\bin\translate.exe`; `translate config path` → `…\.config\translate\config.toml`.
9. New pwsh session: `translate <TAB>` completes subcommands (completion cache at
   `~/.cache/pwsh-init/translate.ps1`).
10. `tv translate` lists history; Enter copies, Ctrl+S speaks (SAPI).
11. Re-run `chezmoi apply` → the block prints "already installed" and does not rebuild.
12. `.github/workflows/windows.yml` green on push.
