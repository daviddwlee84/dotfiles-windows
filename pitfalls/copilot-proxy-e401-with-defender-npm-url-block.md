# `copilot-proxy restart` fails with `E401` while Defender reports `NPM URL Block`

**Symptoms** (grep this section): `copilot-proxy restart` fails on every install
path:

```text
npm warn Unknown user config "always-auth".
npm error code E401
npm error Unable to authenticate, your authentication token seems to be invalid.
WARNING: copilot-proxy: pinned CDN fallback failed (dependency installation through the configured registry failed)
```

Trying the configured China mirror can instead fail as TLS:

```text
npm error code ERR_SSL_SSL/TLS_ALERT_HANDSHAKE_FAILURE
npm error request to https://registry.npmmirror.com/... failed
```

Windows Security simultaneously shows `IT 管理員阻止此內容` for rule
`[TE] NPM URL Block`. Microsoft Defender Operational event `1126` names:

```text
目標:  https://registry.npmmirror.com
進程名稱:  node.exe
```

**First seen**: 2026-08
**Affects**: Windows managed machines running the Copilot PowerShell module with
a parent `.npmrc` that selects an authenticated Azure Artifacts registry.
**Status**: fixed - the CDN dependency installer isolates user/global npm config
and selects the repo-approved registry at CLI precedence.

## Root cause

Two independent policy layers produced similar-looking installation failures:

1. Microsoft Defender Network Protection blocked
   `https://registry.npmmirror.com`. Node surfaced that policy termination as an
   OpenSSL handshake failure rather than an explicit npm policy error.
2. npm discovered `C:\Users\<user>\.local\.npmrc` by walking upward from the
   staged package directory. That project config selected an authenticated
   `pkgs.dev.azure.com/.../npm/registry/` feed with an expired or unavailable
   credential, causing `E401` for every production dependency.

Passing `--userconfig` and `--globalconfig` alone did not solve the second layer:
npm still loads project `.npmrc` files independently. The npm debug log exposed
the decisive evidence:

```text
silly config load:file:C:\Users\<user>\.local\...\.npmrc
verbose argv ... "--registry" "https://pkgs.dev.azure.com/.../npm/registry/"
http fetch GET 401 https://pkgs.dev.azure.com/.../npm/registry/@modelcontextprotocol%2fsdk
```

On a managed machine, chezmoi's approved npm source is the Microsoft
pull-through endpoint `https://packagefeedproxy.microsoft.io/npm/`. The direct
Azure Artifacts feed and the China mirror are not interchangeable with it.

## Workaround

Confirm the endpoint block from the local Defender event log:

```powershell
$since = (Get-Date).AddMinutes(-20)
Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-Windows Defender/Operational'
    StartTime = $since
} | Where-Object Id -eq 1126 |
    Select-Object TimeCreated, Id, Message
```

Verify an actual dependency through the approved pull-through without loading
user credentials:

```powershell
$userConfig = Join-Path $env:TEMP 'copilot-empty-user.npmrc'
$globalConfig = Join-Path $env:TEMP 'copilot-empty-global.npmrc'
npm view '@modelcontextprotocol/sdk@^1.29.0' version `
    --userconfig=$userConfig --globalconfig=$globalConfig `
    --registry=https://packagefeedproxy.microsoft.io/npm/ `
    --@modelcontextprotocol:registry=https://packagefeedproxy.microsoft.io/npm/
```

Deploy the fixed module, select the reviewed version, and verify the client-facing
shim:

```powershell
chezmoi apply --force "$HOME/.config/powershell/modules/Copilot/Copilot.psm1"
Import-Module "$HOME/.config/powershell/modules/Copilot/Copilot.psd1" -Force
copilot-proxy update 2.3.4
copilot-proxy restart
copilot-proxy doctor --live
Invoke-RestMethod http://127.0.0.1:4142/v1/models
```

Do not disable Defender Network Protection or bypass the managed-machine source
policy. The fixed fallback downloads only the reviewed runtime files from
jsDelivr, verifies each baked SHA-256, and resolves ordinary dependencies through
the approved Microsoft pull-through.

## Prevention

- Do not infer an npm authentication problem from `E401` alone; inspect the npm
  debug log's `config load`, `verbose argv`, and `http fetch` lines.
- Treat `--userconfig` and `--globalconfig` as insufficient isolation when npm can
  discover a parent project `.npmrc`.
- Put the policy-selected registry on the npm command line so it has precedence
  over project config.
- On `managedMachine=true`, use the corporate pull-through even when
  `useChineseMirror=true`; managed policy wins.
- Correlate TLS handshake failures with Defender event `1126` before diagnosing
  certificates or changing `strict-ssl`.

## Related

- [`copilot-proxy-npm-etarget-but-doctor-says-installed`](copilot-proxy-npm-etarget-but-doctor-says-installed.md)
- [`packagefeedproxy-npm-404-wrong-base-path`](packagefeedproxy-npm-404-wrong-base-path.md)
- [`docs/copilot-proxy.md`](../docs/copilot-proxy.md)
