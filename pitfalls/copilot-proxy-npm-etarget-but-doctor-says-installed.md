# `npm ETARGET` is followed by `copilot-proxy doctor` saying the requested version is installed

**Symptoms** (grep this section): `copilot-proxy restart` prints:

```text
copilot-proxy: installing @jeffreycao/copilot-api@2.1.0 (one-time — later starts skip this) ...
npm error code ETARGET
npm error notarget No matching version found for @jeffreycao/copilot-api@2.1.0.
copilot-proxy: starting (@jeffreycao/copilot-api@2.1.0) on port 4141 ...
```

A subsequent doctor contradicts npm:

```text
Package
  ✓ installed        @jeffreycao/copilot-api@2.1.0
```

The proxy can listen and serve models because it actually launched an older tree
left in `~/.local/share/copilot-api/pkg`.
**First seen**: 2026-08
**Affects**: the Windows Copilot module before installed `package.json` metadata
became the installation postcondition, especially after the pin changed from
`1.13.14` to `2.1.0` on a lagging corporate npm mirror.
**Status**: fixed — stale package contents cannot satisfy readiness or receive a
new stamp.

## Root cause

The old installer used this success test after npm/Bun exited:

1. any `node_modules/.bin/copilot-api*` shim exists, **or**
2. any `node_modules/@jeffreycao/copilot-api` directory exists.

It did not read that package’s `package.json`. When npm returned `ETARGET`, the
old package tree remained, the weak filesystem predicate returned true, and the
installer wrote the **requested string** `@jeffreycao/copilot-api@2.1.0` to
`.installed-spec`. Doctor trusted that stamp plus the same old directory/binlink,
so it claimed 2.1.0 and `start` launched the stale binary.

The exact 2.1.0 release exists on public npm. In the first report, `ETARGET` was
therefore consistent with the configured corporate pull-through mirror not having
synchronized that version yet—not evidence that the public package never existed.

Reference: [public npm metadata for 2.1.0](https://registry.npmjs.org/@jeffreycao%2Fcopilot-api/2.1.0).

## Workaround

First identify the registry and verify the exact pin **before** deleting the
working prefix:

```powershell
npm config get registry
npm view '@jeffreycao/copilot-api@2.1.0' version
# Compare only where direct public npm is permitted:
npm view '@jeffreycao/copilot-api@2.1.0' version --registry https://registry.npmjs.org/
```

If only the corporate mirror is missing 2.1.0, wait/request synchronization or
use an approved registry for the reinstall. The fixed Windows module can also
recover automatically from this exact case: it downloads the published 2.1.0
runtime files from jsDelivr, verifies a baked SHA-256 for every file, and installs
only ordinary dependencies through the configured npm registry. Then deploy the
fixed module and reinstall:

```powershell
chezmoi apply ~/.config/powershell/modules/Copilot/Copilot.psm1
Import-Module "$HOME/.config/powershell/modules/Copilot/Copilot.psd1" -Force
copilot-proxy reinstall
copilot-proxy doctor
```

Do not switch the managed pin to `latest`; that trades a diagnosable mirror delay
for an unreviewed gateway upgrade.

## Prevention

- Read installed `package.json.name` and `.version`; a directory or binlink is not
  proof of which package landed.
- Store requested spec plus verified installed name/version in the stamp, and
  compare the stamp back to live metadata on every readiness check.
- Write the stamp only after metadata and a runnable launch path agree.
- Keep filesystem metadata as the authoritative postcondition. The existing
  Windows `Start-Process` child shape has returned misleading exit-code data, so
  exit status alone is insufficient.
- Test the exact regression: stale 1.13.14 tree + desired 2.1.0 + failed installer
  must return false, write no 2.1.0 stamp, and never reach proxy launch.

## Related

- [`copilot-api-connectionrefused-stale-bun-only-module`](copilot-api-connectionrefused-stale-bun-only-module.md)
- [`packagefeedproxy-npm-404-wrong-base-path`](packagefeedproxy-npm-404-wrong-base-path.md)
- [`docs/copilot-proxy.md`](../docs/copilot-proxy.md)
