# Opt-in restricted Windows installation profile

**Status**: shipped (profile implementation; work-machine rollout and remaining source adapters pending)
**Effort**: L
**Related**: [TODO](../TODO.md), [PowerShell runtime notes](../docs/powershell-maintenance.md),
`bootstrap.ps1`, `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`

## Context and decision

2026-11: Herdr reported `Could not start the saved shell: CreateProcessW` with
`scoop\shims\pwsh.EXE` and `拒绝访问。 (os error 5)`. Windows also displayed a
notification saying the administrator blocked the content.

The user explicitly chose to repair PowerShell/Herdr executable selection first,
and defer a restricted installation profile. Normal Windows must retain its
existing Scoop workflow; do not silently change all `managedMachine` users.

## Implementation — 2026-11-05

The user confirmed winget and official installers, with separate named approval
for other downloads/builds. The opt-in `organizationProfile=microsoft` now has a
shared source catalog, pre-Scoop bootstrap branch, provider-aware install/upgrades,
NVM/owned-prefix separation, process-only Scoop exclusion, secondary-download gates,
and a metadata-only doctor. Standard `none` behavior remains the default. See
[Microsoft Organization profile](../docs/microsoft-organization.md).

This ships policy/routing, not a claim that every tool is approved or runnable.
Pending adapters/sources (including Pueue service migration, compilers, fonts and
several personal tools) remain explicit. No local installation/apply, Scoop removal,
service migration, security-policy modification or saved-session rewrite was done.
Fresh Microsoft workstations now bootstrap directly from in-box Windows PowerShell
5.1: winget installs/discovers stable pwsh entry points plus Git, chezmoi, uv, Bun,
official CPython and 7-Zip before modifiers run. Runtime probes and a persisted-config
handshake precede the full apply, and explicit unattended workstation setup is
supported. Existing-machine migration remains separate; no real machine was installed
or fully applied while implementing this path.

Validation on 2026-11-05: PowerShell lint reported no Errors; the full Pester run
passed 890 tests with 7 skipped, including 14 fresh-machine/bootstrap cases. The
in-box Windows PowerShell 5.1 entry was exercised with fake installers; the Python
version probe was also executed from real 5.1 against an existing development runtime.
This is not a claim of clean-machine installation E2E validation. The focused organization/prompt pass also rendered
and parsed all 21 PowerShell templates with Microsoft/all-feature data. The public
`just organization-doctor` recipe was exercised without loading a profile. No
doctor `-Probe` checks or live deployment were performed. Offline docs build was
blocked by missing cached mkdocs-material; public manifest lookups were partially
limited by GitHub API rate limits, so install-time exact winget metadata checks
remain required.

## Live dogfood — 2026-11-05

The user authorized applying this branch on the existing Microsoft ARM64 machine.
A private snapshot of 141 live files was created first. Official winget installation
and native probes succeeded for PowerShell 7.6.9 and CPython 3.14.10. The local config
now selects Microsoft policy and those explicit runtimes; existing feature toggles,
NVM selection, registry fallback policy and local override files were preserved.

Full apply first stopped at the known LazyGit auto-migration conflict. Its reviewed
diff retained all six branch colors and added the managed clipboard helper; only
those backed-up LazyGit targets were force-applied. Normal full apply then completed.
The final files-only status converged; the full profile loaded with zero Scoop PATH
entries. Eight core executable version probes passed, and the original five tracked
Herdr/Bun/Pueue processes remained alive. Herdr unmanaged tables, local overrides and
Claude settings/HUD matched their snapshots.

Dogfood fixes committed locally as `32b27e1`:
- Alacritty must use the explicit PowerShell executable, not inherited `pwsh` lookup.
- Stream winget install progress and identify the package waiting for native UAC;
  `--silent` / `--disable-interactivity` do not supply administrator consent.
- Promote the official 7-Zip CLI directory only when its executable exists; its
  installer does not add `7z` to PATH. The deployed native ARM64 7-Zip probe passed.
- Focused tests for these fixes passed (46 tests).

**Initial result / merge hold (superseded in part below):** Pi's company npm artifact download timed out (rollback
reported success); Apprise and LiteLLM failed on company PyPI `.whl.metadata` HTTP 404.
No public-registry fallback or security-policy change was used. Other unapproved
sources remain pending. Apply's exit 0 is intentionally nonfatal and does not make
these three failed installations successful. Investigate the corporate feed before
claiming complete application readiness; this existing-machine dogfood is not a
clean-machine E2E install test.

