# herdr-plus keybind fails: "<action> does not support the current platform (windows)"

**Symptoms** (grep this section): pressing a herdr `type = "plugin_action"` keybind shows a red toast `custom command failed`; `cloudmanic.herdr-plus.quick-actions does not support the current platform (windows)`; `cloudmanic.herdr-plus.projects does not support the current platform (windows)`; `does not support the current platform`; prefix+y / prefix+O do nothing useful even though `herdr plugin list` shows the plugin **installed and enabled**; `herdr server reload-config` reports NO diagnostics (the binding loads fine — it only fails when pressed).
**First seen**: 2026-07
**Affects**: herdr on Windows + `cloudmanic/herdr-plus` (seen at plugin 0.1.20, herdr 0.7.5-preview). Generic to any herdr plugin that declares platform-scoped actions.
**Status**: fixed — bind the `-windows` action ids.

## Symptom

`herdr plugin list` says the plugin is there:

```
1 plugin installed:
- cloudmanic.herdr-plus (Herdr Plus) enabled [github:cloudmanic/herdr-plus@a9aca9d...]
```

…yet pressing `prefix+y` shows:

```
custom command failed
cloudmanic.herdr-plus.quick-actions does not support the current platform (windows)
```

Note what makes this hard to spot: the config **parses cleanly** and `reload-config` reports nothing. The failure happens at *press* time, not load time — so nothing in the usual "is my config valid?" loop catches it.

## Root cause

herdr-plus does **not** ship one cross-platform action per feature. Its `herdr-plugin.toml` declares **separate actions with platform scopes**, and the Windows ones carry a `-windows` suffix:

```toml
[[actions]]
id = "quick-actions"
platforms = ["linux", "macos"]
command = ["./bin/herdr-plus", "quick-actions"]

[[actions]]
id = "quick-actions-windows"
platforms = ["windows"]
command = ["powershell", "-NoProfile", "-NonInteractive", "-Command", "& .\\bin\\herdr-plus.exe quick-actions"]
```

Same split for `projects` / `projects-windows`, `picker` / `picker-windows`, `quick-actions-picker` / `quick-actions-picker-windows`, `ping` / `ping-windows`.

herdr does **not** auto-resolve `quick-actions` to `quick-actions-windows`. Binding the bare id on Windows therefore resolves to an action whose `platforms` list excludes `windows`, and herdr rejects it at invocation.

This repo's herdr config was ported from the macOS/Linux parent repo, which correctly binds the unsuffixed ids — the ids came across verbatim and were wrong on this platform.

## Workaround

Bind the `-windows` ids in `.chezmoitemplates/herdr/config.toml`:

```diff
 [[keys.command]]
 key = "prefix+O"
 type = "plugin_action"
-command = "cloudmanic.herdr-plus.projects"
+command = "cloudmanic.herdr-plus.projects-windows"

 [[keys.command]]
 key = "prefix+y"
 type = "plugin_action"
-command = "cloudmanic.herdr-plus.quick-actions"
+command = "cloudmanic.herdr-plus.quick-actions-windows"
```

Then `chezmoi apply` and reload (`prefix+shift+R` or `herdr server reload-config`).

To see the authoritative action ids for any installed plugin:

```powershell
# the manifest lives next to the fetched plugin source
Get-Content "$HOME\.config\herdr\plugins\github\<id>-<hash>\herdr-plugin.toml" |
    Select-String -Pattern '^\s*(id|platforms)\s*='
```

`herdr plugin install` also prints every action id in its preview **before** you confirm — read that list rather than assuming the ids match the docs/parent repo.

## Prevention

- When porting a herdr plugin binding from a POSIX config, **check the plugin's `herdr-plugin.toml` for `platforms`** before trusting an action id. Cross-platform-looking ids are frequently unix-only.
- Remember the failure is **press-time, not load-time**: a clean `herdr server reload-config` proves nothing about `plugin_action` bindings. Actually press the key to verify.
- Installing the plugin on Windows needs **go** (its Windows build command is `go build -o bin/herdr-plus.exe .`); without a Go toolchain the install fails at the build step. Use `herdr plugin install -y <owner>/<repo>` for non-interactive installs.

## Related

- [`herdr-keybind-failed-to-read-pane-protocol-mismatch`](herdr-keybind-failed-to-read-pane-protocol-mismatch.md) — sibling herdr keybind trap (CLI/server protocol drift).
- `.chezmoitemplates/herdr/config.toml` — the `[[keys.command]]` blocks for prefix+O / prefix+y.
- `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/` — the Quick Action definitions this repo deploys (they are config only; the plugin itself is a separate `herdr plugin install`).
- `dot_config/herdr/pane-copy.ps1` — backs the copy-pane Quick Actions, which use `$HERDR_PLUS_PANE_ID`.
