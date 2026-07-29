# Verify the Rime/Weasel port on a real Windows box

**Status**: P2
**Effort**: S
**Related**: `TODO.md` · `docs/input-method.md` ·
`pitfalls/weasel-silent-install-registers-simplified-chinese.md` ·
`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (`Install-Weasel`) ·
`.chezmoiscripts/run_onchange_after_50_rime_deploy.ps1.tmpl`

## Context

2026-07-29, shipping the Rime/Weasel port. Everything was designed by reading
upstream C++/NSIS source and validated by isolated `chezmoi apply` + template
render/parse on a macOS dev box. Neither that nor `windows-latest` CI can exercise
the parts that matter most: TSF text-service registration, font rendering and IME
runtime behaviour. This is the list of what still needs a human at a real machine.

## Investigation

Already verified off-box, so **don't re-check these**:

- Toggle/CI-flag parity (`tests/InitPrompts.Tests.ps1`, 6/6 green).
- All three YAML files deploy to `AppData/Roaming/Rime` with the toggle on, parse
  as valid YAML, and are absent with the toggle off.
- Both `.ps1.tmpl` scripts render and parse in both toggle states.
- PSScriptAnalyzer 0 errors; full Pester 67/67; `just docs-build --strict` green.
- Unix repo: `chezmoi managed` lists `Library/Rime/*` with the toggle on and
  nothing with it off; `.config/ibus` never appears on darwin.

## Checklist for the real box

1. `chezmoi apply` with `installInputMethod` on → a **UAC prompt** appears (machine
   scope). Note whether an unattended/remote apply is workable or whether it needs
   an already-elevated session.
2. Settings › Time & Language › Language shows the IME under **中文（繁體，台灣）**,
   **not 中文（简体，中国）**. This is the one the `--custom '/T'` fix exists for —
   see the pitfall doc. If it's wrong, the `--custom` pass-through didn't take.
3. `Ctrl+`` ` lists all five schemas in order: 注音·臺灣正體, 注音, 朙月拼音,
   地球拼音, 倉頡五代.
4. 注音·臺灣正體 outputs 臺灣字形; 朙月拼音 also outputs 臺灣字形 (proves
   `luna_pinyin.custom.yaml`'s `switches/@2/reset: 3` applied).
5. The candidate bar uses the fallback chain — latin/labels in Hack Nerd Font Mono,
   CJK in Microsoft JhengHei UI, **no tofu**. If CJK renders in the wrong face,
   check whether comma-split fallback needs the `:first:last` codepoint-range form
   on this Weasel version.
6. `global_ascii`: switch to 中文 in Notepad, alt-tab to another normal app — the
   state should carry over. Then focus pwsh / VSCode — those should be ASCII
   regardless (per-app `ascii_mode` is applied after the global inherit).
7. `Ctrl+Space` toggles ASCII rather than turning the IME off entirely (that is
   what `WeaselSetup.exe /toggleascii` sets).
8. Edit `weasel.custom.yaml` in the source, `chezmoi apply` → the run_onchange
   fires and `WeaselDeployer.exe /deploy` picks the change up without a manual
   tray-menu redeploy.
9. Confirm `%APPDATA%\Rime\user.yaml`, `installation.yaml`, `build\` and
   `*.userdb\` are untouched by chezmoi after several applies (`chezmoi status`
   should stay quiet about them).

## Current blocker / open questions

No Windows box in this session. Items 5 and 6 are the two most likely to need a
tweak — the font fallback syntax and the exact `global_ascii` × `app_options`
interaction were both read from source rather than observed.

Also unverified: whether the TSF registration needs a sign-out/reboot before the
IME appears in the language bar. `install.nsi` starts `WeaselServer.exe` directly
and does not request a reboot, but TSF registration historically wanted a
re-login. Worth adding to `docs/input-method.md` if it turns out to be needed.

## Decision (if any)

`2026-07-29 shipped pending on-box verification` — the design is source-verified
and every off-box check is green, so it ships now rather than waiting.

## References

- `WeaselSetup/WeaselSetup.cpp`, `output/install.nsi`,
  `RimeWithWeasel/RimeWithWeasel.cpp`, `WeaselUI/DirectWriteResources.cpp` —
  all at <https://github.com/rime/weasel>
- Squirrel's missing `global_ascii`: rime/squirrel#201, rime/squirrel#1054
