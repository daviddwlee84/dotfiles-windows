#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot 'dot_codex/modify_config.toml.ps1.tmpl'
    $RenderedPath = Join-Path $TestDrive 'modify_config.toml.ps1'
    $BrokenOverlayPath = Join-Path $TestDrive 'modify_config-broken-overlay.toml.ps1'
    $Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $PwshPath = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    $rendered = & chezmoi execute-template --source $RepoRoot --file $TemplatePath
    if ($LASTEXITCODE -ne 0) { throw 'failed to render Codex modifier' }
    $renderedText = $rendered -join "`n"
    [System.IO.File]::WriteAllText($RenderedPath, $renderedText, [System.Text.UTF8Encoding]::new($false))

    $brokenOverlayText = $renderedText.Replace("[tui]`n#", "[tui`n#")
    if ($brokenOverlayText -eq $renderedText) { throw 'failed to construct broken Codex overlay fixture' }
    [System.IO.File]::WriteAllText($BrokenOverlayPath, $brokenOverlayText, [System.Text.UTF8Encoding]::new($false))

    function ConvertTo-Hex {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [byte[]] $Bytes
        )

        return [System.Convert]::ToHexString($Bytes)
    }

    function Assert-ExactBytes {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [byte[]] $Actual,

            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [byte[]] $Expected
        )

        (ConvertTo-Hex -Bytes $Actual) | Should -BeExactly (ConvertTo-Hex -Bytes $Expected)
    }

    function ConvertFrom-StrictUtf8 {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [byte[]] $Bytes
        )

        return $Utf8.GetString($Bytes)
    }

    function Assert-SuccessfulMerge {
        param(
            [Parameter(Mandatory)]
            [psobject] $Result
        )

        $Result.ExitCode | Should -Be 0
        $Result.Stderr | Should -BeNullOrEmpty
        (ConvertFrom-StrictUtf8 -Bytes $Result.StdoutBytes) | Should -Match 'model-with-reasoning'
    }

    function Invoke-CodexModifier {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [byte[]] $LiveBytes,

            [string] $ScriptPath = $RenderedPath,

            [hashtable] $Environment = @{}
        )

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $PwshPath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-NonInteractive')
        $startInfo.ArgumentList.Add('-File')
        $startInfo.ArgumentList.Add($ScriptPath)
        foreach ($name in $Environment.Keys) {
            $startInfo.Environment[$name] = [string] $Environment[$name]
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $stdout = [System.IO.MemoryStream]::new()
        $stderr = [System.IO.MemoryStream]::new()
        try {
            if (-not $process.Start()) { throw 'failed to start rendered Codex modifier' }
            $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
            $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderr)

            if ($LiveBytes.Length -gt 0) {
                $process.StandardInput.BaseStream.Write($LiveBytes, 0, $LiveBytes.Length)
            }
            $process.StandardInput.BaseStream.Close()

            $process.WaitForExit()
            $stdoutCopy.GetAwaiter().GetResult()
            $stderrCopy.GetAwaiter().GetResult()

            return [pscustomobject]@{
                StdoutBytes = $stdout.ToArray()
                Stderr      = $Utf8.GetString($stderr.ToArray())
                ExitCode    = $process.ExitCode
            }
        }
        finally {
            $stdout.Dispose()
            $stderr.Dispose()
            $process.Dispose()
        }
    }
}

