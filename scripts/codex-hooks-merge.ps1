# Canonicalize Codex lifecycle hooks into inline config.toml.

function ConvertTo-CodexEncodedCommand {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )

    $quotedPath = $ScriptPath.Replace("'", "''")
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("& '$quotedPath'")
    foreach ($argument in $ArgumentList) {
        $parts.Add("'$($argument.Replace("'", "''"))'")
    }
    $scriptText = $parts -join ' '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    return "powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded"
}

function ConvertTo-CodexTomlString {
    param([AllowEmptyString()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function New-CodexManagedHookBlock {
    param(
        [string]$HerdrScript,
        [string]$PeonAdapter,
        [string]$PeonDir,
        [bool]$EnablePeon,
        [string]$Newline = "`n"
    )

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# managed Codex hooks begin')
    if ($HerdrScript -and (Test-Path -LiteralPath $HerdrScript -PathType Leaf)) {
        $command = ConvertTo-CodexEncodedCommand -ScriptPath $HerdrScript -ArgumentList @('session')
        $lines.Add('# Herdr session reporting')
        $lines.Add('[[hooks.SessionStart]]')
        $lines.Add('matcher = "startup|resume|clear"')
        $lines.Add('')
        $lines.Add('[[hooks.SessionStart.hooks]]')
        $lines.Add('type = "command"')
        $lines.Add("command = $(ConvertTo-CodexTomlString $command)")
        $lines.Add("command_windows = $(ConvertTo-CodexTomlString $command)")
        $lines.Add('timeout = 10')
    }

    if ($EnablePeon -and $PeonAdapter -and (Test-Path -LiteralPath $PeonAdapter -PathType Leaf)) {
        $command = ConvertTo-CodexEncodedCommand -ScriptPath $PeonAdapter
        $events = @(
            @{ Name = 'SessionStart'; Matcher = 'startup|resume|clear' },
            @{ Name = 'UserPromptSubmit'; Matcher = $null },
            @{ Name = 'PermissionRequest'; Matcher = $null },
            @{ Name = 'PreCompact'; Matcher = 'manual|auto' },
            @{ Name = 'SubagentStart'; Matcher = $null },
            @{ Name = 'SubagentStop'; Matcher = $null },
            @{ Name = 'Stop'; Matcher = $null }
        )
        foreach ($event in $events) {
            $lines.Add('')
            $lines.Add("[[hooks.$($event.Name)]]")
            if ($event.Matcher) { $lines.Add("matcher = $(ConvertTo-CodexTomlString $event.Matcher)") }
            $lines.Add('')
            $lines.Add("[[hooks.$($event.Name).hooks]]")
            $lines.Add('type = "command"')
            $lines.Add("command = $(ConvertTo-CodexTomlString $command)")
            $lines.Add("command_windows = $(ConvertTo-CodexTomlString $command)")
            $lines.Add("env = { CLAUDE_PEON_DIR = $(ConvertTo-CodexTomlString $PeonDir) }")
            $lines.Add('timeout = 30')
        }
    }
    $lines.Add('')
    $lines.Add('# managed Codex hooks end')
    $lines.Add('')
    return ($lines -join $Newline)
}

function Test-CodexHooksToml {
    param([Parameter(Mandatory)][string]$Path)

    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { throw 'uv is required to validate the generated Codex TOML' }
    & $uv.Source run --no-project python -c 'import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $Path
    return ($LASTEXITCODE -eq 0)
}

function Test-CodexHooksFileOwnedByHerdr {
    param([Parameter(Mandatory)][string]$Path)

    try { $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Could not parse Codex hooks file ${Path}: $_" }
    $commands = @(
        $json.hooks.PSObject.Properties.Value |
            ForEach-Object { @($_) } |
            ForEach-Object { @($_.hooks) } |
            ForEach-Object { $_.command }
    ) | Where-Object { $_ }
    if ($commands.Count -eq 0) { return $true }
    return (@($commands | Where-Object { $_ -notmatch 'herdr-agent-state\.ps1' }).Count -eq 0)
}

function Sync-CodexHooks {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = (Join-Path $HOME '.codex\config.toml'),
        [string]$HooksPath = (Join-Path $HOME '.codex\hooks.json'),
        [string]$HerdrScript = (Join-Path $HOME '.codex\herdr-agent-state.ps1'),
        [string]$PeonDir = (Join-Path $HOME '.openpeon\hooks\peon-ping'),
        [bool]$EnablePeon = $false
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Warning "Codex config not found at $ConfigPath; skipping hook convergence"
        return $false
    }
    $peonAdapter = Join-Path $PeonDir 'adapters\codex.ps1'
    $raw = [IO.File]::ReadAllText($ConfigPath)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $oldPattern = '(?s)# peon-ping Codex hooks begin.*?# peon-ping Codex hooks end\s*'
    $managedPattern = '(?s)# managed Codex hooks begin.*?# managed Codex hooks end\s*'
    $withoutManaged = [regex]::Replace([regex]::Replace($raw, $oldPattern, ''), $managedPattern, '')
    $block = New-CodexManagedHookBlock -HerdrScript $HerdrScript -PeonAdapter $peonAdapter `
        -PeonDir $PeonDir -EnablePeon $EnablePeon -Newline $newline

    $insertAt = [regex]::Match($withoutManaged, '(?m)^\[tui\]\s*$')
    if ($insertAt.Success) { $updated = $withoutManaged.Insert($insertAt.Index, $block) }
    else { $updated = $withoutManaged.TrimEnd("`r", "`n") + $newline + $newline + $block }

    $retireHooks = $false
    if (Test-Path -LiteralPath $HooksPath -PathType Leaf) {
        if (-not (Test-CodexHooksFileOwnedByHerdr -Path $HooksPath)) {
            Write-Warning "Codex hooks.json contains foreign hooks; preserving both files instead of deleting user behavior"
            return $false
        }
        $retireHooks = $true
    }
    if ($updated -ceq $raw -and -not $retireHooks) { return $true }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $configBackup = "$ConfigPath.pre-inline-$stamp.bak"
    $hooksBackup = "$HooksPath.pre-inline-$stamp.bak"
    $temporary = "$ConfigPath.tmp-$stamp"
    Copy-Item -LiteralPath $ConfigPath -Destination $configBackup -ErrorAction Stop
    try {
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        if (-not (Test-CodexHooksToml -Path $temporary)) { throw 'Generated Codex hook config is invalid TOML' }
        [IO.File]::Move($temporary, $ConfigPath, $true)
        if ($retireHooks) { Move-Item -LiteralPath $HooksPath -Destination $hooksBackup -ErrorAction Stop }
        return $true
    } catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $configBackup -Destination $ConfigPath -Force
        if ($retireHooks -and -not (Test-Path -LiteralPath $HooksPath) -and (Test-Path -LiteralPath $hooksBackup)) {
            Copy-Item -LiteralPath $hooksBackup -Destination $HooksPath -Force
        }
        Write-Warning "Could not converge Codex hooks: $_"
        return $false
    }
}
