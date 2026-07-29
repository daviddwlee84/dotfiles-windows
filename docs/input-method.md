# Input method (Rime / Weasel)

[Rime](https://rime.im/) on Windows ships as **Weasel（小狼毫）**. It is opt-in —
answer *yes* to `Install the Rime input method (Weasel) for Traditional Chinese`
at `chezmoi init`, or flip `installInputMethod` in
`%USERPROFILE%\.config\chezmoi\chezmoi.toml`.

The interesting part is not the install: it is that the **engine-level config is
shared byte-for-byte** with the cross-platform macOS/Linux repo, so 注音 and 拼音
behave identically on Weasel, Squirrel (macOS) and ibus-rime (Linux).

## What is shared and what is not

`.chezmoitemplates/rime/` holds the portable bodies. Each platform has a
one-line renderer, `{{ template "rime/<file>" . }}`.

| File | Scope | Why |
|---|---|---|
| `default.custom.yaml` | **shared** | `schema_list`, `menu/page_size` — engine-level, frontend-agnostic |
| `luna_pinyin.custom.yaml` | **shared** | a schema switch patch — engine-level |
| `weasel.custom.yaml` | Windows only | `style/` is Weasel's own, and `app_options` keys on the **EXE name** |
| `squirrel.custom.yaml` | macOS only | `app_options` keys on the **bundle id** |
| `user.yaml`, `installation.yaml`, `build/`, `*.userdb/` | **never managed** | runtime state |

Deploy targets:

| Platform | Frontend | User folder |
|---|---|---|
| Windows | Weasel 小狼毫 | `%APPDATA%\Rime` |
| macOS | Squirrel 鼠鬚管 | `~/Library/Rime` |
| Linux | ibus-rime | `~/.config/ibus/rime` |

Sharing works because **Weasel and Squirrel bundle the same schemas** — both are
built from plum's `:preset` package set (`bopomofo`, `cangjie`, `luna-pinyin`,
`terra-pinyin`, `stroke`, `quick`, `essay`, `prelude`). Every schema in our
`schema_list` is therefore already present on all three platforms; nothing is
downloaded at apply time.

!!! note "Editing the shared files"
    The two repos each keep a copy. Edit one, copy it to the other, then `diff`
    them — that diff **is** the drift check. Extracting them into a third repo
    pulled by `.chezmoiexternal` is tracked in `TODO.md`.

## Schemas

`Ctrl+`` ` opens the scheme menu:

| Schema | |
|---|---|
| `bopomofo_tw` | 注音·臺灣正體 (default) |
| `bopomofo` | 注音 |
| `luna_pinyin` | 朙月拼音 — patched to 臺灣字形 |
| `terra_pinyin` | 地球拼音（帶聲調） |
| `cangjie5` | 倉頡五代 |

To add or reorder, edit `.chezmoitemplates/rime/default.custom.yaml` in **both**
repos. A schema outside the bundled set needs plum
(tray icon → 輸入法設定 → 獲取更多方案).

## Windows-specific behaviour

`weasel.custom.yaml` sets:

- **Font fallback.** Weasel comma-splits `font_face` into a real DirectWrite
  fallback chain, so latin/digits render in `Hack Nerd Font Mono` (the repo-wide
  terminal font) and CJK falls back to `Microsoft JhengHei UI`.
- **`global_ascii: true`** — one shared 中/英 state across every app instead of
  per-window. **Squirrel cannot do this** (`rime/squirrel#201`, `#1054` both
  closed unmerged), so this is a genuine Windows-only win and is deliberately
  absent from the macOS config.
- **Per-app `ascii_mode`** for pwsh, Windows Terminal, Alacritty, WezTerm, herdr,
  nvim, VSCode and Cursor. These are applied *after* a new session inherits the
  global ASCII state, so terminals and editors stay in ASCII while everything
  else follows the shared 中/英 switch.

`Install-Weasel` also runs `WeaselSetup.exe /toggleascii`, which makes
`Ctrl+Space` toggle ASCII rather than switching the whole IME off — that is what
makes `global_ascii` feel like a single 中/英 key.

## Redeploying after a config change

Rime only picks up `*.custom.yaml` edits on a **重新部署**.
`chezmoi apply` handles this automatically: `run_onchange_after_50_rime_deploy.ps1`
re-fires whenever any managed Rime YAML changes and runs
`WeaselDeployer.exe /deploy`.

By hand:

```powershell
$dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Rime\Weasel' -Name InstallDir).InstallDir
& "$dir\WeaselDeployer.exe" /deploy
```

…or right-click the tray icon → 重新部署.

On the other platforms it stays manual (Squirrel's `--reload` is unreliable and
`ibus restart` interrupts the session):

```bash
# macOS
/Library/Input\ Methods/Squirrel.app/Contents/MacOS/Squirrel --reload
# Linux
touch ~/.config/ibus/rime/ && ibus restart
```

## `WeaselSetup.exe` command line

Undocumented upstream, but real (read off `WeaselSetup/WeaselSetup.cpp`). Every
flag below writes only `HKCU`, so **none of them need elevation**:

| Flag | Effect |
|---|---|
| `/t` / `/s` | (re)register the TSF service as Traditional / Simplified — **needs admin** |
| `/lt` `/ls` `/le` | Weasel's own UI language: 繁體 / 简体 / English |
| `/userdir:<dir>` | move the Rime user folder off `%APPDATA%\Rime` |
| `/du` / `/eu` | disable / enable the auto-update check |
| `/toggleascii` | `Ctrl+Space` toggles ASCII instead of the whole IME |
| `/toggleime` | the inverse of the above |

`WeaselDeployer.exe` takes `/deploy`, `/dict`, `/sync` and `/install`. It
compares its argument with a plain string compare, so exactly one argument may be
passed, and it holds an exclusive mutex — a second concurrent deploy exits 1.

## Gotchas

!!! warning "The install raises a UAC prompt"
    `Rime.Weasel`'s winget manifest is machine-scope NSIS, so `--scope user` can
    never work. Applying with `installInputMethod` on will prompt for elevation,
    the same as the WSL2 and OpenSSH-server toggles.

!!! warning "A plain silent install registers Simplified Chinese"
    winget's silent switch for NSIS is `/S`, and Weasel's `install.nsi` maps a
    bare `/S` to `WeaselSetup.exe /s` — 简体. `Install-Weasel` passes
    `--custom '/T'` to override that. If you ever install Weasel by hand, check
    Settings › Language afterwards and run `WeaselSetup.exe /t` if it says 简体.
    See `pitfalls/weasel-silent-install-registers-simplified-chinese.md`.

!!! note "The auto-update check is left off"
    A silent install writes `CheckForUpdates=0`. We do not manage this key;
    re-enable it with `WeaselSetup.exe /eu` if you want Weasel's own updater,
    otherwise `just upgrade-winget` covers it.

!!! note "Runtime files are deliberately unmanaged"
    Rime never rewrites `*.custom.yaml` — switch state and the last-used schema
    go to `user.yaml` (`var/option/…`, `var/previously_selected_schema`). That is
    why these are plain managed files and not a `modify_` overlay like herdr's
    config. `build/`, `installation.yaml`, `user.yaml` and `*.userdb/` are left
    alone entirely.
