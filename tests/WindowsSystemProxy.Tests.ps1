#Requires -Version 7.4
#Requires -PSEdition Core
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/windows-system-proxy.ps1')
}

Describe 'Command-scoped Windows proxy bridge' {
    BeforeEach {
        $script:savedProxy = @{}
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            $savedProxy[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        Mock Get-ItemProperty { [pscustomobject]@{ ProxyEnable = 1; ProxyServer = '127.0.0.1:7891'; ProxyOverride = '*.internal.test;<local>' } }
    }
    AfterEach {
        foreach ($name in $savedProxy.Keys) { [Environment]::SetEnvironmentVariable($name, $savedProxy[$name], 'Process') }
    }
    It 'exposes the configured proxy to the child and restores the environment' {
        $result = Invoke-WithWindowsSystemProxy { @($env:HTTPS_PROXY, $env:NO_PROXY) }
        $result[0] | Should -Be 'http://127.0.0.1:7891/'
        $result[1] | Should -Match '\.internal.test'
        $env:HTTPS_PROXY | Should -BeNullOrEmpty
    }
    It 'restores the environment even when the command fails' {
        { Invoke-WithWindowsSystemProxy { throw 'child failure' } } | Should -Throw '*child failure*'
        $env:HTTP_PROXY | Should -BeNullOrEmpty
    }
    It 'preserves explicit proxy policy' {
        $env:ALL_PROXY = 'socks5://localhost:9000'
        Invoke-WithWindowsSystemProxy { $env:ALL_PROXY } | Should -Be 'socks5://localhost:9000'
        Should -Invoke Get-ItemProperty -Times 0 -Exactly
        $env:HTTPS_PROXY | Should -BeNullOrEmpty
    }
    It 'does not resurrect a disabled system proxy' {
        Mock Get-ItemProperty { [pscustomobject]@{ ProxyEnable = 0; ProxyServer = 'localhost:1234' } }
        Invoke-WithWindowsSystemProxy { [string]$env:HTTPS_PROXY } | Should -BeNullOrEmpty
    }
    It 'selects separate HTTP and HTTPS proxy servers' {
        Mock Get-ItemProperty { [pscustomobject]@{ ProxyEnable = 1; ProxyServer = 'http=localhost:1234;https=localhost:5678'; ProxyOverride = '' } }
        $result = Get-WindowsSystemProxyVariables
        $result.HTTP_PROXY | Should -Be 'http://localhost:1234/'
        $result.HTTPS_PROXY | Should -Be 'http://localhost:5678/'
    }
}
