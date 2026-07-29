# Rime (Weasel) on Windows + shared cross-platform Rime config

## Context

The companion Unix repo (`/Users/david/.local/share/chezmoi`) installs Rime on
macOS (Squirrel) and Linux (ibus-rime) via the `installInputMethod` ansible role
— but manages **zero** Rime config. `docs/input_methods/README.md:254-263` there
records an explicit, still-open intent to eventually version-control
`*.custom.yaml`, ranked by priority. This Windows repo has no IME handling at all.

Two goals, one change:

1. Install and configure **Weasel (小狼毫)** — Rime for Windows — on this repo's
   terms (opt-in toggle, fault-tolerant installer, chezmoi-managed config).
2. Establish the **shared Rime config** layer the Unix repo deferred, so 注音 /
   拼音 behave identically on Windows, macOS and Linux.

This is the first place Rime config becomes version-controlled in either repo.

### Why sharing actually works (source-verified)

Weasel's bundled schema set is built from plum `:preset`
(`rime/weasel@master:build.bat:295` → `plum/preset-packages.conf`):
`bopomofo, cangjie, essay, luna-pinyin, prelude, quick, stroke, terra-pinyin`.
That is the **same set** macOS Squirrel ships — the built schemas already on the
Mac (`~/Library/Rime/build/`) match exactly. So a single `default.custom.yaml`
resolves identically on all three platforms with no downloads.

The split:

| File | Portable? | Why |
|---|---|---|
| `default.custom.yaml` | ✅ shared | `schema_list`, `menu/page_size` — engine-level |
| `luna_pinyin.custom.yaml` | ✅ shared | schema switch patch — engine-level |
| `weasel.custom.yaml` | ❌ Windows | `style/`, `app_options/` keyed by **.exe name** |
| `squirrel.custom.yaml` | ❌ macOS | `app_options/` keyed by **bundle id** |
| `user.yaml`, `installation.yaml`, `build/`, `*.userdb/` | ❌ never manage | runtime state |

**Rime never rewrites `*.custom.yaml`.** Verified in
`librime@master:src/rime/switcher.cc:165-172` — switch state and the
last-selected schema persist to `user.yaml` under `var/option/…` and
`var/previously_selected_schema`. Confirmed on this Mac: `~/Library/Rime/user.yaml`
holds `zh_hant: true`, `previously_selected_schema: bopomofo`. So plain managed
files are correct here — **no `modify_` overlay** (unlike herdr, which does
rewrite its own config).

---

## Design decisions (source-verified)

**winget package** `Rime.Weasel` — `InstallerType: nullsoft`, `Scope: machine`.
Machine scope means a **UAC prompt**; same class as the existing `installWsl` /
`installSshServer` toggles. The repo's `Winget-Install` already retries without
`--scope user`, but we need a bespoke installer anyway (below).

**Silent install registers Simplified Chinese.** `rime/weasel@master:output/install.nsi:300-330`:
`/S` sets `$R2="/s"` → `WeaselSetup.exe /s` → `install(hant=false, …)`. Passing
`/T` as well flips it: `${GetOptions} "/T"` overwrites `$R2="/t"` →
`install(hant=true, …)`. So `--custom '/T'` is mandatory for 繁體.
Silent mode also skips the 安裝選項 dialog and auto-runs `WeaselDeployer.exe /deploy`.

**`WeaselSetup.exe` has an undocumented CLI** (`WeaselSetup/WeaselSetup.cpp:157-241`),
all HKCU writes needing **no admin**:
`/lt` (UI 繁體) · `/toggleascii` (Ctrl+Space toggles ASCII, not the whole IME) ·
`/userdir:<dir>` · `/du` (disable auto-update) · `/eu` (enable).
`WeaselDeployer.exe /deploy` is the CLI redeploy.

**`global_ascii` + per-app `ascii_mode` compose correctly.** In
`RimeWithWeasel/RimeWithWeasel.cpp`, `AddSession` inherits the global ASCII state
at :174-182, then `_ReadClientInfo` applies `app_options` at :434-440. Later wins
→ terminals/editors stay pinned to ASCII while everything else shares one 中/英
state. `global_ascii` is a **Windows-only win** — the Unix docs record it as
unavailable on Squirrel (`rime/squirrel#201`, `#1054`).

**Font fallback is real**: `WeaselUI/DirectWriteResources.cpp:103` splits
`font_face` on `,`. So a latin-first, CJK-fallback chain works in one key.

**Auto-update check**: not managed (per your selection). Note the silent install
writes `CheckForUpdates=0` on its own (`install.nsi:343-346`); re-enable manually
with `WeaselSetup.exe /eu` if wanted.

