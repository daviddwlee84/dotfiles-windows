# Package-source policy shared by apply-time installers and interactive pwsh.
# Known endpoint values from earlier versions are treated as repo-owned so an
# additive profile reload converges; every other value survives. Managed policy
# still wins over China mirrors; public fallback is command-scoped elsewhere.
$repoPackageSourceValues = @{
    PIP_INDEX_URL       = @('https://packagefeedproxy.microsoft.io/pypi/simple/', 'https://pypi.tuna.tsinghua.edu.cn/simple')
    UV_DEFAULT_INDEX    = @('https://packagefeedproxy.microsoft.io/pypi/simple/', 'https://pypi.tuna.tsinghua.edu.cn/simple')
    npm_config_registry = @('https://packagefeedproxy.microsoft.io/npm/', 'https://registry.npmmirror.com')
    GOPROXY              = @('https://goproxy.cn,direct')
    MISE_NODE_MIRROR_URL = @('https://npmmirror.com/mirrors/node/')
    RUSTUP_DIST_SERVER   = @('https://rsproxy.cn')
    RUSTUP_UPDATE_ROOT   = @('https://rsproxy.cn/rustup')
}
foreach ($sourceVariable in $repoPackageSourceValues.Keys) {
    $currentValue = [Environment]::GetEnvironmentVariable($sourceVariable, 'Process')
    if ($null -ne $currentValue -and $repoPackageSourceValues[$sourceVariable] -ccontains $currentValue) {
        Remove-Item "Env:$sourceVariable" -ErrorAction SilentlyContinue
    }
}

{{ if .managedMachine -}}
$env:PIP_INDEX_URL       = 'https://packagefeedproxy.microsoft.io/pypi/simple/'
$env:UV_DEFAULT_INDEX    = 'https://packagefeedproxy.microsoft.io/pypi/simple/'
$env:npm_config_registry = 'https://packagefeedproxy.microsoft.io/npm/'
{{ else if .useChineseMirror -}}
$env:PIP_INDEX_URL       = 'https://pypi.tuna.tsinghua.edu.cn/simple'
$env:UV_DEFAULT_INDEX    = 'https://pypi.tuna.tsinghua.edu.cn/simple'
$env:npm_config_registry = 'https://registry.npmmirror.com'
$env:GOPROXY             = 'https://goproxy.cn,direct'
$env:RUSTUP_DIST_SERVER  = 'https://rsproxy.cn'
$env:RUSTUP_UPDATE_ROOT  = 'https://rsproxy.cn/rustup'
{{ end -}}
