# Codex update reports EBADPLATFORM or succeeds without its ARM64 executable

**First seen:** 2026-09-09  
**Affects:** Windows ARM64, native Scoop Node 24.21.0, npm 11.19.0  
**Status:** original Codex 0.144.1 restored and live inference verified; newer native download remains blocked by timeout

## Symptoms

```text
npm error code EBADPLATFORM
npm error notsup Unsupported platform for @openai/codex@0.153.0-alpha.6-win32-x64: wanted {"os":"win32","cpu":"x64"} (current: {"os":"win32","cpu":"arm64"})
```

After selecting the generic stable 0.152.1 wrapper instead, npm returned exit 0,
but the version probe failed:

```text
Error: Missing optional dependency @openai/codex-win32-arm64. Reinstall Codex: npm install -g @openai/codex@latest
```

## Cause and evidence

- At observation time, the configured corporate feed's `latest` tag pointed at
  the x64-only alpha artifact, not the generic wrapper. This does not establish
  whether public upstream had the same tag; no alternate feed was used.
- The same feed advertised generic stable 0.152.1 with a win32-arm64 optional
  dependency. Its wrapper installed, but the native archive did not.
- npm logged `reify failed optional dependency` and still exited 0. A separate
  required install of the matching ARM64 alias also timed out. Package metadata
  availability therefore did not establish archive download availability.
- Updating the Scoop prefix did not replace the old Codex already running from
  an NVM prefix. A running process is not evidence that the newly resolved CLI
  is usable.

## Recovery used

The complete 0.144.1 wrapper and ARM64 archives were already in the local npm
cache, but under old mirror URL keys. A normal corporate-feed `--offline`
rollback returned `ENOTCACHED` because the requested URL differed.

Recovery used those existing bytes **without contacting the old mirror**:
verified the cache SHA-512 integrity and compared archive SHA-1 with the current
corporate feed's `dist.shasum`, extracted both into a temporary staging tree,
verified the staged `codex --version`, then swapped only the Scoop Codex package
directory. The failed new tree was retained outside the installed prefix. No
PATH changes, live NVM process changes, or source-policy overrides were made.

The restored native CLI reported 0.144.1. A fresh ephemeral, read-only
`codex-copilot-once` invocation with SpecStory disabled returned `PROXY_OK` from
Astra. This older CLI warns that its bundled Astra model metadata is missing;
the wrapper still supplies the live context and compact limits.

## Prevention

- Inspect the configured feed's dist-tags, version and CPU metadata before using
  a platform-suffixed `latest`. Never force an incompatible architecture.
- Treat a successful native `--version` probe as part of installation success;
  npm exit 0 is insufficient for optional native packages.
- Preserve a complete runnable package generation before upgrades, not only the
  generic JavaScript wrapper. Prefer a staged install plus health-checked swap.
- Bound downloads and keep corporate-source policy intact. Do not turn a timeout
  or authentication failure into an unapproved public-registry retry.
- Keep the source package recipes unpinned until a reviewed permanent policy is
  chosen; this incident's exact versions are recovery evidence, not a universal
  future default.

## Where to report

Start with the organization's PackageFeedProxy / 1ES package-feed support owner
for the observed `latest` metadata. No verified internal ticket URL or team alias
was available during this investigation; use the organization's normal support
directory rather than guessing a public GitHub repository for that service.

Suggested report title: **`@openai/codex latest resolves to an x64-only alpha on Windows ARM64`**.
Include the observation timestamp, Node/npm/OS architecture, the configured
feed's dist-tags, the selected version's `os`/`cpu`, and the redacted
`EBADPLATFORM` error. Ask the feed owner to compare its cached tags with upstream
and inspect tag synchronization. Treat the native archive timeout as a separate
download symptom rather than assuming it has the same cause.

The follow-up metadata check still returned `latest=0.153.0-alpha.6-win32-x64`
from the corporate feed. The public npm metadata request failed its TLS
connection; TLS checks were not disabled and no alternate installation source
was used. Consequently, **upstream tag correctness remains unverified**.

If the same bad tag is confirmed on public npm, report it through
[OpenAI Codex's issue form](https://github.com/openai/codex/issues/new/choose).
Related, but not proven duplicate, reports are:

- [#41876: Windows CLI updater offers a version that npm latest does not resolve](https://github.com/openai/codex/issues/41876).
- [#11744: Windows missing optional native dependency after packaging changes](https://github.com/openai/codex/issues/11744)
  (closed; older x64 case, not evidence for this ARM64 tag or download failure).

Public reports should omit corporate registry addresses, internal feed IDs,
usernames, npm config credentials, and signed download URLs. Submit the complete
corporate evidence only through the approved internal support channel.

## Related

- [Copilot proxy guide](../docs/copilot-proxy.md)
- [Windows ARM64 rough edges](../backlog/windows-arm64-managed-machine-rough-edges.md)
