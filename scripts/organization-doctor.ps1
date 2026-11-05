#Requires -Version 7.4
#Requires -PSEdition Core
[CmdletBinding()]
param([switch]$Json, [switch]$Probe, [string[]]$Tool, [ValidateSet('none', 'microsoft')][string]$OrganizationProfile,
    [ValidateRange(1, 30)][int]$TimeoutSeconds = 5)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'organization-policy.ps1')
$policy = Import-OrganizationPolicyData
if ($OrganizationProfile) {
    # Read-only preview; never persist or activate this choice in the shell.
    $policy.Data['organizationProfile'] = $OrganizationProfile
    Initialize-OrganizationPolicy -Data $policy.Data -Catalog $policy.Catalog
    $policy = Get-OrganizationPolicy
}
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'dot_config\powershell\modules\AppSource\AppSource.psm1') -Force
# One metadata scan, never one package-manager invocation per tool.
$inventory = Get-AppSourceReport
$selected = @(Get-OrganizationSelectedTools)
$inspected = if ($Tool) { @($policy.Catalog.tools | Where-Object id -In $Tool) } else { $selected }
$rows = @(
    foreach ($entry in $inspected) {
        if ($Tool -and $entry.id -notin $Tool) { continue }
        $decision = Get-OrganizationSourceDecision -Id $entry.id -Operation execute
        $name = @($entry.commands)[0]
        $group = $inventory.Groups | Where-Object Name -EQ $name | Select-Object -First 1
        $path = $null
        if ($name) {
            try {
                $path = if ($name -eq 'node') { Resolve-OrganizationNode } elseif ($name -eq 'pwsh' -and $policy.Data['powerShellExecutable']) {
                    Resolve-OrganizationCommand -Name pwsh -ExplicitPath $policy.Data['powerShellExecutable']
                } elseif ($name -eq 'python') { Resolve-OrganizationPython }
                else { Resolve-OrganizationCommand $name }
            } catch { $path = $null }
        }
        $candidate = @($group.Candidates | Where-Object Path -EQ $path) | Select-Object -First 1
        $state = if (-not $decision.Allowed) { $decision.State } elseif ($path) { 'unverified' } else { 'not-discovered' }
        $detail = $decision.Reason
        # Only bounded, known read-only native probes. Never execute arbitrary wrappers.
        $probeIds = @('pwsh', 'git', 'chezmoi', 'nodejs-lts', 'bun', 'uv', 'python', 'just', 'lazygit', 'starship')
        $knownSource = $candidate -and $candidate.Manager -in 'WinGet', 'RegisteredInstaller', 'AppExecutionAlias'
        if ($path -and ($path -eq $policy.Data['nodeExecutable'] -or $path -eq $policy.Data['powerShellExecutable'] -or $path -eq $policy.Data['pythonExecutable'])) { $knownSource = $true }
        if ($Probe -and $decision.Allowed -and $path -and $knownSource -and $entry.id -in $probeIds -and [IO.Path]::GetExtension($path) -eq '.exe') {
            $process = [Diagnostics.Process]::new()
            try {
                $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($path)
                $process.StartInfo.UseShellExecute = $false
                $process.StartInfo.CreateNoWindow = $true
                $process.StartInfo.RedirectStandardOutput = $true
                $process.StartInfo.RedirectStandardError = $true
                $process.StartInfo.ArgumentList.Add('--version')
                $null = $process.Start()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    $process.Kill($true); $process.WaitForExit()
                    $state = 'probe-timeout'; $detail = 'Process terminated after the explicit probe timeout.'
                } else {
                    $state = if ($process.ExitCode -eq 0) { 'version-probe-passed' } else { 'probe-failed' }
                    $detail = (($stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()).Trim())
                }
            } catch {
                $state = 'launch-failed'; $detail = $_.Exception.Message
                $cause = $_.Exception
                while ($cause.InnerException) { $cause = $cause.InnerException }
                if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1260) { $state = 'policy-blocked' }
            } finally { $process.Dispose() }
        } elseif ($Probe -and $state -eq 'unverified') {
            $detail = 'No reviewed probe/source evidence; candidate was not executed.'
        }
        [pscustomobject]@{
            Tool = $entry.id; State = $state; Path = $path; Source = $entry.provider
            Owner = $candidate.Manager; Confidence = $candidate.Confidence
            ProcessPathCandidate = $group.ProcessPathCandidate
            PersistedPathCandidate = $group.PersistedPathCandidate
            ScoopCandidates = @($group.Candidates | Where-Object { Test-OrganizationScoopPath $_.Path } | Select-Object -ExpandProperty Path)
            Detail = $detail
        }
    }
)
$report = [pscustomobject]@{
    Profile = $policy.Profile; ManagedMachine = [bool]$policy.Data['managedMachine']
    Architecture = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    ProbeRequested = [bool]$Probe
    Note = 'Source evidence is not IT approval; a version probe is not a full application test. Persisted PATH is a simulation, not a running Herdr/GUI environment.'
    Warnings = $inventory.Warnings; Tools = $rows
}
if ($Json) { $report | ConvertTo-Json -Depth 10 }
else {
    Write-Host "Organization: $($report.Profile); OS architecture: $($report.Architecture); managed feeds: $($report.ManagedMachine)"
    Write-Host $report.Note
    $rows | Format-Table Tool, State, Source, Path, Detail -Wrap
}
