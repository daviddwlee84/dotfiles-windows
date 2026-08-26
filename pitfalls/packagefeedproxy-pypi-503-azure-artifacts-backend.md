# uv fails with HTTP 503 while downloading from the company PyPI feed

**Symptoms**: `Request failed after 3 retries`, `HTTP status server error (503 Service Unavailable)`, final URL under `ms-feed-*.pkgs.visualstudio.com`, `just docs-build` fails although the configured index is `packagefeedproxy.microsoft.io/pypi/simple`

**First seen**: 2026-08
**Affects**: managed Windows machines using uv through the company PyPI pull-through feed
**Status**: source-isolated opt-in fallback implemented

## Symptom

A managed shell configures:

```text
UV_DEFAULT_INDEX=https://packagefeedproxy.microsoft.io/pypi/simple/
```

but uv reports the failure against a different-looking host:

```text
error: Request failed after 3 retries
Caused by: Failed to fetch: https://ms-feed-*.pkgs.visualstudio.com/.../pypi/download/...
Caused by: HTTP status server error (503 Service Unavailable)
```

A successful feed-root or package-metadata probe does not disprove the problem;
the redirected artifact download can fail independently.

## Root cause

`packagefeedproxy.microsoft.io` is the configured company pull-through endpoint.
It resolves package artifacts through an Azure Artifacts backend, so uv displays
the final `*.pkgs.visualstudio.com` download URL when that backend returns 503.
This is not a malformed PyPI URL and does not show that `pypi.org` itself failed.

## Workaround

The default remains corporate-only. On a machine where public fallback is
explicitly permitted, enable the `Allow one public PyPI/npm retry after eligible
corporate feed failures` init prompt and re-apply/reload the profile.

Repo-owned npm/uv commands then:

1. try only the corporate source;
2. classify the captured failure;
3. retry exactly once against only the public source for timeout, temporary
   network errors, or explicit HTTP 5xx.

For a one-off manual docs build without changing the prompt:

```powershell
uv run --no-project --no-config `
  --default-index https://pypi.org/simple --index-strategy first-index `
  --with mkdocs-material --with mkdocs-static-i18n mkdocs build --strict
```

## Prevention

- Never configure public PyPI as an `extra-index` beside the company feed.
- Never fall back on 401/403, TLS/certificate, policy, 404/package-absence,
  rate-limit, solver/build, or local permission failures.
- Keep fallback command-scoped; do not rewrite the parent shell or npmrc.
- Test artifact resolution, not only the index root.
- Keep `scripts/package-source-runner.ps1` covered by deterministic fake-command
  tests so classification does not broaden accidentally.

## Related

- [`packagefeedproxy-npm-404-wrong-base-path`](packagefeedproxy-npm-404-wrong-base-path.md)
- [`docs/tools.md`](../docs/tools.md#package-registries)
- `AGENTS.md` hard invariant 8
