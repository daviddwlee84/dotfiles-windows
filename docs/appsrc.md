# CLI sources and conflicts

`appsrc` answers **which copy will this shell use, what evidence identifies its
source, and what other copies exist?** It is native PowerShell 7.4+, with no
Python dependency. The interface borrows from the parent repo's
[`appsrc`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_dotfiles/bin/executable_appsrc),
but this version is intentionally CLI-only: no GUI inventory, disk sizing or TUI.

## Usage

```powershell
appsrc lazygit                       # same as: appsrc which lazygit
appsrc git
appsrc which -Path 'C:\Program Files\Git\cmd\git.exe'
appsrc scan                         # no arguments also means scan
appsrc scan -Conflicts
$report = appsrc scan -Conflicts -Json | ConvertFrom-Json
$report.Groups | Select-Object Name, Installations, Findings
```

The profile only registers a lazy wrapper: no inventory runs at shell startup.
For a no-profile diagnostic, explicitly import
`~/.config/powershell/modules/AppSource/AppSource.psd1`, then call
`Invoke-AppSource` (same arguments) or `Get-AppSourceReport -Name git` (objects).
The latter does not change PATH to emulate the profile; it reports its own process.

## Reading the result

- **Resolution** is PowerShell's current command lookup, including loaded aliases,
  functions and cmdlets. Function bodies are not printed; discovery does not
  auto-import arbitrary modules. Alias targets are names, not evidence of an
  independently installed executable.
- **ProcessPathCandidate** is a PATH-only candidate, excluding shell wrappers.
  **PersistedPathCandidate** simulates Machine PATH followed by User PATH. Neither
  is a measurement of the environment of an already running IDE/GUI/Herdr server;
  explicit-path callers and `cmd.exe` lookup can also differ.
- **Candidates** retain distinct `.exe`, `.cmd`, `.ps1` and physical paths.
  **Installations** deduplicates known package copies, links and recognized shims.
  Version strings come from package metadata, registered installation metadata or
  PE resources—not by executing `--version`. An unavailable version stays empty.
- **Confidence/Evidence** distinguish direct manifest/file evidence from known
  directory heuristics. Chocolatey binary shim targets are inferred only when a
  unique same-name executable appears in package snapshots. An Uninstall registry
  entry does not establish that winget or Chocolatey installed it.
- **Findings** include multiple installations, process/persisted PATH disagreement,
  shell wrappers and unavailable targets. A virtual environment's
  `ExpectedOverride=true`, Windows system copy, or intentional alias is not a
  recommendation to delete anything. Different versions are not automatically
  described as vulnerable or outdated; no online release query is performed.

## Safety and limitations

This is a read-only local diagnostic. It does not invoke candidate programs,
activate Windows Store aliases, evaluate shim scripts, run package managers,
uninstall anything, or modify registry/PATH. It inspects PATH directories and
known manager metadata, not the entire disk. UNC PATH directories are skipped;
individual metadata reads are capped at 2 MiB. Missing managers, stale package
records, inaccessible directories and broken links produce partial results.
JSON contains its warnings; text mode prints them separately.

Scoop/Chocolatey receive package-aware inspection (including custom roots).
WinGet links, standard npm shims, uv/pipx, Cargo, .NET tools and Windows locations
receive the evidence available locally. Custom launchers or install roots may
remain unknown; do not infer ownership from an executable's name alone.

## Before removing an old installation

The September 2026 machine audit found parallel Scoop/Chocolatey LazyGit, Git,
fzf and glow installations, plus separate Node/Python locations. Shell PATH
normalization can hide this from an interactive pwsh while a long-lived server
still uses an older executable. Herdr's dedicated `prefix+G` launcher addresses
that environment boundary; see [Shell](shell.md).

Use `appsrc <command>` in the affected environment first. Before uninstalling,
verify package ownership, dependencies, services, scheduled tasks, explicit paths
and configuration. Git distributions can differ in system TLS/credential settings;
OpenSSH may own a service. Keep Chocolatey-only tools until replacements are
verified. This release deliberately performs no cleanup automatically.
