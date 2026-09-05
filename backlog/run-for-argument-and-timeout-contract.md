# run-for argument and timeout contract

Status: deferred
Date: 2026-09-05

The user selected conservative PowerShell maintenance: fix runtime contracts,
completion scope and WSL quoting now, leave run-for behavior unchanged.

`profile.d/20_aliases.ps1` currently calls Start-Process with an argument array,
which is joined into one command line. Spaces, empty arguments and embedded
quotes need dedicated handling. Timeout uses `Kill()` on the immediate child,
not a defined process-tree policy; numeric bounds and propagated exit status
also need a contract.

Before implementing, choose and document behavior for native exe, PowerShell
scripts, and npm-style cmd/bat shims separately. Avoid presenting cmd serialization
as arbitrary-argv safe. Test paths with spaces, Unicode, quotes, empty arguments,
batch metacharacters, normal/nonzero exits and timeout descendants. Keep shell
functions/shell expressions outside the native-executable contract unless an
explicit shell mode is designed. See docs/powershell-maintenance.md for the audit.
