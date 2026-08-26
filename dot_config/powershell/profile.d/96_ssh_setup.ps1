# 96_ssh_setup.ps1 — interactive SSH key setup for remote machines.
#
# Native pwsh counterpart of the Unix repo's dot_config/shell/96_ssh_setup.sh,
# deliberately carrying the same fragment number. Public entry point is
# Set-RemoteSshKey, aliased to `ssh-setup-remote` so both platforms take the
# same command with the same meaning.
#
# What it walks through: pick or create a key -> install the public half on the
# remote -> optionally copy the key pair over -> wire the key into the local
# ~/.ssh/config. Before any of that it resolves the target's FULL ProxyJump
# chain and repeats the flow for every jump host, outermost first: ssh only
# forwards TCP through a jump, so each hop needs its own authorized_keys entry
# or it keeps asking for a password.
#
# Two things are genuinely different from the POSIX side:
#   * Windows OpenSSH ships no ssh-copy-id, so the public key is appended by a
#     small PowerShell program run on the far end.
#   * For an account in the remote Administrators group, sshd's default
#     `Match Group administrators` rule reads ONLY
#     C:\ProgramData\ssh\administrators_authorized_keys — a key written to
#     ~/.ssh/authorized_keys there is silently ignored.
#
# The ~/.ssh/config parsing here is a pure-PowerShell reimplementation of the
# Unix `_ssh_cfg_py` helper (recursive Include resolution, wildcard Host
# patterns skipped, first match wins) rather than a python3 dependency.
#
# Env knobs (same names as the Unix side):
#   SSH_SETUP_ASSUME_YES=1   take every prompt's default
#   SSH_SETUP_KEY=<path>     skip the key picker
#   SSH_CFG_ROOT=<path>      operate on a different config tree (tests)

# --- prompting -------------------------------------------------------------

function script:Read-SshSetupAnswer {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($env:SSH_SETUP_ASSUME_YES -eq '1') {
        Write-Host "$Prompt(default)"
        return ''
    }
    Write-Host $Prompt -NoNewline
    $answer = [Console]::In.ReadLine()
    if ($null -eq $answer) { return '' }
    return $answer
}

function script:Test-SshSetupYes {
    param([string]$Answer, [switch]$DefaultYes)
    if ([string]::IsNullOrWhiteSpace($Answer)) { return [bool]$DefaultYes }
    return $Answer -match '^[Yy]'
}

# $HOME is an automatic variable set once at session start — reassigning
# $env:HOME afterwards does not change it, which makes it unusable for test
# isolation. SSH_SETUP_HOME is the override (parallel to SSH_CFG_ROOT below).
function script:Get-SshSetupHome {
    if ($env:SSH_SETUP_HOME) { return $env:SSH_SETUP_HOME }
    return $HOME
}

# --- ~/.ssh/config parsing --------------------------------------------------

function script:Get-SshConfigRoot {
    if ($env:SSH_CFG_ROOT) { return $env:SSH_CFG_ROOT }
    return (Join-Path (Join-Path (Get-SshSetupHome) '.ssh') 'config')
}

function script:Expand-SshIncludePattern {
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$SshDir)
    $p = $Pattern.Trim('"')
    if ($p.StartsWith('~')) { $p = Join-Path (Get-SshSetupHome) $p.Substring(1).TrimStart('/', '\') }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $SshDir $p }
    return $p
}

# Every file in the config tree, following `Include` recursively. Mirrors
# _ssh_cfg_py.resolve_includes, cycle guard included.
function script:Resolve-SshConfigFiles {
    param([Parameter(Mandatory)][string]$Root)
    $sshDir = Split-Path -Parent $Root
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = [System.Collections.Generic.List[string]]::new()

    function walk([string]$path) {
        $full = try { [System.IO.Path]::GetFullPath($path) } catch { $path }
        if (-not $seen.Add($full)) { return }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
        $files.Add($full)
        foreach ($line in (Get-Content -LiteralPath $full -ErrorAction SilentlyContinue)) {
            $s = $line.Trim()
            if (-not $s -or $s.StartsWith('#')) { continue }
            if ($line -notmatch '(?i)^\s*include\s+(.+?)\s*$') { continue }
            foreach ($pat in ($Matches[1] -split '\s+')) {
                if (-not $pat) { continue }
                $expanded = Expand-SshIncludePattern -Pattern $pat -SshDir $sshDir
                foreach ($f in (Get-ChildItem -Path $expanded -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
                    walk $f.FullName
                }
            }
        }
    }

    walk $Root
    return $files
}

# The Host block for $Alias, or $null. Wildcard patterns never match — the same
# rule the Unix helper and tsnet both follow.
function script:Find-SshHostBlock {
    param([Parameter(Mandatory)][string]$Alias, [string]$KeyPath)
    $root = Get-SshConfigRoot
    foreach ($file in (Resolve-SshConfigFiles -Root $root)) {
        $lines = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '(?i)^\s*host\s+(.+?)\s*$') { continue }
            $patterns = $Matches[1] -split '\s+'
            $match = $false
            foreach ($p in $patterns) {
                if ($p -eq $Alias -and $p -notmatch '[*?!]') { $match = $true }
            }
            if (-not $match) { continue }

            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '(?i)^\s*(host|match)\b') { $j++ }
            $block = @($lines[$i..($j - 1)])

            $idf = @($block | Where-Object { $_ -match '(?i)^\s*identityfile\s+(.+?)\s*$' })
            $present = $false
            if ($KeyPath) {
                $want = Get-SshComparablePath $KeyPath
                foreach ($line in $idf) {
                    if ($line -match '(?i)^\s*identityfile\s+(.+?)\s*$') {
                        if ((Get-SshComparablePath $Matches[1]) -eq $want) { $present = $true }
                    }
                }
            }

            return [pscustomobject]@{
                File               = $file
                Lines              = $lines
                Start              = $i
                End                = $j
                Block              = $block
                HasIdentityFile    = ($idf.Count -gt 0)
                HasIdentitiesOnly  = [bool](@($block | Where-Object { $_ -match '(?i)^\s*identitiesonly\b' }).Count)
                KeyPresent         = $present
            }
        }
    }
    return $null
}

