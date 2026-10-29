#Requires -Version 7.4
#Requires -PSEdition Core
# Audited upstream installer; it verifies the stable release zip's SHA-256.
$script:HerdrGuiInstallerUri = 'https://raw.githubusercontent.com/penso/herdr-gpui/5acc5b38f708bda79066f8e8ca2d037c9f9cefc6/site/install.ps1'
$script:HerdrGuiInstallerSha256 = '38502284D58C5F15D9DF44514D4901AAEB65A08736741508F7476B406EC7D989'

function Invoke-HerdrGuiInstallerProcess {
    param([Parameter(Mandatory)][string]$InstallerPath)
    & pwsh -NoProfile -File $InstallerPath | Out-Host
    return $LASTEXITCODE
}

function Install-HerdrGui {
    $ErrorActionPreference = 'Stop'
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Herdr UI\herdr-gpui.exe'
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -or
        (Get-Command herdr-gpui -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host 'Herdr UI already installed; skipping (updates: App Updates)'
        return
    }
    $installer = Join-Path ([IO.Path]::GetTempPath()) ('herdr-ui-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -UseBasicParsing $script:HerdrGuiInstallerUri -OutFile $installer -TimeoutSec 60 -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $script:HerdrGuiInstallerSha256) {
            throw 'Herdr UI installer checksum mismatch; refusing to execute'
        }
        # A separate process contains upstream preferences, exit and Add-Type.
        $exitCode = Invoke-HerdrGuiInstallerProcess -InstallerPath $installer
        if ($exitCode -ne 0) { throw "Herdr UI installer failed with exit $exitCode" }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw 'Herdr UI installer did not produce herdr-gpui.exe'
        }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}
