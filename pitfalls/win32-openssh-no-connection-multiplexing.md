# Windows OpenSSH has no connection multiplexing (`getsockname failed: Not a socket`)

**Symptoms** (grep this section):

```
> ssh -o ControlPath=%TEMP%\cm -O check localhost
getsockname failed: Not a socket
Read from remote host localhost: Unknown error
```

A POSIX OpenSSH client answers the same command with
`Control socket connect(/path): No such file or directory`. `ControlMaster` /
`ControlPath` / `ControlPersist` in a Windows `~/.ssh/config` are quietly
ineffective — you keep being asked for the password on every connection.

**First seen**: 2026-08-27, while considering a `ControlMaster` port of
`ssh-setup-remote` to `dot_config/powershell/profile.d/96_ssh_setup.ps1`.
**Verified on**: `OpenSSH_for_Windows_9.5p2`,
`C:\Windows\System32\OpenSSH\ssh.exe`.
**Status**: won't fix — it is a client limitation, not a configuration
mistake. Do not add `ControlMaster` options to the PowerShell wizard.

## Root cause

Multiplexing needs a Unix-domain socket **and** file-descriptor passing over
it (`SCM_RIGHTS`). Windows 10+ does have `AF_UNIX`, but the Win32 OpenSSH
port does not implement fd passing, so the control socket cannot hand a
connection to another process. `-O check` fails at `getsockname` because what
it opened is not the socket it expects.

## What to do instead

Multiplexing is a means, not an end: the goal is *fewer password prompts*, and
on Windows the only lever is **fewer connections**. `96_ssh_setup.ps1` does
this by merging round trips:

| Remote | Connections |
|---|---|
| POSIX | 1 — `uname -s` rides along with the `authorized_keys` append |
| Windows | 2 — the POSIX attempt, then one PowerShell program that probes Administrators membership *and* installs |

That is also why the `administrators_authorized_keys` question is asked **up
front as a policy** rather than between a probe and an install: the remote
ANDs the local answer with the account's real group membership, so the
decision costs no extra connection and is still correct.

Where a key is already installed, prefer key auth over re-running anything.

## Related

- `../dotfiles/pitfalls/ssh-controlpath-too-long-macos-tmpdir.md` — the Unix
  twin *does* multiplex, and got the socket-path budget wrong.
