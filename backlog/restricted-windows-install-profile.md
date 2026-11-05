# Opt-in restricted Windows installation profile

**Status**: deferred
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