---

## Part A — Windows repo (`/Users/david/src/tries/2026-07-09-windows-dotfiles`)

### A1. Toggle — `.chezmoi.toml.tmpl`

Add after `installTranslate`, before `useChineseMirror`. Name matches the Unix
repo's key exactly for cross-repo parity.

```gotmpl
    # Rime input method (Weasel / 小狼毫). winget's manifest is machine-scope
    # NSIS -> UAC prompt, and its silent path registers SIMPLIFIED Chinese
    # unless the installer gets /T (see the Install-Weasel comment).
    installInputMethod   = {{ promptBoolOnce . "installInputMethod" "Install the Rime input method (Weasel) for Traditional Chinese (needs admin)" false }}
```

No `=` in the prompt text (invariant #1).

### A2. Shared config bodies — `.chezmoitemplates/rime/`

Same idiom as `.chezmoitemplates/herdr/config.toml` and the shared skill body
(invariant #6). These two files are the **cross-repo shared source**.

`.chezmoitemplates/rime/default.custom.yaml`:

```yaml
# Rime — shared, PLATFORM-PORTABLE config. Identical bytes on Weasel (Windows),
# Squirrel (macOS) and ibus-rime (Linux). Do NOT put frontend style or
# app_options here — those go in weasel.custom.yaml / squirrel.custom.yaml.
# Mirror of dotfiles/.chezmoitemplates/rime/default.custom.yaml.
patch:
  schema_list:
    - schema: bopomofo_tw    # 注音·臺灣正體 (primary)
    - schema: bopomofo       # 注音
    - schema: luna_pinyin    # 朙月拼音
    - schema: terra_pinyin   # 地球拼音 (帶聲調)
    - schema: cangjie5       # 倉頡五代
  menu/page_size: 9
```

`.chezmoitemplates/rime/luna_pinyin.custom.yaml`:

```yaml
# 朙月拼音 -> 臺灣字形. switches/@2 is the
# [zh_hant, zh_hans, zh_hant_hk, zh_hant_tw] option group in
# rime-luna-pinyin/luna_pinyin.schema.yaml:27-37; reset: 3 selects 臺灣字形 —
# the same patch rime-bopomofo applies to itself in bopomofo_tw.schema.yaml:8.
patch:
  switches/@2/reset: 3
```

No per-schema file is needed for `bopomofo_tw` (already 臺灣字形), `bopomofo` /
`cangjie5` (traditional by construction) or `terra_pinyin` (`simplification`
defaults off).

> Your note said "注音 + 拼音" while selecting the option that also includes 倉頡.
> I kept `cangjie5` **last** in `schema_list` and added plain `luna_pinyin`
> alongside `terra_pinyin` (帶聲調 pinyin alone is awkward for daily typing).
> Dropping 倉頡 is a one-line delete.

### A3. Deployed config — `AppData/Roaming/Rime/`

Target is `%APPDATA%\Rime`, Weasel's default user dir
(`WeaselSetup.cpp:103-107`). Source-tree layout matches `AppData/Roaming/alacritty/`
and `AppData/Roaming/television/` — no `dot_` prefix.

- `default.custom.yaml.tmpl` → one line: `{{ template "rime/default.custom.yaml" . }}`
- `luna_pinyin.custom.yaml.tmpl` → `{{ template "rime/luna_pinyin.custom.yaml" . }}`
- `weasel.custom.yaml` → plain file, **Windows-only**:

```yaml
patch:
  # Latin/label glyphs from the repo's Nerd Font, CJK from 微軟正黑體.
  # DirectWriteResources.cpp:103 comma-splits this into a fallback chain.
  style/font_face: "Hack Nerd Font Mono, Microsoft JhengHei UI"
  style/label_font_face: "Hack Nerd Font Mono"
  style/comment_font_face: "Hack Nerd Font Mono, Microsoft JhengHei UI"
  style/font_point: 14
  style/color_scheme: dark_temple      # stock scheme; see weasel.yaml:66+
  style/inline_preedit: true
  style/display_tray_icon: true

  # One shared 中/英 state across apps (Squirrel can't do this — squirrel#201).
  global_ascii: true

  # ...except these, pinned to ASCII on focus. app_options is applied AFTER the
  # global_ascii inherit (RimeWithWeasel.cpp:174 then :434), so it wins.
  # Windows keys on the EXE name, unlike Squirrel's bundle ids.
  app_options:
    pwsh.exe: { ascii_mode: true }
    powershell.exe: { ascii_mode: true }
    WindowsTerminal.exe: { ascii_mode: true }
    alacritty.exe: { ascii_mode: true }
    wezterm-gui.exe: { ascii_mode: true }
    herdr.exe: { ascii_mode: true }
    nvim.exe: { ascii_mode: true }
    Code.exe: { ascii_mode: true }
    Cursor.exe: { ascii_mode: true }
```

`Hack Nerd Font Mono` is already the repo-wide terminal font (alacritty, wezterm,
Windows Terminal, VSCode); `installWindowsApps` installs it via scoop.

### A4. Gate — `.chezmoiignore`

Append at the bottom, in toggle order, with the house-style comment:

```gotmpl
# Rime user config is only deployed with the opt-in installInputMethod toggle.
# Weasel reads %APPDATA%\Rime; the sibling runtime files it writes there
# (user.yaml, installation.yaml, build/, *.userdb/) are deliberately unmanaged.
{{ if not .installInputMethod }}
AppData/Roaming/Rime/**
{{ end }}
```

### A5. Installer — `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`

Add `#   installInputMethod   = {{ .installInputMethod }}` to the header toggle
list (this is what re-fires the run_onchange).

New `function Install-Weasel` beside `Install-Herdr` (~line 156) — the bespoke-installer
precedent. All failures go through `Register-Failure`; never aborts the apply
(invariant #2):

```powershell
# --- Rime / Weasel (小狼毫) -------------------------------------------------
# winget's Rime.Weasel is machine-scope NSIS -> UAC prompt. Its silent path runs
# `WeaselSetup.exe /s` = SIMPLIFIED Chinese; --custom '/T' makes install.nsi pass
# /t instead (output/install.nsi:300-306). Silent also skips the 安裝選項 dialog
# and auto-runs WeaselDeployer.exe /deploy.
function Install-Weasel {
    $key = 'HKLM:\SOFTWARE\Rime\Weasel'
    $dir = (Get-ItemProperty -Path $key -Name InstallDir -EA SilentlyContinue).InstallDir
    if (-not $dir) {
        if (-not (Have winget)) { Register-Failure 'winget:Rime.Weasel (winget unavailable)'; return }
        Info 'winget install Rime.Weasel (machine scope - expect a UAC prompt)'
        winget install --id Rime.Weasel -e --silent --custom '/T' `
            --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
        $dir = (Get-ItemProperty -Path $key -Name InstallDir -EA SilentlyContinue).InstallDir
        if (-not $dir) { Register-Failure 'winget:Rime.Weasel'; return }
    }
    # HKCU-only tweaks, no admin (WeaselSetup.cpp:196-220).
    $setup = Join-Path $dir 'WeaselSetup.exe'
    if (Test-Path -LiteralPath $setup) {
        & $setup /lt           # Weasel UI in 繁體中文
        & $setup /toggleascii  # Ctrl+Space toggles ASCII, not the whole IME
    } else { Register-Failure 'weasel (WeaselSetup.exe not found; language/hotkey unset)' }
}
```

Gated call block, placed after the `installTranslate` block and before the
`$script:Failures` summary:

```gotmpl
{{ if .installInputMethod -}}
Install-Weasel
{{ end -}}
```

### A6. Redeploy — new `.chezmoiscripts/run_onchange_after_50_rime_deploy.ps1.tmpl`

Config edits only take effect after 重新部署. Keyed on the YAML content hashes so
it re-fires exactly when the config changes, and ordered after the files land:

```gotmpl
{{ if .installInputMethod -}}
# Re-runs when any managed Rime YAML changes:
#   default:     {{ include ".chezmoitemplates/rime/default.custom.yaml" | sha256sum }}
#   luna_pinyin: {{ include ".chezmoitemplates/rime/luna_pinyin.custom.yaml" | sha256sum }}
#   weasel:      {{ include "AppData/Roaming/Rime/weasel.custom.yaml" | sha256sum }}
$ErrorActionPreference = 'Continue'
...
# WeaselDeployer.exe /deploy == the tray menu's 重新部署 (WeaselDeployer.cpp:88-91).
{{ end -}}
```

Resolve `InstallDir` from `HKLM:\SOFTWARE\Rime\Weasel`; warn-and-exit-0 if absent
(Weasel not installed yet, or first apply pre-reboot). Exit 0 unconditionally.

### A7. Backup — `.chezmoiscripts/run_once_before_01_backup.ps1.tmpl`

Add to `$targets` (a real box very likely already has hand-edited Rime YAML):

```powershell
    (Join-Path $env:APPDATA 'Rime/default.custom.yaml'),
    (Join-Path $env:APPDATA 'Rime/weasel.custom.yaml'),
    (Join-Path $env:APPDATA 'Rime/luna_pinyin.custom.yaml'),
```

### A8. CI — `.github/workflows/windows.yml` (invariant #1)

Add to `$flags`, in the same position as the prompt:

```powershell
  # true so the Rime config tree + the Install-Weasel block get render-checked
  # (apply --exclude scripts means nothing actually installs).
  '--promptBool','Install the Rime input method (Weasel) for Traditional Chinese (needs admin)=true',
```

`tests/InitPrompts.Tests.ps1` needs no edit — it derives parity from both files.

### A9. Docs + bookkeeping (cross-file mirrors, same commit)

- **New page** `docs/input-method.md` + `docs/input-method.zh-TW.md`; add to
  `mkdocs.yml` `nav` and `nav_translations` (`Input method: 輸入法`).
  Content: the portable-vs-platform table above, `WeaselSetup.exe` /
  `WeaselDeployer.exe` flag reference, the 繁/簡 gotcha, how to add a schema
  (edit one shared file), redeploy commands for all three platforms, and the
  `/userdir:<dir>` escape hatch.
- `docs/tools.md` + `.zh-TW.md` — row in the **Opt-in dev stacks** table.
- `docs/setup.md` + `.zh-TW.md` — prompt-table row: `| Rime 輸入法 (Weasel) | off | … |`.
- `.chezmoitemplates/dotfiles-windows-skill.md` — append
  `· Rime/Weasel: {{ .installInputMethod }}` to the second "What's enabled" line,
  plus a `## Gotchas` bullet (UAC + 繁/簡 + redeploy).
- `pitfalls/weasel-silent-install-registers-simplified-chinese.md` — symptom-titled,
  with the verbatim `install.nsi` lines, the `--custom '/T'` fix, and the full
  undocumented `WeaselSetup.exe` flag list (I had to read C++ source for all of it).
- `TODO.md` via `.agents/skills/project-knowledge-harness/scripts/add-todo.sh`:
  - `[P3/M]` extract `.chezmoitemplates/rime/` into a standalone repo pulled by
    `.chezmoiexternal` in both repos → `--backlog` (`backlog/rime-shared-config.md`)
  - `[P3/S]` automate Squirrel/ibus redeploy on the Unix side
  - `[P2/S]` on-box verification checklist (see below) → `--backlog`

---

## Part B — Unix repo (`/Users/david/.local/share/chezmoi`)

`installInputMethod` already exists there (`.chezmoi.toml.tmpl:132-138`, default
false, desktop profiles only) — **no new prompt**, so no Dockerfile/CI flag churn.

### B1. Shared bodies — `.chezmoitemplates/rime/`

Byte-identical copies of A2's two files. `.chezmoitemplates/` already exists there
(`agents`, `editor`, `herdr`) and is rendered the same way
(`dot_config/herdr/modify_config.toml.tmpl`).

### B2. Parallel platform trees

Exactly the shape the repo already uses for editor overlays
(`.chezmoiignore.tmpl:169-186`): one source tree per OS, ignored on the other.

- **macOS** → `~/Library/Rime`:
  - `private_Library/Rime/default.custom.yaml.tmpl`
  - `private_Library/Rime/luna_pinyin.custom.yaml.tmpl`
  - `private_Library/Rime/squirrel.custom.yaml` — macOS-only `app_options`
    keyed by **bundle id**, mirroring A3's exe list. This is the exact patch the
    repo's own docs already give as the canonical example
    (`docs/input_methods/README.md:66-78`). **No `global_ascii`** — unsupported
    on Squirrel; the docs' existing analysis stands.
  - Note: `Rime`, not `private_Rime` — `~/Library/Rime` is `drwxr-xr-x` on this Mac.
- **Linux** → `~/.config/ibus/rime`:
  - `dot_config/ibus/rime/default.custom.yaml.tmpl`
  - `dot_config/ibus/rime/luna_pinyin.custom.yaml.tmpl`
  - No `ibus_rime.custom.yaml` — nothing to set.

### B3. Gate — `.chezmoiignore.tmpl`

New section next to the `installNiri` / `installBrewApps` gates, using the same
`hasKey` guard so hosts whose `chezmoi.toml` predates the key don't error:

```gotmpl
# Rime user config — only manage with installInputMethod=true, and only the tree
# matching this OS. Shared bodies live in .chezmoitemplates/rime/ and are
# byte-identical to dotfiles-windows/.chezmoitemplates/rime/.
{{- $installInputMethod := false }}{{ if hasKey . "installInputMethod" }}{{ $installInputMethod = .installInputMethod }}{{ end }}
{{- if or (ne .chezmoi.os "darwin") (not $installInputMethod) }}
Library/Rime
Library/Rime/**
{{- end }}
{{- if or (ne .chezmoi.os "linux") (not $installInputMethod) }}
.config/ibus/rime
.config/ibus/rime/**
{{- end }}
```

(The pre-existing blanket non-darwin `Library` ignore stays; this adds the
toggle condition, which that block does not cover.)

### B4. Docs

`docs/input_methods/README.md` + `.zh-TW.md`: the "這一輪先不把輸入法資料正式納管進
repo" deferral at :254-263 is now **stale**. Replace with what is managed, the
portable/platform split, the pointer to `.chezmoitemplates/rime/`, the sync
obligation with the Windows repo, and the redeploy commands
(`/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel --reload`;
`touch ~/.config/ibus/rime/ && ibus restart`). Keep the "never manage
`build/` / `user.yaml` / `*.userdb/`" policy — now enforced structurally.

Redeploy stays **manual/documented** on Unix (Squirrel's `--reload` is flaky and
`ibus restart` disrupts the session) versus scripted on Windows. Deliberate
asymmetry; recorded as the `[P3/S]` TODO.

---

## Verification

Cannot execute `.ps1` here (macOS dev box) — validate by render + parse, per AGENTS.md.

**1. Prompt/CI parity (fails fastest):**
```bash
pwsh -NoProfile -c "Invoke-Pester -Path ./tests/InitPrompts.Tests.ps1 -Output Detailed"
```

**2. Isolated apply, toggle ON — proves the YAML lands:**
```bash
TMPD=$(mktemp -d); mkdir -p "$TMPD/home"
chezmoi init --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
  --destination="$TMPD/home" --no-tty \
  --promptBool 'Install the Rime input method (Weasel) for Traditional Chinese (needs admin)=true' \
  ... # EVERY other prompt, exact text
chezmoi apply --source="$PWD" --config="$TMPD/c.toml" --persistent-state="$TMPD/s.db" \
  --destination="$TMPD/home" --exclude=scripts
python3 -c "import yaml,sys; [print(f,yaml.safe_load(open(f))) for f in sys.argv[1:]]" \
  "$TMPD"/home/AppData/Roaming/Rime/*.yaml
```
Assert: 3 files present; `default.custom.yaml` parses with 5 schemas;
`weasel.custom.yaml` has `global_ascii: true` and 9 `app_options` entries.

**3. Toggle OFF — proves the gate:** re-init with `=false`;
`$TMPD/home/AppData/Roaming/Rime` must not exist.

**4. Render + parse both new/edited `.ps1.tmpl`** (mirrors the CI step):
```bash
chezmoi execute-template --config="$TMPD/c.toml" --source="$PWD" \
  < .chezmoiscripts/run_onchange_after_50_rime_deploy.ps1.tmpl > /tmp/r.ps1
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseInput((Get-Content -Raw /tmp/r.ps1),[ref]\$null,[ref]\$e); \$e"
```
Same for `run_onchange_after_10_packages.ps1.tmpl` (both toggle states) and
`run_once_before_01_backup.ps1.tmpl`.

**5. Lint + full suite + docs:**
```bash
pwsh -NoProfile -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
pwsh -NoProfile -c "Invoke-Pester -Path ./tests"
just docs-build
scripts/todo-kanban.sh --validate-only TODO.md
```

**6. Unix repo — isolated apply on darwin:**
```bash
cd /Users/david/.local/share/chezmoi
# init into a temp dest with installInputMethod=true, apply --exclude scripts,
# assert ~3 files under $TMPD/home/Library/Rime and NONE under .config/ibus/rime
```
Then `diff .chezmoitemplates/rime/*` against the Windows repo's copies — must be
byte-identical.

**7. Real Windows box** (CI can't cover; goes in the `[P2/S]` backlog doc):
`chezmoi apply` → UAC → check 設定 › 語言 shows **中文（繁體，台灣）** not 简体 →
`Ctrl+`` ` lists all 5 schemas → 注音·臺灣正體 outputs 臺灣字形 → candidate bar uses
the fallback font chain → typing in pwsh/VSCode stays ASCII while Notepad follows
the shared 中/英 state → `WeaselDeployer.exe /deploy` after an edit picks it up.

**8. macOS end-to-end:** `chezmoi apply` → Squirrel redeploy → `Ctrl+``  shows the
same 5 schemas → confirm `~/Library/Rime/user.yaml` still updates freely (proves
we didn't clobber runtime state).