function script:Get-SshComparablePath {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim().Trim('"')
    if ($p.StartsWith('~')) { $p = Join-Path (Get-SshSetupHome) $p.Substring(1).TrimStart('/', '\') }
    # A malformed path (stray null / invalid char) should still compare as
    # itself rather than aborting the whole config walk.
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { Write-Verbose "Get-SshComparablePath: leaving '$p' unresolved: $_" }
    return $p.Replace('\', '/').TrimEnd('/')
}

function script:ConvertTo-SshTildePath {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-SshComparablePath $Path
    $home_ = (Get-SshComparablePath (Get-SshSetupHome))
    if ($full.StartsWith($home_ + '/', [StringComparison]::OrdinalIgnoreCase)) {
        return '~/' + $full.Substring($home_.Length + 1)
    }
    return $Path
}

# Splice an IdentityFile into an existing block. $Action: insert | replace | add.
function script:Add-SshIdentityFile {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][ValidateSet('insert', 'replace', 'add')][string]$Action,
        [switch]$IdentitiesOnly
    )
    $found = Find-SshHostBlock -Alias $Alias
    if (-not $found) { return $false }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(Get-Content -LiteralPath $File -ErrorAction SilentlyContinue))
    $block = [System.Collections.Generic.List[string]]::new()
    $block.AddRange([string[]]$found.Block)

    $indent = '    '
    for ($k = 1; $k -lt $block.Count; $k++) {
        if ($block[$k].Trim() -and ($block[$k][0] -eq ' ' -or $block[$k][0] -eq "`t")) {
            $indent = $block[$k].Substring(0, $block[$k].Length - $block[$k].TrimStart().Length)
            break
        }
    }
    $idfLine = "$indent" + 'IdentityFile ' + (ConvertTo-SshTildePath $KeyPath)

    $idfIdx = @()
    for ($k = 0; $k -lt $block.Count; $k++) {
        if ($block[$k] -match '(?i)^\s*identityfile\s+') { $idfIdx += $k }
    }

    if ($Action -eq 'add' -or $idfIdx.Count -eq 0) {
        $ins = $block.Count
        while ($ins -gt 1 -and -not $block[$ins - 1].Trim()) { $ins-- }
        $block.Insert($ins, $idfLine)
    } else {
        # 'replace', and 'insert' onto a block that already has one
        $block[$idfIdx[0]] = $idfLine
    }

    if ($IdentitiesOnly -and -not (@($block | Where-Object { $_ -match '(?i)^\s*identitiesonly\b' }).Count)) {
        $pos = $block.Count - 1
        for ($k = 0; $k -lt $block.Count; $k++) {
            if ($block[$k] -match '(?i)^\s*identityfile\s+') { $pos = $k; break }
        }
        $block.Insert($pos + 1, "$indent" + 'IdentitiesOnly yes')
    }

    $out = [System.Collections.Generic.List[string]]::new()
    if ($found.Start -gt 0) { $out.AddRange([string[]]@($lines[0..($found.Start - 1)])) }
    $out.AddRange([string[]]$block)
    if ($found.End -lt $lines.Count) { $out.AddRange([string[]]@($lines[$found.End..($lines.Count - 1)])) }

    Write-SshConfigFile -Path $File -Lines $out
    return $true
}

