# Microsoft Organization profile

An opt-in installation profile for Windows work devices where Scoop executables or
shims are blocked. It uses cataloged winget packages and reviewed official installers,
keeps company npm/PyPI policy, and reports unapproved sources instead of trying an
alternative download. It does **not** change App Control, Defender, execution policy,
TLS, credentials, or organization-managed settings.

## Selection

`organizationProfile = "none"` (also the missing-key default) preserves the normal
Scoop workflow. `"microsoft"` is independent of `role`, feature toggles and
`managedMachine`. Existing managed machines are **not** automatically migrated.
New Microsoft initialization defaults `managedMachine` to true; existing explicit
answers remain intact. Corporate operations require that switch; public fallback
remains a separate, default-off, narrowly classified retry.

### Fresh Microsoft machine: in-box PowerShell 5.1 to full apply

No manual pwsh installation or staged apply is required. After reviewing the scope,
run this revision's bootstrap from **in-box Windows PowerShell 5.1** (include
`-Source .` when using a checked-out copy):

```powershell
powershell.exe -NoProfile -File .\bootstrap.ps1 -Source . -OrganizationProfile microsoft
```

Fresh, explicitly selected Microsoft workstations also support unattended setup:

```powershell
powershell.exe -NoProfile -File .\bootstrap.ps1 -Source . `
  -OrganizationProfile microsoft -NonInteractive -Role workstation `
  -Name 'Your Name' -Email 'you@example.com'
```

If you only have the reviewed bootstrap file, omit `-Source .` to fetch the repo
through chezmoi. The selected branch must contain this implementation. For an
unpublished local commit, use its checkout rather than the older remote main.
Non-Microsoft unattended setup still requires explicit `-Role minimal`.

Bootstrap performs these steps before the full apply:

1. Locate the IT-approved App Installer/winget, including registered App Installer
   metadata when PATH is stale. Windows 11 normally supplies it; if IT removed or
   disabled it, obtain it through IT rather than installing another package manager.
2. Install the official `Microsoft.PowerShell` winget package beside Windows
   PowerShell 5.1. Let the provider select a compatible architecture; never force
   x64, switch to ZIP, or disable signature/policy checks.
3. Rediscover a stable MSIX execution alias or registered MSI installation in the
   **same session**, then verify Core >=7.4. Since PowerShell 7.6, winget defaults
   to MSIX: do not assume a Program Files MSI path or persist a versioned WindowsApps
   package directory as the shell entry point.
4. Install/verify Git, chezmoi, uv, Bun, Python and 7-Zip **before config modifiers**.
   New Python uses official `Python.Python.3.14` user-scope installers (x64/ARM64);
   an existing approved Python must be >=3.11. The in-box Python Store stub is not
   a runtime. Persist `pythonExecutable` for Herdr merging and uv selection.
5. Initialize config, verify that the source catalog, Microsoft profile and runtime
   paths were actually persisted, then run **full `chezmoi apply`**. No terminal
   restart or manual dependency installation is needed between these steps.

Full apply means all configuration and selected, approved tools—not forcing every
optional toggle on or approving unreviewed plugins. Pending/unsupported sources stay
visible. A required runtime failure stops bootstrap before apply; it does not try
another source. No Scoop initialization or execution-policy change is performed.
If IT requires signed scripts, use its approved signing/deployment route.

For an **existing work machine**, do not run a full bootstrap/apply as a diagnostic.
First inspect sources with `appsrc` and the read-only command below. Ensure an approved
non-Scoop PowerShell and chezmoi are installed. Then deliberately edit the existing
chezmoi `[data]` table (do not create a duplicate table):

```toml
organizationProfile = "microsoft"
managedMachine = true
allowPublicPackageFallback = false
powerShellExecutable = 'C:\path\to\approved\pwsh.exe'
nodeExecutable = ''
pythonExecutable = '' # bootstrap records the selected official runtime on fresh machines
organizationSourceApprovals = []
```

The PowerShell path is mandatory: GUI terminals and no-profile children must not fall
back to an inherited Scoop shim. The example is a placeholder, not a path to copy.
Node defaults to the active NVM4W runtime, then other non-Scoop candidates; a nonempty
`nodeExecutable` explicitly selects one coherent Node/npm installation. Invalid or
Scoop overrides are errors, never silently replaced. Do not copy/rename a blocked
binary to make it run.

Preview the diff, review selected/pending tools, then apply only the intended targets.
A diff can run config modifiers; Microsoft mode disables unapproved implicit Python
downloads and preserves existing Herdr config if its parser is unavailable.

