# 40_copilot.ps1 — load the Copilot proxy module (copilot-proxy, copilot-run,
# claude-copilot, copilot-here, copilot-model, copilot-embed, semsearch).
# The $PROFILE loader already put ~/.config/powershell/modules on PSModulePath.
if (Get-Module -ListAvailable -Name Copilot -ErrorAction SilentlyContinue) {
    Import-Module Copilot -ErrorAction SilentlyContinue
}