## Corporate registry follow-up — 2026-11-09

- Pi's same-source npm retry succeeded (`FallbackUsed=false`, 121 packages).
  Its deployed no-profile launcher reported **1.4.0**. The retry's npm timeout/retry
  options were command-scoped; persistent npm config was unchanged.
- Apprise's metadata 404 no longer reproduced. A subsequent pywin32 artifact
  connection timeout was resolved in a retry with 60-second connect/read timeouts
  and one concurrent download. This does not establish a network product's root cause.
- The first successful Apprise retry exposed inherited Scoop `UV_*` storage: even
  WinGet uv installed into the old Scoop tool environment. That retry **did change
  the old Apprise environment**; do not describe the whole investigation as leaving
  it untouched. No old directories were deleted or moved.
- The new policy redirects absent/Scoop-owned uv storage to
  `%LOCALAPPDATA%\dotfiles\uv` only in process/child environments, retaining explicit
  non-Scoop locations and persisted User values. Apprise was then installed through
  the corporate feed into this independent root. Its **2.1.0** executable ran and
  `win32api`, `win32con`, `win32gui` imported successfully using its environment's
  Python with `-I`; no notification was sent.
- Microsoft repo-owned uv child defaults are now 60-second connect/read timeouts
  and download concurrency 1; explicit caller/process settings win. Registry,
  fallback classification, TLS, DNS, GSA and proxy settings are unchanged. Captured
  output redacts artifact signatures and Authorization header credentials.

**Still blocked: LiteLLM.** The same corporate-only install now fails on
`litellm-1.106.1-cp310-abi3-macosx_10_12_x86_64.whl.metadata`, not the earlier Granian
metadata. The company simple index returned 200 and advertised metadata; a bounded
metadata GET returned 404 with this backend message:

```text
Cannot find the file litellm-1.106.1-cp310-abi3-macosx_10_12_x86_64.whl.metadata in package 'litellm 1.106.1' in feed 'pypi-public'
```

This is evidence for the corporate feed maintainer, not a reason to enable public
fallback. The index listed Windows amd64 wheels and an sdist for 1.106.1, but no
Windows ARM64 or universal wheel. Platform compatibility still needs review even
if the feed metadata is repaired. No automatic version pin/downgrade, x64 runtime
switch or source-build workaround was introduced. LiteLLM is not verified usable;
merge remains on hold, and pending source approvals/adapters remain unchanged.

The OrganizationPolicy module and both shared skills were backed up under the
private dogfood snapshot and target-applied with scripts/externals excluded. A new
no-profile child imported the deployed module through a function scope, then
resolved Apprise to the owned uv bin and ran Apprise/Pi version probes successfully.
Process PATH had zero Scoop entries, the checked persisted User PATH/uv variables
were unchanged, and the three deployed targets converged. Changed-file analyzer
checks reported zero Errors (one pre-existing automatic-variable warning).

The post-migration full Pester run reported **879 passed, 26 failed, 8 skipped**;
OrganizationProfile and PackageSourceRunner passed all **49** tests. The failures
exposed legacy fixtures inheriting the live Microsoft profile: template renders
skipped unapproved hooks/plugins, metadata/cache fixtures auto-imported live source
policy, and the Pi argv child found the real deployed policy instead of its fake
Scoop owner. Fixtures now select `none` or stub only the policy boundary for mocked
operations; the real Pi launcher child gets an isolated home. Production policy
was not weakened. These fixture changes also pass analyzer Error checks.

On 2026-11-22 the native Windows full-suite rerun after the fixture edits
reported 901 passed, 5 failed, 7 skipped and one failed container. All five
failed test entries were LazyGit branch-insights cases. A separate run passed
all five LazyGit cases, all 35 OrganizationProfile cases and all 14
PackageSourceRunner cases. The full-suite gate is still open; isolated success
does not establish the cause of the full-suite failure.

Replaying the runtime prerequisite and profile on `ddbceb6` produced 920
passed, 5 failed and 8 skipped. The LazyGit container failed during setup with
Pester's escaped `break`/`continue` diagnostic. A clean `ddbceb6` worktree on
the same host also produced that container error (839 passed, 18 failed
overall). Treat this as a known baseline failure, not a green full-suite run.

The investigation below is retained as historical evidence, not live approval.

## Investigation

