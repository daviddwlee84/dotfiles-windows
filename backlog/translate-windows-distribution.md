# Ship prebuilt Windows binaries for `translate` and install it via scoop

**Status**: P2 — not started (the `go install` path shipped 2026-07-27 and works)
**Effort**: M
**Related**: `TODO.md` · `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (translate block) · `Justfile` (`upgrade-translate`) · `docs/translate.md` · upstream repo `daviddwlee84/translate`

## Context

2026-07-27. `translate` was brought to this repo at parity with the parent
dotfiles (macOS = Homebrew tap, Linux = `go install`). Windows has neither brew
nor ansible, and the upstream repo ships **no prebuilt binaries at all** — it has
no `.github/` directory, no GoReleaser config, and no release workflow; the only
tags are source tags on the Go module proxy (latest `v0.5.2`, 2026-07-22).

So the shipped Windows path builds from source:

```powershell
go install github.com/daviddwlee84/translate@v0.5.2   # GOBIN=~\.local\bin
```

That works — verified to cross-compile clean for `windows/amd64` and
`windows/arm64`, pure Go (`modernc.org/sqlite`, no cgo) — but it has real costs.

## Why revisit

| | `go install` (shipped) | scoop bucket (proposed) |
|---|---|---|
| First install | **several minutes** (embedded swagger-ui bundle + sqlite) | seconds (download + extract) |
| Prerequisite | a Go toolchain (~400 MB of scoop `go` + module cache in `~\.local\share\go`) | none |
| Upgrade | `just upgrade-translate` — a separate, easy-to-forget recipe | free, via the existing `just upgrade-scoop` (`scoop update *`) |
| Version visibility | pinned in a template comment | `scoop status` / `scoop info` |
| Fresh-box `chezmoi apply` | noticeably slower for `workstation` (the toggle defaults on) | unchanged |

The upgrade story is the strongest argument: everything else on this box updates
with `just upgrade-scoop`, and `translate` is the one exception.

## What it would take (all in the `translate` repo, not this one)

1. **`.goreleaser.yaml`** — `windows/amd64`, `windows/arm64` (plus darwin/linux
   for free, which would also let the parent repo's Linux `go_tools` role switch
   to a binary download). `CGO_ENABLED=0` already holds.
2. **`.github/workflows/release.yml`** — tag-triggered GoReleaser run producing
   zipped archives + `checksums.txt`. The repo has no CI at all today, so this is
   greenfield.
3. **A `scoop-bucket` repo** (`daviddwlee84/scoop-bucket`) with a
   `translate.json` manifest — `version`, `url`/`hash` per architecture, `bin`,
   and a `checkver` + `autoupdate` block so the manifest tracks new tags itself.
   GoReleaser's `scoops:` publisher can write the manifest on release.
4. **This repo**: replace the `{{ if .installTranslate }}` block's `go install`
   with `Scoop-Install @('daviddwlee84/translate')` after a
   `scoop bucket add daviddwlee84 https://github.com/daviddwlee84/scoop-bucket`
   in `Ensure-Scoop`; drop the `Scoop-Install @('go')` line and the
   `just upgrade-translate` recipe; update `docs/translate.md` + `.zh-TW.md`,
   `docs/tools.md` + `.zh-TW.md` (move the row out of the "built from source"
   framing), and the skill template's gotcha bullet.

Note `Scoop-Install` already handles bucket-qualified names — it splits on `/`
and compares the last segment against `scoop export` (see the function in
`run_onchange_after_10_packages.ps1.tmpl`), which is exactly the
`extras/opencode-desktop` shape used today.

## Considered and rejected

- **winget manifest** — needs a PR into `microsoft/winget-pkgs` per release plus
  their validation pipeline; far more ceremony than a personal scoop bucket for a
  tool with one user.
- **Committing a prebuilt `translate.exe` into this dotfiles repo** — bloats the
  repo, can't be updated independently, and chezmoi would have to manage a binary.
- **Keeping `go install` but pointing it at `@latest`** — loses reproducibility on
  a fresh box without fixing either the build time or the Go dependency.

## Revisit when

- Any second machine has to install this (the multi-minute build stops being a
  one-off annoyance), **or**
- the `translate` repo grows CI for another reason (then GoReleaser is a small
  increment), **or**
- the parent repo's Linux side also wants to stop building from source.
