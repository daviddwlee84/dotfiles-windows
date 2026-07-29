# Merge engine for the managed ~/.gitconfig overlay.
#
# Dot-source it in tests; it is also embedded verbatim into
# modify_dot_gitconfig.ps1.tmpl via `{{ include }}` -- the same idiom the
# editors overlay uses (editors/ is chezmoi-ignored but inlined at render time).
# Keeping it a real .ps1 is what makes the merge unit-testable without running
# chezmoi at all.
#
# MERGE MODEL -- the inverse of the parent repo's modify_dot_gitconfig.tmpl.
# The parent preserves ONLY [credential "..."] blocks and replaces everything
# else with its baseline. Here the baseline OWNS a fixed set of section+key
# pairs, and every other key found in the live file is pulled through
# untouched. The parent's allowlist would silently drop [otel "trace2"] and any
# section corp tooling adds later; a deny-by-default overlay cannot.
#
# Consequence worth knowing: a wrong value hand-set in a NON-managed key is
# preserved forever and `chezmoi diff` stays clean. This overlay is not a
# linter. To retire such a key, add it to the baseline (which then owns it).

Set-StrictMode -Version Latest

function ConvertFrom-GitConfigText {
    <#
    .SYNOPSIS
        Flatten gitconfig INI text into Section/Key/Line records.
    .DESCRIPTION
        Section is the raw header text, so [filter "lfs"] and [credential "x"]
        keep their subsection. Comments and blank lines are dropped; malformed
        lines are skipped rather than throwing, because this must never fail an
        apply.
    #>
    param([string]$Text)

    $entries = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return , $entries }

    $section = ''
    foreach ($raw in ($Text -split "`r?`n")) {
        $trimmed = $raw.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }

        if ($trimmed.StartsWith('[')) {
            $close = $trimmed.IndexOf(']')
            if ($close -lt 1) { continue }
            $section = $trimmed.Substring(1, $close - 1).Trim()
            continue
        }

        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $trimmed.Substring(0, $eq).Trim()
        if ($key.Length -eq 0) { continue }

        $entries.Add([pscustomobject]@{
                Section = $section
                Key     = $key
                Line    = $trimmed
            })
    }

    return , $entries
}

function Merge-GitConfig {
    <#
    .SYNOPSIS
        Emit the baseline, then carry over every live key the baseline does not own.
    #>
    param(
        [Parameter(Mandatory)][string]$BaselineText,
        [string]$LiveText = ''
    )

    $managed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in (ConvertFrom-GitConfigText -Text $BaselineText)) {
        [void]$managed.Add("$($entry.Section)`0$($entry.Key)")
    }

    # Ordered so carried-over sections keep the order they had in the live file,
    # which keeps the output stable across applies.
    #
    # CASE-SENSITIVE ON PURPOSE. `[ordered]@{}` compares keys case-INsensitively,
    # which silently collapses [credential "azrepos:org/O365Exchange"] into
    # [credential "azrepos:org/o365exchange"] -- two genuinely different
    # credential contexts, since git treats the quoted subsection as
    # case-sensitive. Merging them would hand one org's credentials to another.
    $carry = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    foreach ($entry in (ConvertFrom-GitConfigText -Text $LiveText)) {
        if ($managed.Contains("$($entry.Section)`0$($entry.Key)")) { continue }
        if (-not $carry.Contains($entry.Section)) {
            $carry[$entry.Section] = [System.Collections.Generic.List[string]]::new()
        }
        $carry[$entry.Section].Add($entry.Line)
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((($BaselineText -replace "`r`n", "`n").TrimEnd("`n")))
    [void]$sb.Append("`n")

    foreach ($section in $carry.Keys) {
        [void]$sb.Append("`n[$section]`n")
        foreach ($line in $carry[$section]) {
            # Normalize indentation to a tab so re-running over our own output
            # is byte-stable (idempotency).
            [void]$sb.Append("`t$line`n")
        }
    }

    return $sb.ToString()
}
