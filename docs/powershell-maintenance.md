# PowerShell maintenance notes

This note records the September 2026 runtime/scope audit and the contract for
future scripts. This is a Windows dotfiles repository, not a promise to run every
script on Unix. Editing on Unix is supported through isolated rendering and tests.

## Two runtime boundaries

| Surface | Contract |
|---|---|
| `bootstrap.ps1` | Windows PowerShell 5.1-compatible syntax/APIs; probes the resolved target pwsh before chezmoi |
| Profiles, helpers, modifiers, run-scripts, tests | PowerShell 7.4+ Core |
| Module manifests | `PowerShellVersion = '7.4'`, `CompatiblePSEditions = @('Core')` |
| Vendored/generated third-party code and external hook commands | Follow their own contract; do not mechanically rewrite them |

Use these guards on new first-party scripts (after a shebang, if present):

```powershell
#Requires -Version 7.4
#Requires -PSEdition Core
```

7.4 establishes a common .NET 8 and modern native-argument baseline, rather than
allowing features to accidentally depend on whichever pwsh a developer has.
Bootstrap installs missing pwsh using the existing policy; it does not upgrade an
existing installation silently. It rejects versions below 7.4 with an upgrade hint.

`#Requires` checks the current host; it does **not** launch another interpreter.
The Windows `.ps1` extension and a Unix shebang do not select pwsh for you either.
An old parser may reject new syntax before producing a useful requirement error:
Windows PowerShell 5.1 still reports `&&` as invalid even under a 7.4 requirement.
Keep the bootstrap entirely 5.1-parseable and explicitly launch modern scripts
with pwsh. [Microsoft: about_Requires](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_requires).

### Template embedding

PowerShell rejects multiple `#Requires -PSEdition` directives in one parsed script.
Sources usable standalone keep their guards; an enclosing script strips only
the embedded edition directive:

```text
{{ include "scripts/example.ps1" | replace "#Requires -PSEdition Core" "# Core edition is required by the enclosing script." }}
```

Template-only fragments such as package-source policy inherit the enclosing
edition guard. Scripts embedded as **string data** for later execution keep their
own guard. Always render and parse the final output, not only each source file.

## Scope is part of the interface

Dot-sourcing a file inside a function does not make its functions global.
`reload`, `cas` and `cau` load the profile from function scope, so public shell
helpers and dependencies must explicitly survive that scope or live in a retained
module. The basic aliases/Git helpers now use explicit global definitions.

Cached tv/dev-cli/translate/pia initializers contain plain helper functions and
`$script:` state used by callbacks. They now execute in one retained named module
per tool, imported globally. Reload replaces only the matching managed module.
Prompt integrations that already implement their own global hooks remain on
their existing path. Do not regex-rewrite arbitrary upstream init code.

Tests must call helpers and complete a command **after the loader has returned**,
then reload again. An environment-variable-only test misses this bug. Keep
PSReadLine edit-mode reset before final key-handler registration. Do not globally
enable StrictMode or Stop in a user's shell; preserve non-fatal apply scripts.

## Native arguments and child environments

`& $exe @argv` and `Start-Process -ArgumentList $argv` are not interchangeable:
Start-Process serializes the array into one argument string. Prefer
`ProcessStartInfo.ArgumentList` for native `.exe` arguments when controlling a
child process; treat `.cmd`/`.bat` and shell expressions as a separate contract.
PowerShell's newer native argument handling still has Windows batch/legacy
exceptions. [Microsoft: about_Parsing](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing).

When choosing one executable, explicitly take the first result of
`Get-Command -CommandType Application`: on this multi-install host that query
returned several candidates even without `-All`. Do not cast the resulting
`.Source` array to a single process filename. The LazyGit regression test covers it.

WSL self-elevation now quotes its script path and selects the current pwsh by
absolute path. The hidden child is unattended and never waits for invisible
keyboard input; the parent gives status/retry guidance. Tests mock elevation.

Herdr's server is a native executable, not a PowerShell host. Normal panes use
the configured pwsh, while Windows custom commands go through `cmd /d /c` and
inherit server state. `prefix+G` now loads just the managed environment before
launching LazyGit with inherited terminal I/O. Failures keep cwd, paths and exit
status visible. Never stop a server just to refresh PATH: that exits pane processes.
Use [appsrc](appsrc.md) to compare installations without executing them.

## Audit outcomes and deferred work

- Shipped: runtime guards and manifest contract, completion retention, basic
  helper reload scope, quoted WSL elevation, LazyGit environment/error boundary,
  and read-only provenance inspection.
- Deferred by choice: `run-for` currently serializes arguments through
  Start-Process and terminates only the immediate process on timeout. Before
  changing it, define separate `.exe`, `.ps1`, batch-shim, exit-code and process-tree
  behavior; test spaces, embedded quotes, empty arguments and timeout cleanup.
- Other large profile fragments with private `script:` helpers deserve isolated
  reload tests before any scope refactor. No blanket module conversion was made.
- No automatic package removals, registry/PATH migration, terminal-emulator change,
  or speculative .NET/performance rewrite. Warm initialization caching stays.

Validation: `PowerShellRuntime`, `PowerShellInitCache`, `AppSource`, `Bootstrap`,
`GitAliases` and `HerdrLazyGit` Pester tests, existing full suite, PSScriptAnalyzer,
isolated chezmoi render/parse and strict bilingual docs build. CI checks a 7.4
maintenance release in addition to its normal current-pwsh job.
