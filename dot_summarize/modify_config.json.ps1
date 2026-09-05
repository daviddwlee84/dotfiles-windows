#!/usr/bin/env pwsh
#Requires -Version 7.4
#Requires -PSEdition Core
# chezmoi modify_ script: deep-merge a managed overlay into ~/.summarize/config.json.
# Runs under [interpreters.ps1] in .chezmoi.toml.tmpl; chezmoi pipes the CURRENT target
# file in on stdin and takes the new contents from stdout, and strips the `.ps1`
# interpreter suffix when resolving the target name.
#
# WHY THE PATH IS NOT XDG: summarize hardcodes ~/.summarize/config.json. There is no
# XDG lookup and no SUMMARIZE_CONFIG override, so the profile-root path is the only
# one the tool reads. No junction/symlink is used (invariant 6).
#
# WHY AN OVERLAY AND NOT A PLAIN MANAGED FILE: summarize is a second writer.
# `summarize refresh-free` rewrites the OpenRouter free-model presets into this file
# and `--set-default` persists a model choice; a plain file would clobber both on every
# apply. Counterpart of the parent repo's dot_summarize/modify_config.json (jq).
#
# MERGE MODEL — live file as base, overlay leaves win:
#   - Every live key survives unless the overlay names it.
#   - Nested objects merge recursively; scalars and arrays are replaced wholesale.
#   - Property order of the live file is preserved (PSCustomObject, not a hashtable),
#     so re-applies are byte-stable instead of reshuffling the user's config.
#
# WHY `prompt` IS NOT IN THE OVERLAY: the top-level `prompt` key REPLACES summarize's
# built-in summary instructions for EVERY source type. Per-source prompts go through
# --prompt-file — see dot_config/summarize/prompts/.
#
# Every failure path emits the original stdin bytes unchanged: config recovery must be
# explicit, never an accidental overwrite.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$overlayJson = @'
{
  "output": {
    "language": "zh-TW",
    "length": "medium"
  }
}
'@

function Write-StdoutBytes {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    $out = [Console]::OpenStandardOutput()
    $out.Write($Bytes, 0, $Bytes.Length)
    $out.Flush()
}

function Write-PreservedInput {
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    [Console]::Error.WriteLine("modify_config.json: $Message; preserving live config unchanged")
    Write-StdoutBytes -Bytes $Bytes
}

function Test-StartsWithUtf8Bom {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes
    )

    return $Bytes.Length -ge 3 -and
    $Bytes[0] -eq 0xEF -and
    $Bytes[1] -eq 0xBB -and
    $Bytes[2] -eq 0xBF
}

function Test-JsonObject {
    param($Value)

    return $null -ne $Value -and $Value -is [System.Management.Automation.PSCustomObject]
}

function Merge-JsonObject {
    param(
        [Parameter(Mandatory)] $Base,
        [Parameter(Mandatory)] $Overlay
    )

    foreach ($property in $Overlay.PSObject.Properties) {
        $existing = $Base.PSObject.Properties[$property.Name]

        if ($null -eq $existing) {
            $Base | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
            continue
        }

        if ((Test-JsonObject -Value $existing.Value) -and (Test-JsonObject -Value $property.Value)) {
            Merge-JsonObject -Base $existing.Value -Overlay $property.Value
            continue
        }

        # Scalars and arrays: the overlay wins wholesale.
        $existing.Value = $property.Value
    }
}

function ConvertTo-OutputBytes {
    param([Parameter(Mandatory)] $Object)

    # Depth must clear summarize's nested `models`/`cli`/`speakers` presets; the default
    # of 2 would silently serialise them as type names. LF endings + no BOM keep the
    # file byte-identical to what the parent repo's jq overlay produces.
    $text = ($Object | ConvertTo-Json -Depth 64).Replace("`r`n", "`n")
    return ([System.Text.UTF8Encoding]::new($false)).GetBytes($text + "`n")
}

$inputBuffer = [System.IO.MemoryStream]::new()
try {
    try {
        [Console]::OpenStandardInput().CopyTo($inputBuffer)
        [byte[]] $originalBytes = $inputBuffer.ToArray()
    }
    catch {
        [byte[]] $originalBytes = $inputBuffer.ToArray()
        Write-PreservedInput -Message "could not read stdin bytes: $($_.Exception.Message)" -Bytes $originalBytes
        return
    }
}
finally {
    $inputBuffer.Dispose()
}

# Keep the original byte array immutable. Parsing gets a copy with at most one leading
# UTF-8 BOM removed; successful output is always newly encoded instead.
[byte[]] $parseBytes = [byte[]]::new($originalBytes.Length)
[System.Array]::Copy($originalBytes, $parseBytes, $originalBytes.Length)
if (Test-StartsWithUtf8Bom -Bytes $parseBytes) {
    [byte[]] $withoutBom = [byte[]]::new($parseBytes.Length - 3)
    if ($withoutBom.Length -gt 0) {
        [System.Array]::Copy($parseBytes, 3, $withoutBom, 0, $withoutBom.Length)
    }
    $parseBytes = $withoutBom
}

$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
try {
    $liveText = $strictUtf8.GetString($parseBytes)
}
catch [System.Text.DecoderFallbackException] {
    Write-PreservedInput -Message "stdin is not valid UTF-8: $($_.Exception.Message)" -Bytes $originalBytes
    return
}

try {
    $overlay = $overlayJson | ConvertFrom-Json
}
catch {
    Write-PreservedInput -Message "the embedded overlay is not valid JSON: $($_.Exception.Message)" -Bytes $originalBytes
    return
}

# Cold start: no file yet, or an empty/whitespace-only one. Emit the overlay as-is.
if ([string]::IsNullOrWhiteSpace($liveText)) {
    Write-StdoutBytes -Bytes (ConvertTo-OutputBytes -Object $overlay)
    return
}

try {
    $live = $liveText | ConvertFrom-Json
}
catch {
    Write-PreservedInput -Message "stdin is not valid JSON: $($_.Exception.Message)" -Bytes $originalBytes
    return
}

if (-not (Test-JsonObject -Value $live)) {
    Write-PreservedInput -Message 'stdin is valid JSON but not an object' -Bytes $originalBytes
    return
}

try {
    Merge-JsonObject -Base $live -Overlay $overlay
    [byte[]] $mergedBytes = ConvertTo-OutputBytes -Object $live
}
catch {
    Write-PreservedInput -Message "merge failed: $($_.Exception.Message)" -Bytes $originalBytes
    return
}

Write-StdoutBytes -Bytes $mergedBytes
