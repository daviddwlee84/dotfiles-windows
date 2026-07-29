# `copilot-proxy` install dies with `error: ConnectionRefused downloading package manifest`

**Symptoms** (grep this section): `copilot-proxy start` / `copilot-proxy reinstall`
prints

```
Resolving dependencies
Resolved, downloaded and extracted [6]
error: ConnectionRefused downloading package manifest @jeffreycao/copilot-api
WARNING: copilot-proxy: install stalled with the proxy env — retrying without it ...
Resolving dependencies
Resolved, downloaded and extracted [6]
error: ConnectionRefused downloading package manifest @jeffreycao/copilot-api
Write-Error: copilot-proxy: could not install @jeffreycao/copilot-api@1.13.14 — run 'copilot-proxy doctor'.
```

Both attempts fail identically (with and without the proxy env), so it looks
like a hard network block. `~/.local/share/copilot-api/pkg` stays empty and
`.installed-spec` is never written. Meanwhile plain `npm` works fine —
`npm view @jeffreycao/copilot-api@1.13.14 version` returns the version, and
other global npm CLIs install without complaint. That mismatch is the tell.
**First seen**: 2026-07-29
**Affects**: corp/managed Windows boxes where the npm registry is an internal
mirror (here `packagefeedproxy.microsoft.io`) and `registry.npmjs.org` is
blocked, **and** the deployed Copilot module predates the npm-install branch.
**Status**: fixed — `chezmoi apply`.

## Root cause

Two things compound:

1. **Bun does not use the corp npm registry.** `Resolving dependencies` /
   `Resolved, downloaded and extracted [N]` / `error: ConnectionRefused` is
   **Bun's** output format, not npm's. Bun reaches for `registry.npmjs.org`,
   which the corp network blocks, hence `ConnectionRefused`. npm, by contrast,
   honours the `registry=` line in `~/.npmrc` (and the machine-level npmrc), so
   the same package resolves instantly.
2. **The deployed module was stale.** `Invoke-CopilotPkgInstallTry` prefers npm
   when `npm.cmd` is on PATH and only falls back to Bun otherwise — but that
   npm branch was added in commit `5351411`. The copy at
   `~/.config/powershell/modules/Copilot/Copilot.psm1` still had the
   **Bun-only** version, because `chezmoi apply` had not been run since. The
   source tree was correct; the deployed file was not.

So the error says "network", the real answer is "your deployed module is behind
your source tree". `chezmoi status` had been flagging it the whole time:

```
 M .config/powershell/modules/Copilot/Copilot.psm1
```

## Workaround

```powershell
chezmoi status                 # look for a modified Copilot.psm1
chezmoi apply ~/.config/powershell/modules/Copilot/Copilot.psm1
copilot-proxy reinstall        # now uses npm
# copilot-proxy: installed @jeffreycao/copilot-api@1.13.14 -> ...\copilot-api\pkg
```

Successful run takes ~22s and reports `added 149 packages`.

A full `chezmoi apply` also works but runs the `run_onchange` package installers
(scoop/winget/npm), which can take many minutes; target the single file when
you only need the module refreshed.

## Prevention

- **Check `chezmoi status` before debugging any behaviour of a chezmoi-managed
  script.** A stale deployed copy reproduces bugs that no longer exist in the
  source, and nothing warns you.
- Do **not** conclude "the registry is broken" from a Bun error. Confirm with
  npm first — `npm view <pkg> version` uses the configured registry, Bun does
  not. See
  [`packagefeedproxy-npm-404-wrong-base-path`](packagefeedproxy-npm-404-wrong-base-path.md)
  for how to probe the registry correctly.
- This is why `Copilot.psm1` carries the warning
  `npm.cmd not found; falling back to Bun (authenticated Azure Artifacts feeds require npm)`
  — if you see that line, the Bun path is about to be taken and will fail on a
  corp network.

## Related

- [`packagefeedproxy-npm-404-wrong-base-path`](packagefeedproxy-npm-404-wrong-base-path.md)
  — the companion trap: probing the internal registry the wrong way and
  concluding it is broken.
- `docs/copilot-proxy.md` — module overview; note it lists **bun** as the only
  prerequisite, which is true for *running* the proxy but not for *installing*
  the package on a corp feed.
