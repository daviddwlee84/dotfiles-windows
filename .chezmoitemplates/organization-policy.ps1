{{ include "scripts/organization-policy.ps1" | replace "#Requires -PSEdition Core" "# Core edition is required by the enclosing script." }}
$organizationData = @'
{{ pick . "organizationProfile" "organizationSourceApprovals" "nodeExecutable" "powerShellExecutable" "pythonExecutable" "managedMachine" "allowPublicPackageFallback" "installCodingAgents" "installSpecstoryBuild" "installWindowsApps" "installUtilityApps" "installGamingApps" "installExtraRuntimes" "installMediaTools" "installLlmTools" "installSummarize" "installTunnelTools" "installIacTools" "installSshServer" "installHerdr" "installClink" "installTry" "installPersonalTools" "installTranslate" "installInputMethod" "installWsl" "installWslUbuntu" | toJson }}
'@ | ConvertFrom-Json -AsHashtable
$organizationCatalog = @'
{{ include ".chezmoidata/windows-tool-sources.json" }}
'@ | ConvertFrom-Json -AsHashtable
Initialize-OrganizationPolicy -Data $organizationData -Catalog $organizationCatalog.windowsToolSources
