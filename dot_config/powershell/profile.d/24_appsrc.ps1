#Requires -Version 7.4
#Requires -PSEdition Core
# No inventory or module scan on profile startup. Resolve the managed module
# explicitly so a similarly named installed module cannot replace this helper.
function global:appsrc {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Command = 'scan',
        [Parameter(Position = 1)][string]$Name,
        [string]$Path,
        [switch]$Conflicts,
        [switch]$Json
    )
    $manifest = Join-Path $HOME '.config/powershell/modules/AppSource/AppSource.psd1'
    Import-Module $manifest -Global -ErrorAction Stop
    AppSource\Invoke-AppSource @PSBoundParameters
}