Describe 'Codex config byte-safe overlay' {
    It 'merges a full-size desktop config with many plugin and project tables' {
        $tables = 1..60 | ForEach-Object {
            "[projects.'C:\Users\Example\repo$_']`ntrust_level = `"trusted`"`n"
        }
        $liveBytes = $Utf8.GetBytes(($tables -join "`n") + "`n[tui]`nstatus_line = [`"old`"]`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes
        Assert-SuccessfulMerge -Result $result
        (ConvertFrom-StrictUtf8 -Bytes $result.StdoutBytes) | Should -Match 'repo60'
    }

    It 'creates the managed status line from zero input bytes' {
        $result = Invoke-CodexModifier -LiveBytes ([byte[]]::new(0))

        Assert-SuccessfulMerge -Result $result
        $text = ConvertFrom-StrictUtf8 -Bytes $result.StdoutBytes
        $text | Should -Match '(?s)status_line\s*=.*model-with-reasoning.*fast-mode.*git-branch.*context-remaining.*task-progress.*current-dir'
        $text | Should -Not -Match 'five-hour-limit|weekly-limit'
    }

    It 'accepts only TOML-legal whitespace as blank input' {
        $liveBytes = $Utf8.GetBytes(" `t`n`r`n`t ")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        Assert-SuccessfulMerge -Result $result
    }

    It 'accepts a UTF-8 BOM with no content' {
        $result = Invoke-CodexModifier -LiveBytes ([byte[]] (0xEF, 0xBB, 0xBF))

        Assert-SuccessfulMerge -Result $result
    }

    It 'removes one UTF-8 BOM from valid live TOML before parsing' {
        [byte[]] $liveBytes = ([byte[]] (0xEF, 0xBB, 0xBF)) + $Utf8.GetBytes("model = `"bom-model`"`r`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        Assert-SuccessfulMerge -Result $result
        (ConvertFrom-StrictUtf8 -Bytes $result.StdoutBytes) | Should -Match 'model = "bom-model"'
    }

    It 'repairs the double-mojibake BOM prefix already written by the old modifier' {
        $prefix = 'Γê⌐ΓòùΓöÉ'
        $liveBytes = $Utf8.GetBytes($prefix + "model = `"recovered`"`r`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'repairing a mojibake UTF-8 BOM prefix'
        $text = ConvertFrom-StrictUtf8 -Bytes $result.StdoutBytes
        $text | Should -Match 'model = "recovered"'
        $text | Should -Not -Match [regex]::Escape($prefix)
        $text | Should -Match 'model-with-reasoning'
    }

    It 'repairs the direct OEM mojibake BOM prefix' {
        $prefix = [string]([char]0x2229) + [char]0x2557 + [char]0x2510
        $liveBytes = $Utf8.GetBytes($prefix + "model = `"recovered`"`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'repairing a mojibake UTF-8 BOM prefix'
        (ConvertFrom-StrictUtf8 -Bytes $result.StdoutBytes) | Should -Not -Match [regex]::Escape($prefix)
    }

    It 'preserves a double BOM byte-for-byte with a diagnostic' {
        [byte[]] $liveBytes = ([byte[]] (0xEF, 0xBB, 0xBF)) + ([byte[]] (0xEF, 0xBB, 0xBF)) + $Utf8.GetBytes("model = `"untouched`"`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'multiple leading UTF-8 BOMs'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'does not treat NBSP as blank TOML' {
        [byte[]] $liveBytes = 0xC2, 0xA0
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'whitespace that TOML does not allow as blank input'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'preserves providers, projects, and nested TUI tables while replacing status_line' {
        $live = @'
model = "custom-model"

[model_providers.copilot]
base_url = "http://localhost:4142"

[model_providers.copilot.http_headers]
X-Custom = "preserve-me"

[projects."C:/src/project"]
trust_level = "trusted"

[tui]
status_line = ["old-status"]

[tui.keymap.editor]
insert_newline = ["ctrl-j"]
'@
        $result = Invoke-CodexModifier -LiveBytes $Utf8.GetBytes($live)

        Assert-SuccessfulMerge -Result $result
        $text = ConvertFrom-StrictUtf8 -Bytes $result.StdoutBytes
        $text | Should -Match 'model = "custom-model"'
        $text | Should -Match 'base_url = "http://localhost:4142"'
        $text | Should -Match 'X-Custom = "preserve-me"'
        $text | Should -Match '(?s)\[projects\."C:/src/project"\].*trust_level = "trusted"'
        $text | Should -Match '(?s)\[tui\.keymap\.editor\].*insert_newline = \["ctrl-j"\]'
        $text | Should -Not -Match 'old-status'
    }

    It 'fails closed when tui exists with a non-table TOML type' {
        $liveBytes = $Utf8.GetBytes("tui = `"must-survive`"`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'live tui value is not a table'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'preserves malformed TOML with LF byte-for-byte and diagnoses the parser failure' {
        $liveBytes = $Utf8.GetBytes("model = [`nprovider = `"still here`"`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'live config is invalid TOML'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'preserves malformed TOML with CRLF byte-for-byte and diagnoses the parser failure' {
        $liveBytes = $Utf8.GetBytes("model = [`r`nprovider = `"still here`"`r`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'live config is invalid TOML'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'rejects a standalone CR before the TOML parser can normalize it' {
        $liveBytes = $Utf8.GetBytes('x = """a' + "`r" + 'b"""' + "`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'standalone CR'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'preserves invalid UTF-8 byte-for-byte with a diagnostic' {
        [byte[]] $liveBytes = 0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x20, 0x3D, 0x20, 0x22, 0xC3, 0x28, 0x22, 0x0A
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'stdin is not valid UTF-8'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'preserves valid input when bun is absent instead of downloading a parser' {
        $liveBytes = $Utf8.GetBytes("model = `"no-parser`"`r`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes -Environment @{ PATH = $TestDrive }

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'bun was not found'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'preserves valid input when the managed overlay cannot be parsed' {
        $liveBytes = $Utf8.GetBytes("model = `"overlay-failure`"`r`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes -ScriptPath $BrokenOverlayPath

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -Match 'managed overlay is invalid'
        Assert-ExactBytes -Actual $result.StdoutBytes -Expected $liveBytes
    }

    It 'normalizes successful output to BOM-free LF with exactly one final LF' {
        [byte[]] $liveBytes = ([byte[]] (0xEF, 0xBB, 0xBF)) + $Utf8.GetBytes("model = `"normalize-me`"`r`n`r`n[tui]`r`nstatus_line = [`"old`"]`r`n`r`n")
        $result = Invoke-CodexModifier -LiveBytes $liveBytes

        Assert-SuccessfulMerge -Result $result
        $result.StdoutBytes.Length | Should -BeGreaterThan 3
        (ConvertTo-Hex -Bytes $result.StdoutBytes[0..2]) | Should -Not -BeExactly 'EFBBBF'
        $result.StdoutBytes | Should -Not -Contain 0x0D
        $result.StdoutBytes[-1] | Should -Be 0x0A
        $result.StdoutBytes[-2] | Should -Not -Be 0x0A
    }

    It 'is byte-idempotent after the first successful merge' {
        $liveBytes = $Utf8.GetBytes("model = `"stable`"`r`n`r`n[tui]`r`nstatus_line = [`"old`"]`r`n")
        $first = Invoke-CodexModifier -LiveBytes $liveBytes
        $second = Invoke-CodexModifier -LiveBytes $first.StdoutBytes

        Assert-SuccessfulMerge -Result $first
        Assert-SuccessfulMerge -Result $second
        Assert-ExactBytes -Actual $second.StdoutBytes -Expected $first.StdoutBytes
    }
}
