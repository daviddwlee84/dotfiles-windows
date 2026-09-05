#Requires -Version 7.4
#Requires -PSEdition Core
# Shared official Windows release installer for dev-cli and SpecStory.
# Apply installs missing tools only; explicit upgrade recipes request replacement.
function Get-WindowsCliRelease {
    param(
        [ValidateSet('dev-cli', 'specstory')][string]$Name,
        [string]$Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    )
    $arch = switch ($Architecture) {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { throw "Unsupported Windows architecture: $Architecture" }
    }
    $repository = if ($Name -eq 'dev-cli') { 'daviddwlee84/dev-cli' } else { 'specstoryai/getspecstory' }
    $release = Invoke-RestMethod "https://api.github.com/repos/$repository/releases/latest" -TimeoutSec 60 -ErrorAction Stop
    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v\d+\.\d+\.\d+$') { throw "Unexpected $Name release tag: $tag" }
    if ($Name -eq 'dev-cli') {
        $archive = "dev-cli_${tag}_windows_${arch}.zip"
        $checksums = 'SHA256SUMS'
        $exe = 'dev.exe'
    } else {
        $specArch = if ($arch -eq 'amd64') { 'x86_64' } else { 'arm64' }
        $archive = "SpecStoryCLI_Windows_${specArch}.zip"
        $checksums = "SpecStoryCLI_$($tag.Substring(1))_checksums.txt"
        $exe = 'specstory.exe'
    }
    foreach ($asset in @($archive, $checksums)) {
        if (@($release.assets | Where-Object name -CEQ $asset).Count -ne 1) {
            throw "$Name $tag is missing the official asset $asset"
        }
    }
    [pscustomobject]@{
        Tag = $tag; Archive = $archive; Checksums = $checksums; Executable = $exe
        BaseUri = "https://github.com/$repository/releases/download/$tag"
    }
}

function Get-WindowsCliVersion {
    param([string]$Path)
    $output = @(& $Path --version 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Version probe failed: $Path" }
    return ($output -join "`n").Trim()
}

function Install-WindowsCliRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('dev-cli', 'specstory')][string]$Name,
        [switch]$Upgrade,
        [string]$BinDirectory = (Join-Path $HOME '.local\bin')
    )
    $exe = if ($Name -eq 'dev-cli') { 'dev.exe' } else { 'specstory.exe' }
    $target = Join-Path $BinDirectory $exe
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and -not $Upgrade) {
        $version = Get-WindowsCliVersion -Path $target
        $recipe = if ($Name -eq 'dev-cli') { 'upgrade-dev' } else { 'upgrade-specstory' }
        Write-Host "==> $Name already installed: $version (upgrade: just $recipe)"
        return
    }
    $release = Get-WindowsCliRelease -Name $Name
    New-Item -ItemType Directory -Force -Path $BinDirectory -ErrorAction Stop | Out-Null
    # Same-volume staging allows a single atomic replacement after verification.
    $stage = Join-Path $BinDirectory ('.' + $Name + '-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
    try {
        Write-Host "==> installing $Name $($release.Tag) from official Windows release"
        $archive = Join-Path $stage $release.Archive
        $checksums = Join-Path $stage $release.Checksums
        foreach ($item in @(@($release.Archive, $archive), @($release.Checksums, $checksums))) {
            Invoke-WebRequest -Uri "$($release.BaseUri)/$($item[0])" -OutFile $item[1] `
                -TimeoutSec 180 -MaximumRetryCount 2 -RetryIntervalSec 2 -ErrorAction Stop
        }
        $pattern = '^([a-fA-F0-9]{64})\s+\*?' + [regex]::Escape($release.Archive) + '$'
        $lines = @(Get-Content -LiteralPath $checksums -ErrorAction Stop | Where-Object { $_ -cmatch $pattern })
        if ($lines.Count -ne 1) { throw "Missing or ambiguous checksum for $($release.Archive)" }
        $expected = [regex]::Match($lines[0], $pattern).Groups[1].Value
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256 -ErrorAction Stop).Hash -ine $expected) {
            throw "Checksum mismatch for $($release.Archive)"
        }
        $unpack = Join-Path $stage 'unpack'
        Expand-Archive -LiteralPath $archive -DestinationPath $unpack -ErrorAction Stop
        $binaries = @(Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter $exe -ErrorAction Stop)
        if ($binaries.Count -ne 1) { throw "Expected exactly one $exe in the release archive" }
        $version = Get-WindowsCliVersion -Path $binaries[0].FullName
        if ($version -notmatch ('(?<![\d.])' + [regex]::Escape($release.Tag.Substring(1)) + '(?![\d.])')) {
            throw "Release version mismatch: expected $($release.Tag), got $version"
        }
        [IO.File]::Move($binaries[0].FullName, $target, $true)
        Write-Host "==> verified $Name`: $version"
    } finally {
        # Only remove the exact generated staging directory inside this bin root.
        $root = [IO.Path]::GetFullPath($BinDirectory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $resolved = [IO.Path]::GetFullPath($stage)
        if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Staging path escaped bin directory: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
