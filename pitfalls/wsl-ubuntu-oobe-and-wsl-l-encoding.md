# WSL Ubuntu: OOBE username/password prompt, `wsl -l` mojibake, wsl.conf default user ignored

**Symptoms** (grep this section):
- `wsl -l`/`wsl -l -q`/`wsl --status` print **garbled/mojibake** text (`U​b​u​n​t​u`, null bytes, `\x00`) or fail to `-match` in PowerShell.
- First `wsl -d Ubuntu-24.04` launch drops into the interactive **"Enter new UNIX username:"** / **"New password:"** OOBE instead of provisioning unattended.
- After scripting `/etc/wsl.conf` `[user] default=<name>`, `wsl` still logs in as **root** (the default-user change "did nothing").
- Piped bash script fails with `$'\r': command not found` / `set -e` aborting on the first line.
- `enable-wsl-ubuntu` prints **"Ubuntu-24.04 already exists and wasn't set up by this tool"** and does nothing — an `Ubuntu-24.04` you installed + OOBE'd yourself is deliberately left untouched.

**First seen**: 2026-07
**Affects**: `scripts/enable-wsl-ubuntu.ps1`, WSL2 on Windows 10/11, Ubuntu-24.04
**Status**: workaround documented (baked into the script)

## Symptom

Automating a WSL Ubuntu install from PowerShell hits three separate traps:

1. `wsl.exe` emits **UTF-16LE** by default, so `wsl -l -q | ...` in pwsh is
   mojibake and string matching (`-match 'Ubuntu-24.04'`) silently fails.
2. `wsl --install -d Ubuntu-24.04` (without `--no-launch`) or a plain
   `wsl -d Ubuntu-24.04` first-launch runs the **interactive OOBE**, asking for a
   UNIX username + password — defeating unattended setup.
3. `/etc/wsl.conf` `[user] default=<name>` is read **only at distro boot**; the
   already-running session keeps its old default user until the distro is
   terminated.
4. Passing a multi-line bash script from PowerShell with CRLF line endings makes
   bash choke on the `\r`.

## Root cause

1. WSL's long-standing UTF-16 output; the fix is the `WSL_UTF8` env var
   (WSL ≥ 0.64): <https://learn.microsoft.com/en-us/windows/wsl/basic-commands>
2. The distro launcher runs OOBE on first init unless you register with
   `--no-launch` and create the user yourself as root (there is no `--user` on
   `wsl --install`): <https://superuser.com/questions/1925924/scripting-automating-installation-of-a-wsl-distro>
3. `wsl.conf` is parsed on boot; `wsl --terminate <distro>` forces a re-read:
   <https://superuser.com/questions/1566022/how-to-set-default-user-for-manually-installed-wsl-distro>
4. PowerShell here-strings on Windows carry CRLF.

## Workaround

All baked into `scripts/enable-wsl-ubuntu.ps1`:

```powershell
$env:WSL_UTF8 = '1'                                   # (1) UTF-8 output
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)  # (4) BOM-free stdin
wsl.exe --install -d Ubuntu-24.04 --no-launch         # (2) register, no OOBE
# create the user as root, bypassing OOBE (bash via stdin, CRLF stripped):
$root = @"
set -e
u='<user>'
id "`$u" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm "`$u"
passwd -l "`$u" || true
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "`$u" > "/etc/sudoers.d/90-`$u"; chmod 0440 "/etc/sudoers.d/90-`$u"
printf '[user]\ndefault=%s\n' "`$u" > /etc/wsl.conf
"@ -replace "`r`n", "`n"
$root | wsl.exe -d Ubuntu-24.04 -u root -- bash -s
wsl.exe --terminate Ubuntu-24.04                      # (3) re-read wsl.conf
```

## Prevention

- Always set `$env:WSL_UTF8='1'` before parsing any `wsl.exe` output in pwsh.
- Always register distros with `--no-launch` and create the user as root; never
  let the OOBE run in an automated context.
- Always `wsl --terminate` after writing `/etc/wsl.conf`.
- Pipe bash via `bash -s` with `-replace "\`r\`n","\`n"` — never interpolate a
  complex command through `wsl -- bash -c "…"` (quote hell + CRLF).
- **Don't clobber a hand-made distro.** A distro this tool created carries the
  sentinel `/etc/dotfiles-windows-provisioned`; `enable-wsl-ubuntu` refuses to
  touch an `Ubuntu-24.04` that lacks it (so it never overwrites a distro you set
  up + OOBE'd yourself, and never fails trying to bootstrap as a user that
  doesn't exist there). To let the tool own it: `wsl --unregister Ubuntu-24.04`
  and re-run. To keep yours: install the dotfiles manually with the chezmoi
  one-liner. A separate pre-existing `Ubuntu` (not `-24.04`) is left alone — the
  tool adds its own `Ubuntu-24.04` and logs a note.

## Related

- `scripts/enable-wsl-ubuntu.ps1` · `.chezmoiscripts/run_onchange_after_46_wsl_ubuntu.ps1.tmpl`
- [tools.md → Unattended WSL Ubuntu + dotfiles](../docs/tools.md)
- `backlog/wsl-ubuntu-auto-dotfiles.md` (design record)
- Sibling: `pitfalls/wsl-install-no-action-reboot-required.md` (the platform install)