# Write atomically-ish and keep the file private. chezmoi's `private_` prefix
# owns the ACL on Windows; on a non-Windows pwsh we still need the chmod.
function script:Write-SshConfigFile {
    # AllowEmptyString is needed too: a MANDATORY [string[]] parameter rejects
    # an otherwise-non-empty array that merely CONTAINS an empty-string element
    # (e.g. the blank separator line before a Host block) unless both
    # attributes are present.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $tmp = "$Path.tmp$PID"
    Set-Content -LiteralPath $tmp -Value $Lines -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    if (-not $IsWindows) { & chmod 600 $Path 2>$null }
}

function script:Test-SshConfigDInclude {
    $root = Get-SshConfigRoot
    $sshDir = Split-Path -Parent $root
    $target = Get-SshComparablePath (Join-Path $sshDir 'config.d')
    foreach ($file in (Resolve-SshConfigFiles -Root $root)) {
        foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            $s = $line.Trim()
            if (-not $s -or $s.StartsWith('#')) { continue }
            if ($line -notmatch '(?i)^\s*include\s+(.+?)\s*$') { continue }
            foreach ($pat in ($Matches[1] -split '\s+')) {
                if (-not $pat) { continue }
                $dir = Split-Path -Parent (Expand-SshIncludePattern -Pattern $pat -SshDir $sshDir)
                if ((Get-SshComparablePath $dir) -eq $target) { return $true }
            }
        }
    }
    return $false
}

function script:Add-SshConfigDInclude {
    if (Test-SshConfigDInclude) { return $true }
    $root = Get-SshConfigRoot
    $sshDir = Split-Path -Parent $root
    $target = ConvertTo-SshTildePath (Join-Path $sshDir 'config.d')
    $existing = @()
    if (Test-Path -LiteralPath $root) { $existing = @(Get-Content -LiteralPath $root) }

    $k = 0
    while ($k -lt $existing.Count -and (-not $existing[$k].Trim() -or $existing[$k].TrimStart().StartsWith('#'))) { $k++ }

    $inc = @("# Load drop-in host configs from $target/", "Include $target/*", '')
    $out = @()
    if ($k -gt 0) { $out += $existing[0..($k - 1)] }
    $out += $inc
    if ($k -lt $existing.Count) { $out += $existing[$k..($existing.Count - 1)] }

    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Write-SshConfigFile -Path $root -Lines $out
    return $true
}

# --- ssh invocation seams (kept thin so Pester can mock them) ---------------

function script:Invoke-SshConfigQuery {
    param([Parameter(Mandatory)][string]$Target)
    return @(& ssh -G $Target 2>$null)
}

function script:Invoke-SshRemote {
    param([Parameter(Mandatory)][string]$Dest, [string[]]$SshArgs = @(), [Parameter(Mandatory)][string]$Command)
    $out = & ssh @SshArgs $Dest $Command 2>$null
    $script:SshSetupLastExit = $LASTEXITCODE
    return @($out)
}

# Ship a PowerShell program to the far end as -EncodedCommand (base64 UTF-16LE):
# neither the local shell, ssh's own argv concatenation, nor the remote
# DefaultShell (cmd or pwsh) can then mangle the quoting.
function script:Invoke-SshPowerShell {
    param([Parameter(Mandatory)][string]$Dest, [string[]]$SshArgs = @(), [Parameter(Mandatory)][string]$Script)
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
    return (Invoke-SshRemote -Dest $Dest -SshArgs $SshArgs -Command "powershell -NoProfile -NonInteractive -EncodedCommand $enc")
}

# --- ProxyJump chain --------------------------------------------------------

# [user@]host[:port] -> a dest usable by ssh/scp plus a separate port, because
# neither ssh-copy-id nor scp accepts "host:port".
function script:Split-SshHop {
    param([Parameter(Mandatory)][string]$Spec)
    $dest = $Spec
    $port = ''
    if ($Spec -match '^(.*\])\:(.+)$') { $dest = $Matches[1]; $port = $Matches[2] }
    elseif ($Spec -notmatch '\]$' -and $Spec -match '^(.*)\:([^:]+)$') { $dest = $Matches[1]; $port = $Matches[2] }
    if ($port -notmatch '^\d+$') { $dest = $Spec; $port = '' }
    return [pscustomobject]@{ Dest = $dest; Port = $port }
}

# The ProxyJump hops declared for one host. `ssh -G` omits the line entirely
# when there is none; an explicit `ProxyJump none` renders as the literal none.
function script:Get-SshJumpHop {
    param([Parameter(Mandatory)][string]$Target)
    foreach ($line in (Invoke-SshConfigQuery -Target $Target)) {
        if ($line -match '(?i)^\s*proxyjump\s+(.+?)\s*$') {
            $v = $Matches[1]
            if ($v -eq 'none') { return @() }
            return @($v -split ',' | Where-Object { $_ })
        }
    }
    return @()
}

