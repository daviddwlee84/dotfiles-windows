#Requires -Version 7.4
#Requires -PSEdition Core
# LazyGit captures its copy command's stdout. Write OSC 52 to the pane console
# so the Herdr client currently viewing the pane receives the clipboard write.
param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

if (-not $env:HERDR_ENV) {
    Set-Clipboard -Value $Text
    return
}

$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
$sequence = [Text.Encoding]::ASCII.GetBytes("$([char]27)]52;c;$payload$([char]7)")
$console = [IO.File]::Open('\\.\CONOUT$', [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
try {
    $console.Write($sequence, 0, $sequence.Length)
    $console.Flush()
} finally {
    $console.Dispose()
}
