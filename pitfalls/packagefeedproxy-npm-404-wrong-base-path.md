# npm returns 404 against `packagefeedproxy.microsoft.io` — and the registry is actually fine

**Symptoms** (grep this section): probing the internal Microsoft npm mirror
looks like a dead service —

```
npm error 404
npm error 404 Note that you can also install from a
npm error 404 tarball, folder, http url, or git url.
```

`npm ping --registry https://packagefeedproxy.microsoft.io/npm/` → **404**.
`https://packagefeedproxy.microsoft.io/` and `/undici` → **404** in a browser or
`Invoke-WebRequest`. `npm view <pkg> --registry https://packagefeedproxy.microsoft.io/npm/registry/`
→ **404**. Yet DNS resolves and TCP 443 connects fine, and *some* tarball URLs
return 200. The natural conclusion — "this is only a tarball proxy for specific
packages, not a real npm registry" — is **wrong**.
**First seen**: 2026-07-29 (reached independently on two company laptops)
**Affects**: Microsoft corp machines where `registry=https://packagefeedproxy.microsoft.io/npm/`
is set at the machine level (`Q:\.tools\.npm-global\etc\npmrc`) and
`registry.npmjs.org` is blocked.
**Status**: not a bug — three probing mistakes.

## Root cause

`packagefeedproxy.microsoft.io/npm/` **is** a full pull-through npm registry.
Three separate things make it look broken:

### 1. `npm ping` is not implemented — 404 does not mean unhealthy

`npm ping` hits `/-/ping`, which this mirror does not serve. It returns 404 on a
perfectly working registry. **Never use `npm ping` as the health probe here.**
Use a metadata read instead:

```bash
npm view undici version --registry https://packagefeedproxy.microsoft.io/npm/
# 8.8.0
```

### 2. `/npm/registry/` is one segment too deep

The registry root is `/npm/`, **not** `/npm/registry/`:

| URL | Result |
|---|---|
| `https://packagefeedproxy.microsoft.io/npm/` | works |
| `https://packagefeedproxy.microsoft.io/npm/registry/` | 404 |
| `https://packagefeedproxy.microsoft.io/` | 404 |

The `/npm/registry/...` shape is what **Azure Artifacts** feeds use
(`pkgs.dev.azure.com/<org>/_packaging/<feed>/npm/registry/`), so it is an easy
habit to carry over. The give-away that `/npm/` is correct: the tarball path
that *does* work, `/npm/@scope/name/-/name-1.2.3.tgz`, is the standard npm
layout relative to base `/npm/`.

### 3. The internal feed can be *ahead* of the public mirror

Asking the internal Azure Artifacts feed for `undici@latest` yields a version
the public mirror does not have yet. Requesting that newer tarball from
`packagefeedproxy` then 404s, which reads as "tarball not provided" when it
actually means "that version isn't mirrored". At time of writing the internal
feed had `undici` 8.9.0 while the mirror's latest was **8.8.0**.

## How to verify it is healthy

```bash
R='https://packagefeedproxy.microsoft.io/npm/'
npm view undici version   --registry "$R"   # 8.8.0   -> metadata works
npm view left-pad version --registry "$R"   # 1.3.0   -> arbitrary public pkg, so no allowlist
npm view '@jeffreycao/copilot-api@1.13.14' version --registry "$R"
```

`left-pad` is the important one: an obscure package nobody on the machine has
ever installed proves this is a general pull-through proxy, not a curated
allowlist.

Metadata rewrites `dist.tarball` to Microsoft's 1ES **public** mirror:

```
https://ms-feed-25.pkgs.visualstudio.com/1es-public/_packaging/npm-public/npm/registry/undici/-/undici-8.8.0.tgz
```

Note `npm-public` — packages served here are public npm packages, so a scoped
name resolving through it is **not** evidence that a package is internal or
that an internal-feed credential is required.

## Prevention

- Health-probe with `npm view <pkg> version --registry <url>`, never `npm ping`.
- Do not copy the `/npm/registry/` suffix from Azure Artifacts URLs.
- Before concluding a version is missing, check the mirror's own `latest`
  rather than the internal feed's.
- `npm config list` shows which file supplies `registry` (`builtin` / `global` /
  `user` / `env`) and masks credentials — prefer it to reading `~/.npmrc`, which
  contains a live token.

## Related

- [`copilot-api-connectionrefused-stale-bun-only-module`](copilot-api-connectionrefused-stale-bun-only-module.md)
  — the failure this investigation was chasing. It was not a registry problem
  at all; a stale deployed module was falling back to Bun, which ignores the
  configured registry.
