# 30_apps.ps1 — app control, system audio, and clipboard helpers. Native
# PowerShell equivalents of the macOS/Linux app*/sys*/x helpers, same verb names.

# --- app control (applaunch / appquit / apprestart / apprunning / applist) ---
function applaunch {
    param([Parameter(Mandatory)][string]$Name)
    Start-Process $Name
}
function appquit {
    param([Parameter(Mandatory)][string]$Name)
    $proc = $Name -replace '\.exe$', ''
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force
}
function apprestart {
    param([Parameter(Mandatory)][string]$Name)
    appquit $Name; Start-Sleep 1; applaunch $Name
}
function apprunning {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Process -Name ($Name -replace '\.exe$', '') -ErrorAction SilentlyContinue)
}
function applist {
    Get-Process | Where-Object { $_.MainWindowTitle } | Select-Object Name, Id, MainWindowTitle | Sort-Object Name
}

# --- system audio (sysvol / sysmute) ---
# Absolute level + explicit mute use AudioDeviceCmdlets when installed; a
# dependency-free media-key fallback covers up/down and mute-toggle everywhere.
function script:Initialize-VolumeKeys {
    if (-not ('Native.WinVol' -as [type])) {
        Add-Type -Name WinVol -Namespace Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
'@
    }
}
function script:Send-VolumeKey {
    param([byte]$Vk, [int]$Times = 1)
    Initialize-VolumeKeys
    for ($i = 0; $i -lt $Times; $i++) { [Native.WinVol]::keybd_event($Vk, 0, 0, [System.UIntPtr]::Zero) }
}

function sysvol {
    param([Parameter(Position = 0)][string]$Arg, [Parameter(Position = 1)][int]$Amount = 10)
    $hasCmdlet = [bool](Get-Command Set-AudioDevice -ErrorAction SilentlyContinue)
    switch ($Arg) {
        'up'   { if ($hasCmdlet) { $c = [int]((Get-AudioDevice -PlaybackVolume) -replace '\D'); Set-AudioDevice -PlaybackVolume ([math]::Min(100, $c + $Amount)) } else { Send-VolumeKey 0xAF ([math]::Ceiling($Amount / 2)) } }
        'down' { if ($hasCmdlet) { $c = [int]((Get-AudioDevice -PlaybackVolume) -replace '\D'); Set-AudioDevice -PlaybackVolume ([math]::Max(0, $c - $Amount)) } else { Send-VolumeKey 0xAE ([math]::Ceiling($Amount / 2)) } }
        ''     { if ($hasCmdlet) { Get-AudioDevice -PlaybackVolume } else { Write-Warning 'sysvol: install AudioDeviceCmdlets for level readout; use `sysvol up|down`' } }
        default {
            if ($Arg -match '^\d+$') {
                if ($hasCmdlet) { Set-AudioDevice -PlaybackVolume ([int]$Arg) }
                else { Write-Warning 'sysvol <N> (absolute) needs AudioDeviceCmdlets; use `sysvol up|down` instead' }
            } else { Write-Warning "sysvol: usage: sysvol [up|down [step] | <0-100>]" }
        }
    }
}

function sysmute {
    param([Parameter(Position = 0)][ValidateSet('', 'on', 'off', 'toggle')][string]$State = 'toggle')
    if (Get-Command Set-AudioDevice -ErrorAction SilentlyContinue) {
        switch ($State) {
            'on'  { Set-AudioDevice -PlaybackMute $true }
            'off' { Set-AudioDevice -PlaybackMute $false }
            default { Set-AudioDevice -PlaybackMuteToggle }
        }
    } else {
        Send-VolumeKey 0xAD 1   # VK_VOLUME_MUTE toggles
        if ($State -in 'on', 'off') { Write-Warning 'sysmute on/off needs AudioDeviceCmdlets; toggled instead' }
    }
}

# --- clipboard / open (x) ---
# x copy [text]   copy args (or piped stdin) to the clipboard
# x paste         print the clipboard
# x open <target> open a file/URL with its default handler
function x {
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('copy', 'paste', 'open')][string]$Action,
        [Parameter(ValueFromRemainingArguments)][string[]]$Rest
    )
    switch ($Action) {
        'copy'  {
            $data = if ($Rest) { $Rest -join ' ' } else { ($input | Out-String).TrimEnd("`r", "`n") }
            Set-Clipboard -Value $data
        }
        'paste' { Get-Clipboard }
        'open'  { if ($Rest) { Start-Process ($Rest -join ' ') } else { Start-Process . } }
    }
}
