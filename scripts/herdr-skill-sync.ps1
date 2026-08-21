# Shared Herdr agent-skill synchronizer.
#
# The installed binary is the version authority. `herdr --skill` emits the
# official skill compiled for that release, avoiding drift from a Git branch.

function Resolve-HerdrExecutable {
    $command = Get-Command herdr -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    if ($env:LOCALAPPDATA) {
        $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    }
    return $null
}

function Get-HerdrSkillContent {
    param([Parameter(Mandatory)][string]$HerdrPath)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $HerdrPath
    $start.ArgumentList.Add('--skill')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($process.ExitCode -ne 0) {
        $detail = $stderr.Trim()
        if (-not $detail) { $detail = "exit $($process.ExitCode)" }
        throw "herdr --skill failed: $detail"
    }
    return $stdout
}

function Write-HerdrSkillContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string[]]$Destinations
    )

    if ($Content -notmatch '\A---\r?\n' -or $Content -notmatch '(?m)^name:\s*herdr\s*$') {
        Write-Warning 'herdr --skill returned invalid skill content; keeping existing copies'
        return $false
    }

    $encoding = [Text.UTF8Encoding]::new($false)
    foreach ($destination in $Destinations) {
        $directory = Split-Path -Parent $destination
        $temporary = Join-Path $directory ('.SKILL.md.tmp.' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
            if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
                ([IO.File]::ReadAllText($destination) -ceq $Content)) {
                continue
            }
            [IO.File]::WriteAllText($temporary, $Content, $encoding)
            [IO.File]::Move($temporary, $destination, $true)
        } catch {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            Write-Warning "Could not synchronize Herdr skill at ${destination}: $_"
            return $false
        }
    }
    return $true
}

function Sync-HerdrSkill {
    param(
        [string[]]$Destinations = @(
            (Join-Path $HOME '.agents\skills\herdr\SKILL.md'),
            (Join-Path $HOME '.claude\skills\herdr\SKILL.md')
        ),
        [string]$HerdrPath = (Resolve-HerdrExecutable)
    )

    if (-not $HerdrPath) {
        Write-Warning 'Herdr is not installed; keeping any existing global skill copies'
        return $false
    }

    try {
        $content = Get-HerdrSkillContent -HerdrPath $HerdrPath
        return Write-HerdrSkillContent -Content $content -Destinations $Destinations
    } catch {
        Write-Warning "Could not read the official skill from the installed Herdr binary: $_"
        return $false
    }
}
