#Requires -Version 7
# run_onchange_after_02_profile_redirect.ps1 — make sure pwsh actually loads the
# managed $PROFILE.
#
# chezmoi writes the loader to the LITERAL ~/Documents/PowerShell/Microsoft.
# PowerShell_profile.ps1. But when OneDrive "Known Folder Move" is enabled (very
# common on Windows), pwsh resolves $PROFILE under ~/OneDrive/Documents/
# PowerShell/... instead — so the managed profile silently never loads: no
# starship, no aliases, just the bare `PS C:\...>` prompt.
#
# We can't know that redirected path at apply time, but THIS script runs under
# pwsh, so $PROFILE here is exactly what an interactive pwsh computes. If it
# differs from the managed file, drop a one-line stub there that dot-sources the
# managed loader. Pure no-op when Documents isn't redirected.
#
# Fault-tolerant per the repo invariant: never abort the apply.
$ErrorActionPreference = 'Continue'

$managed = Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
$real    = $PROFILE   # CurrentUserCurrentHost — OneDrive-aware

try {
    $managedFull = [System.IO.Path]::GetFullPath($managed)
    $realFull    = if ($real) { [System.IO.Path]::GetFullPath([string]$real) } else { '' }

    if ($realFull -and ($realFull -ine $managedFull)) {
        $dir = Split-Path $realFull -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

        # Preserve any PRE-EXISTING real profile before we overwrite it — the
        # run_once_before backup only guards the literal ~/Documents path, not
        # this OneDrive-redirected one. Skip if it's already our own stub.
        $marker = 'Auto-written by chezmoi (dotfiles-windows)'
        if (Test-Path -LiteralPath $realFull) {
            $existing = Get-Content -LiteralPath $realFull -Raw -ErrorAction SilentlyContinue
            if ($existing -and ($existing -notmatch [regex]::Escape($marker))) {
                $backupDir = Join-Path $HOME '.dotfiles-backup'
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $bak = Join-Path $backupDir 'Microsoft.PowerShell_profile.ps1.onedrive.bak'
                if (-not (Test-Path -LiteralPath $bak)) {
                    Copy-Item -LiteralPath $realFull -Destination $bak -Force
                    Write-Host "==> backed up existing profile -> $bak" -ForegroundColor Cyan
                }
            }
        }

        $stub = "# Auto-written by chezmoi (dotfiles-windows). Your Documents folder is`n" +
                "# OneDrive-redirected, so pwsh looks here instead of ~/Documents. Load the`n" +
                "# real managed profile:`n" +
                ". `"$managedFull`"`n"
        Set-Content -LiteralPath $realFull -Value $stub -Encoding utf8
        Write-Host "==> Wrote profile redirect stub -> $realFull" -ForegroundColor Cyan
    } else {
        Write-Host '==> $PROFILE points at the managed loader (no redirect needed)' -ForegroundColor DarkGray
    }
} catch {
    Write-Warning "profile redirect stub failed (non-fatal): $_"
}