- The Scoop pwsh shim was unsigned. The executable it pointed to had a valid
  Microsoft Authenticode signature and reported **7.6.3 / Core** in a successful
  direct no-profile probe. This does not prove every Scoop tool is blocked or
  that any particular installation source is approved.
- `gh` also failed to launch with `Access is denied`; no attempts were made to
  alter policy, unblock it, or add exclusions.
- Company Portal and App Installer were installed, but their existence does not
  reveal the organization's approved software catalog. The user had not checked
  the catalog. Bounded Defender/AppLocker/Code Integrity queries did not locate
  a matching pwsh block event; the enforcing product/rule remains unknown.
- Bootstrap installs Scoop before chezmoi init. The package script unconditionally
  calls `Ensure-Scoop`. A future profile must gate both before any installer runs,
  not merely substitute one package name or reorder PATH.
- Profile PATH favors Scoop shims. Pi uses Scoop Node's owned global prefix;
  Pueue resolves a matched client/daemon pair from Scoop and may start a service.
  Git bash/file.exe, translate's custom bucket and explicit upgrade recipes also
  need ownership-aware migration.

## Candidate-source matrix (not an approved install list)

| Group | Candidate | Migration concerns / verification |
|---|---|---|
| PowerShell | Company Portal deployment; approved Microsoft package or `Microsoft.PowerShell` winget package | Verify actual MSI/MSIX entrypoint, Core >=7.4, signature, launch, update owner. Current upstream winget may default to MSIX, not the MSI Program Files path. |
| Git | Company Portal / official Git for Windows installer; `Git.Git` if approved | Existing machine Git may suffice. Preserve credential manager, bash and file.exe resolution; public winget manifest is not maintained by Git for Windows itself. |
| chezmoi | Approved `twpayne.chezmoi` package or verified upstream release | Needed before data prompts. Check artifact provenance, executable resolution, update owner and no implicit Scoop fallback. |
| Node/npm | Approved Node LTS installation | Repo Pi prefix and npm command are Scoop-owned; preserve rollback and global-package ownership before changing. Do not mix nvm and Scoop prefixes. |
| uv/Python | Approved `astral-sh.uv` package or upstream release | uv's Python downloads are a separate source decision. Preserve company PyPI policy and existing environments; installer source and dependency index are not interchangeable. |
| Bun / just | Company deployment or reviewed upstream packages | Package mapping, signing, update owner and IT approval still need verification. Do not assume a public package exists or is permitted. |
| Shell utilities | Inventory starship, zoxide, fzf, fd, rg, bat, eza, jq, lazygit, yazi, television, editors | Classify required versus optional; check each package/source instead of mass converting. Missing tools must have explicit degraded-mode diagnostics. |
| Pueue | Approved matched client/daemon release | Service versus user-daemon lifecycle, existing tasks and update compatibility. Do not launch an arbitrary PATH daemon. |
| Coding agents / Herdr / plugins | Approved vendor/package sources | npm prefixes, download-and-execute installers, Go plugin builds and runtime upgrades must respect the same restriction. |
| Fonts / media / IaC / optional runtimes | Per-package approved deployment | Scope, architecture, elevation and upgrades vary; not necessary to unblock the initial PowerShell shell. |

## Proposed boundary

Add a default-off `standard|restricted` installation profile, independent of role,
`managedMachine`, and the existing corporate registry fallback toggle. Restricted
must never initialize Scoop or silently retry through another unapproved source.
Unapproved installs should be reported as pending approval, not as success.
Preserve run-script nonfatal summaries and existing standard behavior.

No automatic executable copying/renaming, security exclusions, Scoop uninstall,
or global npm migration. Do not promote the old ASR-exclusion pitfall into policy
for this managed environment.

## Open questions

1. What installation and update channels does IT actually approve?
2. Which tools must work in the first restricted profile, and which may be absent?
3. How should bootstrap receive the profile before chezmoi prompts exist?
4. How should existing owned prefixes/services migrate with rollback?
5. Which Herdr UI version/config/recovery mechanisms need support?

## References

- [Microsoft PowerShell Windows installation](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)
- [Company Portal work apps](https://learn.microsoft.com/en-us/intune/user-help/apps/install-apps-windows)
- [Git for Windows installation](https://git-scm.com/install/windows)
- [chezmoi installation and verification](https://www.chezmoi.io/install/)
- [uv installation and upgrade ownership](https://docs.astral.sh/uv/getting-started/installation/)
- [Node.js official downloads](https://nodejs.org/en/download)
