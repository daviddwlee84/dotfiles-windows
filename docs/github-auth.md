# GitHub authentication and proxies

If `gh auth login` fails behind Clash while the browser or Git can connect,
set the proxy in the **PowerShell session that will run `gh`**, complete browser
authentication, then configure Git to use the GitHub CLI credentials.

## Sign in through Clash

Use Clash's actual **HTTP or mixed port**. The verified setup used `7891`;
this is an example, not a universal Clash default.

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:7891'
$env:HTTP_PROXY = $env:HTTPS_PROXY

gh auth login --hostname github.com --git-protocol https --web
```

Answer **Yes** to authenticating Git, then enter the newly generated one-time
code in the browser and finish authorization. After `Authentication complete`:

```powershell
gh auth setup-git --hostname github.com
gh auth status
```

Retry `git pull` in the intended repository. `gh auth setup-git` configures
GitHub's credential helper to use `gh`; it does not sign in by itself. The
`--hostname github.com` option scopes the configuration to that host. See the
[official command reference](https://cli.github.com/manual/gh_auth_setup-git).

The proxy URL starts with **`http://` even in `HTTPS_PROXY`** because it points
to Clash's HTTP proxy listener, which tunnels HTTPS connections. Both variables
affect only this shell and its child processes. A new terminal needs them again
unless configured separately. If `NO_PROXY` already excludes GitHub, adjust that
entry before retrying. These commands do not change Windows' system proxy or
enable TUN.

**Verified on Windows, 2026-09-04:** these steps completed authentication;
`gh auth status` reported an active account stored in the keyring with HTTPS
Git operations, and the subsequent `git pull` reached object download.

## Why the browser works while gh fails

These proxy mechanisms are separate:

| Mechanism | What uses it |
|---|---|
| Windows system proxy | Applications that honor Windows' proxy settings, including typical browser configurations. |
| Git `http.proxy` | Git's HTTP(S) transport; this does not configure `gh`'s OAuth/API requests. |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | The Go HTTP transport used by `gh`. |
| Clash TUN | Routes application traffic through a virtual network interface when enabled and correctly routed. |

`gh` uses Go's default HTTP transport, whose proxy lookup reads environment
variables rather than Git configuration or the Windows system proxy. See the
[gh HTTP client](https://github.com/cli/go-gh/blob/trunk/pkg/api/http_client.go)
and [Go's proxy lookup](https://pkg.go.dev/net/http#ProxyFromEnvironment).

In the verified incident, Windows' system proxy and Git's proxy both pointed
to Clash, but the proxy environment variables were unset. There was no active
Clash TUN interface, and the route to GitHub used Wi-Fi through the LAN gateway.
Consequently, those settings did not route `gh` through Clash.

The failed request was a POST to `https://github.com/login/oauth/access_token`,
ending with:

```text
wsarecv: An established connection was aborted by the software in your host machine.
```

This is a connection-abort symptom, not proof of a bad GitHub password or of a
particular firewall causing it. Microsoft's
[Winsock error reference](https://learn.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2)
also lists timeout or protocol errors as possible causes. Short direct requests
worked during diagnosis, so the original interruption was not reproduced;
explicit proxy configuration was the subsequently confirmed workaround.

To check whether TUN actually owns the route:

```powershell
Get-NetAdapter -IncludeHidden | Select-Object Name, InterfaceDescription, Status
$githubIPv4 = Resolve-DnsName github.com -Type A |
    Where-Object IPAddress | Select-Object -First 1 -ExpandProperty IPAddress
Find-NetRoute -RemoteIPAddress $githubIPv4
```

Check the selected interface and next hop. A public peer IP in an error message
alone does not prove TUN was bypassed; TUN operates below the application's
HTTP proxy layer.

## CredentialHelperSelector after switching Git installations

`CredentialHelperSelector` is Git for Windows' credential-helper chooser. A
portable Git installation can default to `helper-selector`, while another Git
installation already uses `manager`. A PATH change can therefore expose the
chooser even if it never appeared before.

```powershell
Get-Command git -All | Select-Object Source
git --version
git config --show-origin --show-scope --get-all credential.helper
```

In this incident, the `Program Files` Git 2.40 installation used `manager`,
while Scoop Git 2.55 used `helper-selector`. Scoop's
[Git package notes](https://github.com/ScoopInstaller/Main/blob/master/bucket/git.json)
describe configuring Git Credential Manager for portable Git.

| Choice | Behavior |
|---|---|
| `manager` | Git Credential Manager: supports GitHub browser authentication, MFA, and secure credential storage. |
| `wincred` | Stores supplied credentials in Windows; does not provide the full GitHub browser sign-in flow. |
| `<no helper>` | Does not use a credential helper to retrieve or store credentials. |

When choosing a general Git credential helper, select **`manager`** and check
**Always use this from now on**. See the
[GCM documentation](https://github.com/git-ecosystem/git-credential-manager).
For GitHub, the `gh auth setup-git` step above configures a host-specific helper
that uses the completed `gh` login. Selecting `manager` alone does not log in
the separate GitHub CLI application.

If Git reports `Invalid username or token` and
`Password authentication is not supported for Git operations`, it has not
obtained a valid token. Complete the login/helper steps above; a GitHub account
password cannot authenticate HTTPS Git operations. The chezmoi Git overlay
preserves these credential settings; see [Git configuration](setup.md#git-configuration).
