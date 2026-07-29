# Extract the shared Rime config into its own repo

**Status**: P3
**Effort**: M
**Related**: `TODO.md` · `.chezmoitemplates/rime/` · `docs/input-method.md` ·
`AppData/Roaming/Rime/` · parent repo `docs/input_methods/README.md`

## Context

2026-07-29, while porting Rime to Windows (Weasel/小狼毫). The user asked whether
any config could be **shared** with the Unix side (Squirrel on macOS, ibus-rime on
Linux). It can — but the mechanism chosen this round duplicates the shared files
in both repos rather than giving them a single home.

## Investigation

Established during the port (all source-verified, so it doesn't need redoing):

- **The schema sets are identical.** Weasel builds its bundled data from plum's
  `:preset` package set (`rime/weasel@master:build.bat:295` →
  `plum/preset-packages.conf` = `bopomofo cangjie essay luna-pinyin prelude quick
  stroke terra-pinyin`). That is the same set Squirrel ships — confirmed against
  the built schemas already in `~/Library/Rime/build/` on the Mac. So one
  `schema_list` resolves identically on all three platforms with no downloads.
- **The portable/non-portable line is sharp.** `default.custom.yaml` and
  `<schema>.custom.yaml` are engine-level and fully portable.
  `weasel.custom.yaml` / `squirrel.custom.yaml` are not: `app_options` keys on the
  EXE name on Windows and on the bundle id on macOS, and `style/` is Weasel-only.
- **Rime never rewrites `*.custom.yaml`** — switch state goes to `user.yaml`
  (`librime:src/rime/switcher.cc`, `Switcher::SetActiveSchema`). So these are safe
  as plain managed files in any mechanism; no `modify_` overlay is needed, which
  keeps the externalisation option open.
- Both repos already have a `.chezmoitemplates/` directory and both already use
  the `{{ template "…" . }}` indirection (for herdr's config), so the current
  duplicated-body layout cost nothing to adopt.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. Duplicate `.chezmoitemplates/rime/` in both repos** (chosen 2026-07) | Zero new infrastructure; both repos stay self-contained and offline-appliable; `diff` between the two dirs is a cheap, explicit drift check | Two copies to keep in sync by hand; nothing *enforces* it — a one-sided edit is silent until someone diffs |
| B. Standalone `rime-config` repo pulled by `.chezmoiexternal.toml` in both | Genuine single source of truth; drift becomes impossible | A third repo to publish and maintain; adds a network fetch to `chezmoi apply` in both repos (and a GFW failure mode); `.chezmoiexternal` refresh semantics add a moving part for two small YAML files |
| C. Git submodule in both repos | Single source of truth, no network fetch at apply time | Submodules are a well-known footgun in dotfiles repos; contributors must remember `--recursive` |
| D. Keep Rime config unmanaged, as the Unix repo did before | No sync problem at all | Loses the entire point — the user explicitly asked for shared config |

## Current blocker / open questions

Not blocked, just not yet worth it. Two small YAML files is under the threshold
where a third repo pays for itself. Revisit when any of these become true:

- The shared set grows beyond ~3 files (e.g. custom dictionaries, `lua/` scripts,
  a hand-maintained 詞庫).
- A real drift incident happens (one repo edited, the other not, and it wasn't
  noticed until a machine misbehaved).
- A third platform/frontend joins (fcitx5-rime on Linux would read
  `~/.local/share/fcitx5/rime` — a third renderer, same shared bodies).

Open question if option B is taken: whether the external should be pinned to a tag
or track `main`. Pinning means the two repos can legitimately diverge for a while,
which is arguably worse than today's honest hand-sync.

## Decision (if any)

`2026-07-29 chose option A` — duplicate the bodies, document the sync obligation
in both repos' docs, and make the copies byte-identical so `diff` is a valid check.
Deliberately kept the layout externalisation-ready: the shared bodies already live
alone in `.chezmoitemplates/rime/` with nothing else in that directory, and every
platform file is a one-line renderer, so switching to option B is a mechanical
change to two `.chezmoiexternal.toml` files plus deleting the duplicated dir.

To check for drift today:

```bash
diff -r ~/src/tries/2026-07-09-windows-dotfiles/.chezmoitemplates/rime \
        ~/.local/share/chezmoi/.chezmoitemplates/rime
```

## References

- plum preset set: <https://github.com/rime/plum/blob/master/preset-packages.conf>
- Weasel data build: <https://github.com/rime/weasel/blob/master/build.bat>
- Rime customization guide: <https://github.com/rime/home/wiki/CustomizationGuide>
- chezmoi externals: <https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/>
