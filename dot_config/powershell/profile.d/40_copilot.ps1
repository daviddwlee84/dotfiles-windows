# 40_copilot.ps1 — load the Copilot proxy module (copilot-proxy, copilot-run,
# claude-copilot, copilot-here, copilot-model, copilot-embed, semsearch).
# The $PROFILE loader already put ~/.config/powershell/modules on PSModulePath.
if (Get-Module -ListAvailable -Name Copilot -ErrorAction SilentlyContinue) {
    # -DisableNameChecking: the exported commands use hyphenated / unapproved-verb
    # names (copilot-proxy, claude-copilot, …) by design, so silence the import
    # warnings about unapproved verbs and restricted characters.
    Import-Module Copilot -DisableNameChecking -ErrorAction SilentlyContinue
}
