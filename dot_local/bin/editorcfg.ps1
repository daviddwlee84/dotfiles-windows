#Requires -Version 7.4
#Requires -PSEdition Core
$configRoot = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
Import-Module (Join-Path $configRoot 'powershell/modules/EditorConfig/EditorConfig.psd1') -ErrorAction Stop
exit (Invoke-EditorConfig -CommandArguments $args)
