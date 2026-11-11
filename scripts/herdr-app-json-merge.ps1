#Requires -Version 7.4
#Requires -PSEdition Core
# Merge engine for the Herdr App modify_ overlays (keys.json / settings.json).
# Inlined into dot_config/herdr-app/modify_*.json.ps1.tmpl via {{ include }} and
# dot-sourced by tests/HerdrAppOverlay.Tests.ps1.
#
# Same semantics as the parent repo's sh+jq overlays:
#   - empty / whitespace-only live file -> empty output (Herdr then writes its
#     full defaults on first start; a file holding only our fragment would
#     replace them). chezmoi leaves a missing target absent.
#   - otherwise deep-merge the managed fragment: objects merge recursively,
#     the fragment wins for scalars/arrays, every other key is preserved in
#     its original order.
#   - invalid live JSON (or any failure) -> the original bytes, unchanged.

function Merge-HerdrAppJsonObject {
    param([Parameter(Mandatory)] $Base, [Parameter(Mandatory)] $Overlay)
    foreach ($property in $Overlay.PSObject.Properties) {
        $existing = $Base.PSObject.Properties[$property.Name]
        if ($null -eq $existing) {
            $Base | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        } elseif ($existing.Value -is [System.Management.Automation.PSCustomObject] -and
            $property.Value -is [System.Management.Automation.PSCustomObject]) {
            Merge-HerdrAppJsonObject -Base $existing.Value -Overlay $property.Value
        } else {
            $existing.Value = $property.Value
        }
    }
}

function Get-HerdrAppMergedJson {
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $InputBytes,
        [Parameter(Mandatory)][string] $OverlayJson
    )
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($InputBytes).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($text)) { return , [byte[]]@() }
        $live = $text | ConvertFrom-Json -ErrorAction Stop
        if ($live -isnot [System.Management.Automation.PSCustomObject]) { return , $InputBytes }
        $overlay = $OverlayJson | ConvertFrom-Json -ErrorAction Stop
        Merge-HerdrAppJsonObject -Base $live -Overlay $overlay
        $out = ($live | ConvertTo-Json -Depth 64).Replace("`r`n", "`n")
        return , ([System.Text.UTF8Encoding]::new($false)).GetBytes($out + "`n")
    } catch {
        [Console]::Error.WriteLine("herdr-app overlay: $($_.Exception.Message); preserving live file unchanged")
        return , $InputBytes
    }
}

function Invoke-HerdrAppJsonModify {
    param([Parameter(Mandatory)][string] $OverlayJson)
    $buffer = [System.IO.MemoryStream]::new()
    try {
        [Console]::OpenStandardInput().CopyTo($buffer)
        [byte[]] $bytes = Get-HerdrAppMergedJson -InputBytes $buffer.ToArray() -OverlayJson $OverlayJson
    } finally {
        $buffer.Dispose()
    }
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