# Every jump host needed to reach $Target, outermost first, target excluded.
function script:Get-SshJumpChain {
    param([Parameter(Mandatory)][string]$Target)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $added = [System.Collections.Generic.HashSet[string]]::new()
    $out = [System.Collections.Generic.List[string]]::new()

    function walk([string]$h) {
        if (-not $seen.Add($h)) { return }
        foreach ($hop in (Get-SshJumpHop -Target $h)) {
            walk $hop
            # A cycle back to the requested target must not list the target as
            # its own jump host; $seen already stopped the recursion.
            if ($hop -eq $Target) { continue }
            if ($added.Add($hop)) { $out.Add($hop) }
        }
    }

    walk $Target
    return @($out)
}

# --- local keys -------------------------------------------------------------

function script:Test-SshPrivateKeyFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $first = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue
    return ($first -match '-----BEGIN .*PRIVATE KEY-----')
}

# Keys in ~/.ssh, flagging the ones whose public half is missing. Listing by
# *.pub (the obvious approach, and what the Unix side used to do) hides exactly
# the keys that later break ssh-copy-id.
function script:Get-SshLocalKey {
    $dir = Join-Path (Get-SshSetupHome) '.ssh'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $skip = @('config', 'known_hosts', 'known_hosts.old', 'authorized_keys', '.DS_Store')
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($f.Extension -eq '.pub') { continue }
        if ($skip -contains $f.Name) { continue }
        if (-not (Test-SshPrivateKeyFile $f.FullName)) { continue }
        $result.Add([pscustomobject]@{
            Path   = $f.FullName
            HasPub = (Test-Path -LiteralPath ($f.FullName + '.pub'))
        })
    }
    return @($result)
}

# The public half is always derivable from the private key, so a missing .pub is
# repairable rather than fatal. ssh-keygen -y prompts for the passphrase itself.
function script:Restore-SshPublicKey {
    param([Parameter(Mandatory)][string]$KeyPath)
    if (Test-Path -LiteralPath ($KeyPath + '.pub')) { return $true }
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Write-Warning "Key not found: $KeyPath"
        return $false
    }

    Write-Host ''
    Write-Host "No public key next to $KeyPath."
    $ans = Read-SshSetupAnswer 'Regenerate it with `ssh-keygen -y`? [Y/n] '
    if (-not (Test-SshSetupYes -Answer $ans -DefaultYes)) {
        Write-Warning "The key install step needs $KeyPath.pub — aborting."
        return $false
    }

    $pub = & ssh-keygen -y -f $KeyPath
    if ($LASTEXITCODE -ne 0 -or -not $pub) {
        Write-Warning "ssh-keygen -y failed for $KeyPath"
        return $false
    }
    Set-Content -LiteralPath ($KeyPath + '.pub') -Value $pub -Encoding utf8NoBOM
    Write-Host "Wrote $KeyPath.pub"
    return $true
}

# --- installing the key on the far end -------------------------------------

# What is at the other end? `uname -s` is the cheap probe; it fails on a
# pwsh/cmd DefaultShell, and only then do we pay for the PowerShell round trip.
# whoami /groups rather than IsInRole(): a non-elevated admin token carries the
# Administrators SID as deny-only, which IsInRole reports as false, while sshd
# still routes that session through the administrators_authorized_keys rule.
function script:Get-SshRemoteKind {
    param([Parameter(Mandatory)][string]$Dest, [string[]]$SshArgs = @())

    $out = Invoke-SshRemote -Dest $Dest -SshArgs (@('-o', 'ConnectTimeout=15') + $SshArgs) -Command 'uname -s'
    $first = ($out | Select-Object -First 1)
    if ($first -match '^(Linux|Darwin|.*BSD|SunOS|AIX|CYGWIN|MINGW|MSYS)') {
        return [pscustomobject]@{ Kind = 'posix'; Admin = $false; User = '' }
    }

    $probe = @'
$ErrorActionPreference = 'SilentlyContinue'
$g = (whoami /groups | Out-String)
$a = if ($g -match 'S-1-5-32-544') { '1' } else { '0' }
Write-Output ("windows admin=" + $a + " user=" + $env:USERNAME)
'@
    $out = Invoke-SshPowerShell -Dest $Dest -SshArgs (@('-o', 'ConnectTimeout=15') + $SshArgs) -Script $probe
    foreach ($line in $out) {
        if ($line -match 'windows\s+admin=(\d)\s+user=(.*)$') {
            return [pscustomobject]@{ Kind = 'windows'; Admin = ($Matches[1] -eq '1'); User = $Matches[2].Trim() }
        }
    }
    return [pscustomobject]@{ Kind = 'unknown'; Admin = $false; User = '' }
}

