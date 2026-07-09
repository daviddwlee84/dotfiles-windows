# 35_yazi.ps1 — `y` launches yazi and cd's to wherever you quit (mirrors the
# unix y() wrapper). No-op if yazi isn't installed.
if (Get-Command yazi -ErrorAction SilentlyContinue) {
    function y {
        $tmp = New-TemporaryFile
        try {
            yazi @args --cwd-file $tmp.FullName
            $cwd = (Get-Content -Raw -LiteralPath $tmp.FullName -ErrorAction SilentlyContinue).Trim()
            if ($cwd -and $cwd -ne $PWD.Path -and (Test-Path -LiteralPath $cwd)) {
                Set-Location -LiteralPath $cwd
            }
        } finally {
            Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}
