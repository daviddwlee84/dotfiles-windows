#Requires -Version 7.4
#Requires -PSEdition Core
# 40_copilot.ps1 — load the Copilot proxy module (copilot-proxy, copilot-run,
# claude-copilot, copilot-here, copilot-model, copilot-embed, semsearch).
# The $PROFILE loader already put ~/.config/powershell/modules on PSModulePath.
#
# Import directly — a `Get-Module -ListAvailable` guard scans all of PSModulePath
# (slow, esp. under OneDrive-hydrated Documents\PowerShell\Modules); a missing
# module just no-ops here. -DisableNameChecking: the exported commands use
# hyphenated / unapproved-verb names (copilot-proxy, claude-copilot, …) by design,
# so silence the import warnings about unapproved verbs and restricted characters.
# -Force is required because `reload` dot-sources $PROFILE in the same process.
# Without it, PowerShell keeps the old module scriptblocks even after chezmoi has
# deployed a fixed Copilot.psm1, which made `copilot-proxy auth` repeat the old
# ETARGET-only installer until the entire terminal was restarted.
Import-Module Copilot -Force -DisableNameChecking -ErrorAction SilentlyContinue
