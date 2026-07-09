# Microsoft.PowerShell_profile.ps1 — managed by chezmoi (Windows dotfiles).
#
# Thin loader: dot-sources every fragment in ~/.config/powershell/profile.d in
# sorted order, then the user's untracked local override. Keep logic in the
# fragments, not here — this file is intentionally boring.

$ConfigRoot  = Join-Path $HOME '.config/powershell'
$FragmentDir = Join-Path $ConfigRoot 'profile.d'
$ModuleDir   = Join-Path $ConfigRoot 'modules'

# Make chezmoi-managed modules importable (e.g. Copilot).
if (Test-Path $ModuleDir) {
    if (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $ModuleDir) {
        $env:PSModulePath = $ModuleDir + [System.IO.Path]::PathSeparator + $env:PSModulePath
    }
}

if (Test-Path $FragmentDir) {
    foreach ($fragment in Get-ChildItem -Path $FragmentDir -Filter '*.ps1' | Sort-Object Name) {
        try { . $fragment.FullName }
        catch { Write-Warning "profile.d: failed to load $($fragment.Name): $_" }
    }
}

# Untracked, user-local overrides (secrets, machine-specific tweaks).
$LocalProfile = Join-Path $ConfigRoot 'local.ps1'
if (Test-Path $LocalProfile) { . $LocalProfile }
