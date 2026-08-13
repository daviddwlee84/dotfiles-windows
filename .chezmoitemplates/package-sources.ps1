# Package-source policy shared by apply-time installers and interactive pwsh.
# Precedence is intentional: a managed/corporate machine must stay on the
# company-approved pull-through registries even if useChineseMirror was also
# selected. NuGet is provisioned machine-wide by IT; Go/Cargo keep their normal
# defaults because no company endpoints were discovered for them.
{{ if .managedMachine -}}
$env:PIP_INDEX_URL       = 'https://packagefeedproxy.microsoft.io/pypi/simple/'
$env:UV_DEFAULT_INDEX    = 'https://packagefeedproxy.microsoft.io/pypi/simple/'
$env:npm_config_registry = 'https://packagefeedproxy.microsoft.io/npm/'
{{ else if .useChineseMirror -}}
$env:PIP_INDEX_URL        = 'https://pypi.tuna.tsinghua.edu.cn/simple'
$env:UV_DEFAULT_INDEX     = 'https://pypi.tuna.tsinghua.edu.cn/simple'
$env:npm_config_registry  = 'https://registry.npmmirror.com'
$env:GOPROXY              = 'https://goproxy.cn,direct'
$env:MISE_NODE_MIRROR_URL = 'https://npmmirror.com/mirrors/node/'
$env:RUSTUP_DIST_SERVER   = 'https://rsproxy.cn'
$env:RUSTUP_UPDATE_ROOT   = 'https://rsproxy.cn/rustup'
{{ end -}}