## Catalog and approvals

`.chezmoidata/windows-tool-sources.json` is the complete source classification used
by the Microsoft adapter, templates and diagnostics. Feature toggles still express
what you want; a toggle does **not** approve every plugin or compiler it might use.

| Category | Behavior |
|---|---|
| Cataloged winget CLI/GUI | Exact ID and source; provider selects a compatible installer. Metadata is checked before acquisition; absent/unsupported packages are reported. |
| Herdr official installers | Reuse the existing verified official helpers. |
| Oh My Pi (`omp`) | Separate from Oh My Posh; currently reviewed for Windows x64 only. |
| Pi and Python dependencies | Existing corporate source runner; Pi disables lifecycle scripts and npm bin links. Python distributions are a separate source. |
| Git externals, plugins, personal releases, npm native payload chains | `pending-approval` unless their named source has been explicitly reviewed and approved. |
| No implemented compatible source (Pueue migration, compilers, fonts, several personal tools) | Pending/unsupported, never Scoop or a source-build fallback. Approval alone does not implement a missing adapter. |

An approval is a known individual catalog ID, for example `yazi-plugins`; there is
no wildcard. Add an ID to `organizationSourceApprovals` **only after** confirming its
source and downstream downloads with IT. Unknown IDs fail closed. A hash verifies
integrity, not approval. A registry approval does not automatically approve a package's
postinstall downloads. Some entries are inventoried but deliberately have no automatic
installer yet; their report says `unsupported-adapter` even after source approval.

Without plugin approval, Neovim starts with its built-in functionality, Yazi plugin
acquisition is skipped, and the Pi-agents external is not fetched. Claude's repo-owned
settings/HUD merger is skipped until marketplace approval, preserving existing live
settings rather than adding marketplaces or hooks. This does **not** disable plugins
already configured by the user or IT. Copilot provisioning requires its own approval;
Microsoft provisioning failure does not retry through a different proxy or CDN.

OS feature, WSL distro and sshd/service/firewall provisioning are not automatically
run by this profile. Existing manual administrative commands remain explicit separate
operations. Neither this profile nor the catalog is a sandbox for third-party
self-updaters, user scripts, plugins already configured elsewhere, or WSL's own tools.

## Ownership and migration

- Scoop/Chocolatey files and persisted PATH remain untouched. Microsoft shell and
  installer selection remove Scoop roots from their **process** PATH, including
  custom `SCOOP`/`SCOOP_GLOBAL` roots. Inspect local overrides that reintroduce paths.
- Existing NVM selection and unrelated npm globals are preserved. New repo-owned
  npm agents use `%LOCALAPPDATA%\dotfiles\npm`. Existing recognized Pi installs can
  run from their original prefix, but are not taken over for upgrades; migrate them
  separately after reviewing ownership.
- Existing differently owned tools are preserved rather than duplicated. This may
  require an explicit migration before the new profile can manage updates.
- No automatic Pueue service/queue migration, saved Herdr session rewrite, Scoop
  removal, prompt replacement, or environment-local file edits.
- Open a new approved PowerShell/GUI session after changing profiles. An already
  running Herdr server retains its environment and saved absolute shell paths.

## Diagnostics and upgrades

```powershell
just organization-doctor
just organization-doctor -OrganizationProfile microsoft -Json # preview without changing config
just organization-doctor -Json
just organization-doctor -Tool pwsh -Probe
just upgrade
```

The default doctor uses `Get-AppSourceReport` metadata and never invokes inspected
binaries. `-Probe` explicitly requests timeout-bounded version checks for a small
reviewed set of native commands with source evidence. It never installs, changes PATH,
or starts services. Access denied is reported as a launch failure unless the OS
specifically identifies a policy block. A passing version probe is not a full app test.

`just upgrade` / `upgrade-winget` update only selected, installed, approved catalog
entries. Missing packages are not installed. Component commands keep their owners;
unsupported adapters are reported. `upgrade-scoop` and the Scoop font installer refuse
to run in Microsoft mode. No failure retries by changing winget scope or source.

Installer progress is streamed with the exact package ID. A native Windows UAC
prompt can still pause an installer: `--silent` / `--disable-interactivity` do not
approve elevation. Confirm it on the Windows desktop under your IT policy; never
paste administrator credentials into an agent conversation. For unattended machine
packages, arrange the approved administrative deployment context beforehand.

Run-script summaries distinguish installed-but-unverified, preserved existing owner,
pending approval, unsupported, administrator-session-required and failed states.
Nonfatal apply completion does not mean every selected tool is usable.