# There is no ssh-copy-id on Windows, so even a POSIX remote is served by an
# explicit append. grep -qxF keeps it idempotent.
function script:Install-SshKeyPosix {
    param([Parameter(Mandatory)][string]$Dest, [string[]]$SshArgs = @(), [Parameter(Mandatory)][string]$PublicKey)
    $quoted = "'" + $PublicKey.Replace("'", "'\''") + "'"
    $cmd = "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; " +
           "grep -qxF $quoted ~/.ssh/authorized_keys || printf '%s\n' $quoted >> ~/.ssh/authorized_keys; " +
           "echo installed:~/.ssh/authorized_keys"
    return (Invoke-SshRemote -Dest $Dest -SshArgs $SshArgs -Command $cmd)
}

function script:Install-SshKeyWindows {
    param(
        [Parameter(Mandatory)][string]$Dest,
        [string[]]$SshArgs = @(),
        [Parameter(Mandatory)][string]$PublicKey,
        [switch]$UseAdminFile
    )
    # Single quotes are doubled, not backslash-escaped, inside a PowerShell
    # '...' literal.
    $key = $PublicKey.Replace("'", "''")
    $admin = if ($UseAdminFile) { '1' } else { '0' }
    $tpl = @'
$ErrorActionPreference = 'Stop'
$key = '@@KEY@@'
if ('@@ADMIN@@' -eq '1') {
    $dir  = Join-Path $env:ProgramData 'ssh'
    $path = Join-Path $dir 'administrators_authorized_keys'
} else {
    $dir  = Join-Path $env:USERPROFILE '.ssh'
    $path = Join-Path $dir 'authorized_keys'
}
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType File -Path $path -Force | Out-Null }
$lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
if ($lines -notcontains $key) {
    Add-Content -LiteralPath $path -Value $key
    Write-Output "added:$path"
} else {
    Write-Output "present:$path"
}
if ('@@ADMIN@@' -eq '1') {
    # sshd refuses the file unless it is owned by Administrators/SYSTEM only.
    icacls $path /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    Write-Output "acl:$path"
}
'@
    $src = $tpl.Replace('@@KEY@@', $key).Replace('@@ADMIN@@', $admin)
    return (Invoke-SshPowerShell -Dest $Dest -SshArgs $SshArgs -Script $src)
}

