@{
    RootModule        = 'Copilot.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7e6f2a1-9c4d-4e2b-8a5f-3d1c0e7a6b40'
    Author            = 'Da-Wei Lee'
    Description       = 'GitHub Copilot -> Anthropic proxy for Claude Code (copilot-proxy tool series).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'copilot-proxy', 'copilot-run', 'claude-copilot', 'claude-copilot-once',
        'copilot-here', 'copilot-model', 'copilot-embed', 'semsearch'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
