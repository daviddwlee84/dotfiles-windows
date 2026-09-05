#Requires -Version 7.4
#Requires -PSEdition Core
# Shared process-only PATH precedence for profile and no-profile package runs.
# This file reads persisted PATH values but never writes them; its only mutation
# is the current process's $env:PATH.

function ConvertTo-WindowsPathEntries {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PathValues
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($value in $PathValues) {
        $expandedValue = [Environment]::ExpandEnvironmentVariables([string]$value)
        foreach ($entry in ($expandedValue -split ';')) {
            $candidate = $entry.Trim()
            if ($candidate -and $seen.Add($candidate)) {
                $candidate
            }
        }
    }
}

function Set-WindowsPathPrecedence {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProcessPath = $env:PATH,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ManagedPaths = @(),

        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User'),

        [AllowNull()]
        [AllowEmptyString()]
        [string]$MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    )

    $processEntries = @(ConvertTo-WindowsPathEntries -PathValues $ProcessPath)
    $managedEntries = @(ConvertTo-WindowsPathEntries -PathValues $ManagedPaths)
    $userEntries = @(ConvertTo-WindowsPathEntries -PathValues $UserPath)
    $machineEntries = @(ConvertTo-WindowsPathEntries -PathValues $MachinePath)

    $persisted = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in @($userEntries) + @($machineEntries)) {
        $null = $persisted.Add($entry)
    }

    $managed = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $managedEntries) {
        $null = $managed.Add($entry)
    }

    $processOnlyEntries = @($processEntries | Where-Object {
        -not $persisted.Contains($_) -and -not $managed.Contains($_)
    })
    $orderedEntries = @(
        $processOnlyEntries
        $managedEntries
        $userEntries
        $machineEntries
    )

    $env:PATH = @(ConvertTo-WindowsPathEntries -PathValues ($orderedEntries -join ';')) -join ';'
}
