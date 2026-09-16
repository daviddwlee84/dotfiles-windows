#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/windows-cli-release.ps1')
}

Describe 'Verified Windows CLI releases' {
    BeforeEach {
        $script:bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:fixture = Join-Path $TestDrive 'fixture'
        New-Item -ItemType Directory -Force $fixture | Out-Null
        Set-Content (Join-Path $fixture 'dev.exe') 'new binary'
        $script:zip = Join-Path $TestDrive 'release.zip'
        Compress-Archive (Join-Path $fixture 'dev.exe') $zip -Force
        $script:hash = (Get-FileHash $zip).Hash
        Mock Get-WindowsCliRelease {
            [pscustomobject]@{ Tag = 'v0.2.13'; Archive = 'dev.zip'; Checksums = 'SHA256SUMS'; BaseUri = 'https://example.invalid' }
        }
        Mock Invoke-WebRequest {
            if (([string]$Uri).EndsWith('/dev.zip')) { Copy-Item $zip $OutFile }
            else { Set-Content $OutFile "$hash  dev.zip" }
        }
        Mock Get-WindowsCliVersion { 'dev version v0.2.13' }
    }

    It 'installs a verified release and cleans staging' {
        Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin
        Get-Content (Join-Path $bin 'dev-cli.exe') | Should -Be 'new binary'
        @(Get-ChildItem $bin -Force).Count | Should -Be 1
    }

    It 'keeps apply offline when the owned executable is present' {
        New-Item -ItemType Directory -Force $bin | Out-Null
        Set-Content (Join-Path $bin 'dev-cli.exe') 'existing binary'
        Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Get-Content (Join-Path $bin 'dev-cli.exe') | Should -Be 'existing binary'
    }

    It 'preserves the old binary on a checksum mismatch' {
        New-Item -ItemType Directory -Force $bin | Out-Null
        Set-Content (Join-Path $bin 'dev-cli.exe') 'existing binary'
        $script:hash = '0' * 64
        { Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin -Upgrade } | Should -Throw '*Checksum mismatch*'
        Should -Invoke Get-WindowsCliVersion -Times 0 -Exactly
        Get-Content (Join-Path $bin 'dev-cli.exe') | Should -Be 'existing binary'
        @(Get-ChildItem $bin -Force).Count | Should -Be 1
    }

    It 'rejects a valid archive containing the wrong version before replacement' {
        New-Item -ItemType Directory -Force $bin | Out-Null
        Set-Content (Join-Path $bin 'dev-cli.exe') 'existing binary'
        Mock Get-WindowsCliVersion { 'dev version v0.1.0' }
        { Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin -Upgrade } | Should -Throw '*version mismatch*'
        Get-Content (Join-Path $bin 'dev-cli.exe') | Should -Be 'existing binary'
    }

    It 'rejects duplicate checksum entries' {
        Mock Invoke-WebRequest {
            if (([string]$Uri).EndsWith('/dev.zip')) { Copy-Item $zip $OutFile }
            else { Set-Content $OutFile @("$hash  dev.zip", "$hash  dev.zip") }
        }
        { Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin } | Should -Throw '*ambiguous checksum*'
        Test-Path (Join-Path $bin 'dev-cli.exe') | Should -BeFalse
    }

    It 'does not treat a broken installed binary as healthy' {
        New-Item -ItemType Directory -Force $bin | Out-Null
        Set-Content (Join-Path $bin 'dev-cli.exe') 'broken binary'
        Mock Get-WindowsCliVersion { throw 'Version probe failed' }
        { Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin } | Should -Throw '*Version probe failed*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'leaves an unrelated dev.exe untouched during install and upgrade' {
        New-Item -ItemType Directory -Force $bin | Out-Null
        Set-Content (Join-Path $bin 'dev.exe') 'internal dev tool'
        Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin
        Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin -Upgrade
        Get-Content (Join-Path $bin 'dev.exe') | Should -Be 'internal dev tool'
        Get-Content (Join-Path $bin 'dev-cli.exe') | Should -Be 'new binary'
        @(Get-ChildItem $bin -Force).Count | Should -Be 2
    }

    It 'restores the previous version when publishing the verified binary fails' {
        New-Item -ItemType Directory -Force $bin | Out-Null
        Set-Content (Join-Path $bin 'dev-cli.exe') 'existing binary'
        Mock Move-WindowsCliFile { throw 'fixture publish failure' } -ParameterFilter {
            $Source -like '*unpack*'
        }
        { Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin -Upgrade } |
            Should -Throw '*fixture publish failure*'
        Get-Content (Join-Path $bin 'dev-cli.exe') | Should -Be 'existing binary'
        @(Get-ChildItem $bin -Force).Count | Should -Be 1
    }

    It 'retries a real source sharing lock released after the first attempt' -Skip:(-not $IsWindows) {
        New-Item -ItemType Directory -Force $bin | Out-Null
        $source = Join-Path $bin 'source.exe'
        $target = Join-Path $bin 'target.exe'
        Set-Content $source 'new binary'
        $script:sourceLock = [IO.File]::Open($source, 'Open', 'Read', 'Read')
        Mock Start-Sleep { $script:sourceLock.Dispose() }
        try {
            Move-WindowsCliFile -Source $source -Destination $target
            Get-Content $target | Should -Be 'new binary'
            Should -Invoke Start-Sleep -Times 1 -Exactly
        } finally { $script:sourceLock.Dispose() }
    }

    It 'bounds retries and preserves an installed binary that denies renaming' -Skip:(-not $IsWindows) {
        New-Item -ItemType Directory -Force $bin | Out-Null
        $target = Join-Path $bin 'dev-cli.exe'
        Set-Content $target 'existing binary'
        $targetLock = [IO.File]::Open($target, 'Open', 'Read', 'Read')
        Mock Start-Sleep {}
        try {
            { Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin -Upgrade } |
                Should -Throw '*Close processes using that file and retry*'
            Should -Invoke Start-Sleep -Times 20 -Exactly
            Get-Content $target | Should -Be 'existing binary'
            @(Get-ChildItem $bin -Force).Count | Should -Be 1
        } finally { $targetLock.Dispose() }
    }

    It 'publishes a new version while a reader keeps using the old file' -Skip:(-not $IsWindows) {
        New-Item -ItemType Directory -Force $bin | Out-Null
        $target = Join-Path $bin 'dev-cli.exe'
        Set-Content $target 'existing binary'
        $stream = [IO.File]::Open($target, 'Open', 'Read', ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream)
        try {
            Install-WindowsCliRelease -Name dev-cli -BinDirectory $bin -Upgrade
            Get-Content $target | Should -Be 'new binary'
            $reader.ReadToEnd().Trim() | Should -Be 'existing binary'
        } finally { $reader.Dispose() }
    }
}

Describe 'Windows release architecture selection' {
    BeforeEach {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v2.10.0'
                assets = @('SpecStoryCLI_Windows_arm64.zip', 'SpecStoryCLI_Windows_x86_64.zip', 'SpecStoryCLI_2.10.0_checksums.txt') |
                    ForEach-Object { [pscustomobject]@{ name = $_ } }
            }
        }
    }
    It 'uses the native ARM64 artifact' {
        (Get-WindowsCliRelease -Name specstory -Architecture Arm64).Archive | Should -Be 'SpecStoryCLI_Windows_arm64.zip'
    }
    It 'uses the upstream x86_64 spelling on x64' {
        (Get-WindowsCliRelease -Name specstory -Architecture X64).Archive | Should -Be 'SpecStoryCLI_Windows_x86_64.zip'
    }
    It 'rejects an unsupported architecture before requesting metadata' {
        { Get-WindowsCliRelease -Name specstory -Architecture X86 } | Should -Throw '*Unsupported*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}