# One hop of the wizard. $Role 'jump' skips the key-pair copy: ProxyJump
# authenticates end-to-end from this machine, so a jump host never needs the
# private key and putting it there would be a gratuitous secret spill.
function script:Set-RemoteSshKeyOnHost {
    param(
        [Parameter(Mandatory)][string]$Hop,
        [Parameter(Mandatory)][string]$KeyPath,
        [ValidateSet('jump', 'target')][string]$Role = 'target'
    )

    $split = Split-SshHop -Spec $Hop
    $dest = $split.Dest
    $sshArgs = @()
    if ($split.Port) { $sshArgs += @('-p', $split.Port) }

    $remoteUser = ''
    $remoteHost = $dest
    if ($dest -match '^(.+)@(.+)$') { $remoteUser = $Matches[1]; $remoteHost = $Matches[2] }

    Write-Host ''
    Write-Host "--- Copy public key to $Hop ---"
    $ans = Read-SshSetupAnswer 'Install the key for passwordless login? [Y/n] '
    $kind = 'posix'
    if (Test-SshSetupYes -Answer $ans -DefaultYes) {
        Write-Host "Probing $dest ..."
        $probe = Get-SshRemoteKind -Dest $dest -SshArgs $sshArgs
        $kind = $probe.Kind
        if ($kind -eq 'unknown') {
            Write-Host 'Could not identify the remote OS.'
            $a = Read-SshSetupAnswer "Is $dest a Windows (OpenSSH sshd) machine? [y/N] "
            $kind = if (Test-SshSetupYes -Answer $a) { 'windows' } else { 'posix' }
        }

        $pub = (Get-Content -LiteralPath ($KeyPath + '.pub') -Raw).Trim()
        if ($kind -eq 'windows') {
            $useAdmin = $false
            if ($probe.Admin) {
                $who = if ($probe.User) { $probe.User } else { 'The remote account' }
                Write-Host ''
                Write-Host "$who is in the remote Administrators group."
                Write-Host "sshd's default ``Match Group administrators`` rule reads ONLY"
                Write-Host 'C:\ProgramData\ssh\administrators_authorized_keys for such accounts —'
                Write-Host 'a key in ~/.ssh/authorized_keys would be ignored. That file is shared'
                Write-Host 'by every administrator on the box.'
                $a = Read-SshSetupAnswer 'Use administrators_authorized_keys? [Y/n] '
                $useAdmin = Test-SshSetupYes -Answer $a -DefaultYes
            }
            $out = Install-SshKeyWindows -Dest $dest -SshArgs $sshArgs -PublicKey $pub -UseAdminFile:$useAdmin
        } else {
            $out = Install-SshKeyPosix -Dest $dest -SshArgs $sshArgs -PublicKey $pub
        }
        if (-not $out) {
            Write-Warning "Key install on $dest produced no output — verify manually."
            return $false
        }
        $out | ForEach-Object { Write-Host $_ }
    }

    # --- copy the key pair (final target only) ---
    if ($Role -eq 'target') {
        Write-Host ''
        Write-Host '--- Copy key pair to remote ---'
        Write-Host 'This lets the remote machine use the same key (e.g. for GitHub).'
        $a = Read-SshSetupAnswer "Copy private+public key to ${dest}:~/.ssh/? [y/N] "
        if (Test-SshSetupYes -Answer $a) {
            $scpArgs = @()
            if ($split.Port) { $scpArgs += @('-P', $split.Port) }
            $name = Split-Path -Leaf $KeyPath
            $remoteDir = if ($kind -eq 'windows') { "${dest}:.ssh/" } else { "${dest}:~/.ssh/" }
            & scp @scpArgs $KeyPath ($KeyPath + '.pub') $remoteDir
            if ($LASTEXITCODE -eq 0) {
                if ($kind -eq 'windows') {
                    $perm = @'
$ErrorActionPreference = 'SilentlyContinue'
$k = Join-Path (Join-Path $env:USERPROFILE '.ssh') '@@NAME@@'
if (Test-Path -LiteralPath $k) {
    icacls $k /inheritance:r /grant ("{0}:F" -f $env:USERNAME) | Out-Null
    Write-Output "perm:$k"
}
'@
                    Invoke-SshPowerShell -Dest $dest -SshArgs $sshArgs -Script ($perm.Replace('@@NAME@@', $name)) |
                        ForEach-Object { Write-Host $_ }
                } else {
                    Invoke-SshRemote -Dest $dest -SshArgs $sshArgs `
                        -Command "chmod 600 ~/.ssh/$name && chmod 644 ~/.ssh/$name.pub" | Out-Null
                }
                Write-Host 'Key copied and permissions set.'
            } else {
                Write-Warning 'scp failed.'
            }
        }
    }

    # --- local ~/.ssh/config ---
    Write-Host ''
    Write-Host '--- Local SSH config ---'
    $a = Read-SshSetupAnswer 'Add/update host alias in local ~/.ssh/config? [Y/n] '
    if (-not (Test-SshSetupYes -Answer $a -DefaultYes)) { return $true }

    $found = Find-SshHostBlock -Alias $remoteHost -KeyPath $KeyPath
    if ($found) {
        Write-Host ''
        Write-Host "Host `"$remoteHost`" is already configured in $($found.File):"
        $found.Block | ForEach-Object { Write-Host $_ }

        if ($found.KeyPresent) {
            Write-Host ''
            Write-Host "This key ($KeyPath) is already set for $remoteHost — nothing to do."
            $script:SshSetupHostAlias = $remoteHost
            return $true
        }

        $action = 'insert'
        if ($found.HasIdentityFile) {
            $a = Read-SshSetupAnswer 'This host already has an IdentityFile. [r]eplace / [a]dd another / [s]kip? [r] '
            switch -Regex ($a) {
                '^[Aa]' { $action = 'add' }
                '^[Ss]' { $action = '' }
                default { $action = 'replace' }
            }
        }
        if (-not $action) { return $true }

        $ido = $false
        if (-not $found.HasIdentitiesOnly) {
            $a = Read-SshSetupAnswer 'Also add `IdentitiesOnly yes` so only this key is offered? [y/N] '
            $ido = Test-SshSetupYes -Answer $a
        }
        if (Add-SshIdentityFile -File $found.File -Alias $remoteHost -KeyPath $KeyPath -Action $action -IdentitiesOnly:$ido) {
            Write-Host "Updated $($found.File)."
        } else {
            Write-Warning "Failed to update $($found.File)."
        }
        $script:SshSetupHostAlias = $remoteHost
        return $true
    }

    # New host — append a fresh block.
    $alias = Read-SshSetupAnswer "Host alias [$remoteHost]: "
    if (-not $alias) { $alias = $remoteHost }
    $hostName = Read-SshSetupAnswer "HostName (IP or FQDN) [$remoteHost]: "
    if (-not $hostName) { $hostName = $remoteHost }
    $defaultUser = if ($remoteUser) { $remoteUser } else { $env:USERNAME }
    $user = Read-SshSetupAnswer "User [$defaultUser]: "
    if (-not $user) { $user = $defaultUser }
    $a = Read-SshSetupAnswer 'Add IdentitiesOnly yes? [y/N] '
    $ido = Test-SshSetupYes -Answer $a

    $sshDir = Split-Path -Parent (Get-SshConfigRoot)
    $configFile = Get-SshConfigRoot
    $wroteConfigD = $false
    if (Test-Path -LiteralPath (Join-Path $sshDir 'config.d')) {
        $a = Read-SshSetupAnswer 'Write to ~/.ssh/config.d/ instead of ~/.ssh/config? [Y/n] '
        if (Test-SshSetupYes -Answer $a -DefaultYes) {
            $configFile = Join-Path (Join-Path $sshDir 'config.d') "host_$alias"
            $wroteConfigD = $true
        }
    }

    $block = @('', "Host $alias", "    HostName $hostName", "    User $user")
    if ($split.Port) { $block += "    Port $($split.Port)" }
    $block += "    IdentityFile $(ConvertTo-SshTildePath $KeyPath)"
    if ($ido) { $block += '    IdentitiesOnly yes' }

    Write-Host ''
    Write-Host "Will append to ${configFile}:"
    $block | ForEach-Object { Write-Host $_ }
    $a = Read-SshSetupAnswer 'Confirm? [Y/n] '
    if (-not (Test-SshSetupYes -Answer $a -DefaultYes)) { return $true }

    New-Item -ItemType Directory -Path (Split-Path -Parent $configFile) -Force | Out-Null
    Add-Content -LiteralPath $configFile -Value $block -Encoding utf8NoBOM
    if (-not $IsWindows) { & chmod 600 $configFile 2>$null }
    Write-Host 'Config written.'
    $script:SshSetupHostAlias = $alias

    # A drop-in that nothing Includes silently does not load.
    if ($wroteConfigD -and -not (Test-SshConfigDInclude)) {
        Write-Host ''
        Write-Host 'Note: ~/.ssh/config has no `Include` for config.d/* — this entry will not load.'
        $a = Read-SshSetupAnswer 'Add `Include ~/.ssh/config.d/*` to ~/.ssh/config now? [Y/n] '
        if (Test-SshSetupYes -Answer $a -DefaultYes) {
            $null = Add-SshConfigDInclude
            Write-Host 'Include directive added.'
        }
    }
    return $true
}

# --- key picker -------------------------------------------------------------

function script:Select-SshSetupKey {
    param([Parameter(Mandatory)][string]$HostHint)

    if ($env:SSH_SETUP_KEY) {
        $p = $env:SSH_SETUP_KEY
        if ($p.StartsWith('~')) { $p = Join-Path (Get-SshSetupHome) $p.Substring(1).TrimStart('/', '\') }
        if (-not (Restore-SshPublicKey -KeyPath $p)) { return $null }
        return $p
    }

    Write-Host ''
    Write-Host 'Existing keys in ~/.ssh/:'
    $keys = Get-SshLocalKey
    $createNew = $false
    $keyPath = $null

    if ($keys.Count -gt 0) {
        foreach ($k in $keys) {
            if ($k.HasPub) { Write-Host "  $($k.Path)" } else { Write-Host "  $($k.Path)  (no .pub)" }
        }
        $a = Read-SshSetupAnswer 'Use an existing key? [Y/n] '
        if (-not (Test-SshSetupYes -Answer $a -DefaultYes)) {
            $createNew = $true
        } else {
            $keyPath = Read-SshSetupAnswer 'Enter key path (without .pub): '
            if ($keyPath.StartsWith('~')) { $keyPath = Join-Path (Get-SshSetupHome) $keyPath.Substring(1).TrimStart('/', '\') }
            if (-not (Test-Path -LiteralPath $keyPath) -and -not (Test-Path -LiteralPath ($keyPath + '.pub'))) {
                Write-Warning "Key not found: $keyPath"
                return $null
            }
        }
    } else {
        Write-Host '  (none found)'
        $createNew = $true
    }

    if ($createNew) {
        Write-Host ''
        Write-Host '--- Create new SSH key ---'
        $algo = Read-SshSetupAnswer 'Algorithm [ed25519] (ed25519/ed25519-sk/rsa): '
        if (-not $algo) { $algo = 'ed25519' }
        $defaultName = "id_${algo}_$HostHint"
        $name = Read-SshSetupAnswer "Key name [$defaultName]: "
        if (-not $name) { $name = $defaultName }
        $keyPath = Join-Path (Join-Path (Get-SshSetupHome) '.ssh') $name
        if (Test-Path -LiteralPath $keyPath) {
            Write-Warning "Key already exists: $keyPath"
            return $null
        }
        $defaultComment = "$env:USERNAME@$env:COMPUTERNAME -> $HostHint"
        $comment = Read-SshSetupAnswer "Comment [$defaultComment]: "
        if (-not $comment) { $comment = $defaultComment }

        $a = Read-SshSetupAnswer 'Set a passphrase? [y/N] '
        $keygenArgs = @('-t', $algo, '-f', $keyPath, '-C', $comment)
        if (-not (Test-SshSetupYes -Answer $a)) { $keygenArgs += @('-N', '') }
        if ($algo -eq 'rsa') { $keygenArgs += @('-b', '4096') }

        New-Item -ItemType Directory -Path (Split-Path -Parent $keyPath) -Force | Out-Null
        Write-Host ''
        Write-Host "> ssh-keygen $($keygenArgs -join ' ')"
        & ssh-keygen @keygenArgs
        if ($LASTEXITCODE -ne 0) { return $null }
        Write-Host ''
        Write-Host "Key created: $keyPath"
    }

    # A key taken off disk may have lost its public half (an agent-only import, a
    # partial copy from another machine). The install step needs the .pub file,
    # and noticing only at that point produces a baffling errno message.
    if (-not (Restore-SshPublicKey -KeyPath $keyPath)) { return $null }
    return $keyPath
}

# --- public entry point -----------------------------------------------------

function Set-RemoteSshKey {
    <#
    .SYNOPSIS
    Interactive SSH key setup for a remote machine, ProxyJump chain included.

    .DESCRIPTION
    Picks or creates a key, installs its public half on the remote, optionally
    copies the pair over, and wires the key into the local ~/.ssh/config.
    When the target is reached through one or more ProxyJump hosts, every hop is
    set up too, outermost first - ssh only forwards TCP through a jump, so each
    hop needs its own authorized_keys entry or it keeps asking for a password.

    Aliased to ssh-setup-remote, the same command name the Unix dotfiles use.

    .PARAMETER Target
    [user@]host - an ~/.ssh/config alias or a literal destination.

    .EXAMPLE
    Set-RemoteSshKey zr

    .EXAMPLE
    ssh-setup-remote zr
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Target)

    Write-Host ''
    Write-Host "=== SSH Key Setup for $Target ==="

    $hostHint = ($Target -replace '^.*@', '') -replace ':.*$', ''

    # Resolve the chain BEFORE anything else so the run can be described up
    # front, instead of silently setting up the last hop only.
    $hosts = @(Get-SshJumpChain -Target $Target) + @($Target)
    $total = $hosts.Count
    if ($total -gt 1) {
        Write-Host ''
        Write-Host "ProxyJump chain detected: $($hosts -join ' -> ')"
        Write-Host 'Each hop needs its own key in its own authorized_keys - ProxyJump only'
        Write-Host 'forwards TCP, so the jump host never sees your private key.'
    }

    $keyPath = Select-SshSetupKey -HostHint $hostHint
    if (-not $keyPath) { return }

    $script:SshSetupHostAlias = ''
    $ok = $true
    for ($i = 0; $i -lt $total; $i++) {
        $hop = $hosts[$i]
        $role = if ($i -eq $total - 1) { 'target' } else { 'jump' }

        if ($total -gt 1) {
            Write-Host ''
            Write-Host '========================================'
            Write-Host "[$($i + 1)/$total] $hop ($role)"
            Write-Host '========================================'
        }

        # BatchMode makes this a non-blocking probe: it fails immediately
        # instead of prompting for a password.
        $split = Split-SshHop -Spec $hop
        $probeArgs = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
        if ($split.Port) { $probeArgs += @('-p', $split.Port) }
        $null = Invoke-SshRemote -Dest $split.Dest -SshArgs $probeArgs -Command 'true'
        if ($script:SshSetupLastExit -eq 0) {
            Write-Host "$hop already accepts key-based login."
            $a = Read-SshSetupAnswer 'Set it up anyway? [y/N] '
            if (-not (Test-SshSetupYes -Answer $a)) {
                Write-Host 'Skipped.'
                continue
            }
        }

        if (-not (Set-RemoteSshKeyOnHost -Hop $hop -KeyPath $keyPath -Role $role)) {
            $ok = $false
            Write-Warning "Setup for $hop failed."
            if ($role -eq 'jump') {
                $a = Read-SshSetupAnswer 'Continue with the rest of the chain? [y/N] '
                if (-not (Test-SshSetupYes -Answer $a)) { break }
            }
        }
    }

    Write-Host ''
    Write-Host '=== Done! ==='
    $final = if ($script:SshSetupHostAlias) { $script:SshSetupHostAlias } else { $Target }
    Write-Host "Test with: ssh $final"
    if (-not $ok) { Write-Warning 'At least one hop did not complete.' }
}

# Same command name as the Unix side - the whole point of the parity work.
Set-Alias -Name ssh-setup-remote -Value Set-RemoteSshKey -Scope Global -Force
