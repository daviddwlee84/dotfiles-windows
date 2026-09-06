#Requires -Version 7.4
#Requires -PSEdition Core
# Invoked as a standalone process, never dot-sourced or captured in a pipeline.
# Only the resolver's existing batch executable and explicit argv arrive here.
$PSNativeCommandUseErrorActionPreference = $false
$command = $args[0]
$forward = @($args | Select-Object -Skip 1)
& $command @forward
exit $LASTEXITCODE
