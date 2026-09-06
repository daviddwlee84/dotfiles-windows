#Requires -Version 7.4
#Requires -PSEdition Core
[IO.File]::WriteAllText($env:EDITOR_TEST_LOG, (ConvertTo-Json -InputObject @($args) -Compress))
Start-Sleep -Milliseconds 100
[IO.File]::WriteAllText($env:EDITOR_TEST_CLOSED, (Get-Location).Path)
exit 23
