# 40_copilot.ps1 — load the Copilot proxy module (copilot-proxy, copilot-run,
# claude-copilot, copilot-here, copilot-model, copilot-embed, semsearch).
# The $PROFILE loader already put ~/.config/powershell/modules on PSModulePath.
#
# Import directly — a `Get-Module -ListAvailable` guard scans all of PSModulePath
# (slow, esp. under OneDrive-hydrated Documents\PowerShell\Modules); a missing
# module just no-ops here. -DisableNameChecking: the exported commands use
# hyphenated / unapproved-verb names (copilot-proxy, claude-copilot, …) by design,
# so silence the import warnings about unapproved verbs and restricted characters.
Import-Module Copilot -DisableNameChecking -ErrorAction SilentlyContinue
