# PSScriptAnalyzer configuration for this repo.
#
# Rationale for the exclusions (all deliberate for a PowerShell 7 target):
#   PSAvoidUsingWriteHost                 - user-facing status output is intended
#   PSAvoidUsingInvokeExpression          - tool init: `iex (&starship init ...)`
#   PSUseShouldProcessForStateChangingFunctions - these are shell helpers, not cmdlets
#   PSUseApprovedVerbs                    - hyphenated names (copilot-proxy) are the
#                                           public API, kept for muscle memory
#   PSUseBOMForUnicodeEncodedFile         - we target pwsh 7 (UTF-8 by default); no BOM
#   PSUseSingularNouns                    - a few private helpers return collections
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingInvokeExpression',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseApprovedVerbs',
        'PSUseBOMForUnicodeEncodedFile',
        'PSUseSingularNouns'
    )
}
