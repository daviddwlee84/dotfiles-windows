# 20_aliases.ps1 — aliases and small helper functions. Modern-CLI replacements
# are guarded so they only shadow the builtin when the tool is installed.

# --- modern replacements ---
if (Get-Command eza -ErrorAction SilentlyContinue) {
    function ll { eza -l  --icons --git @args }
    function la { eza -la --icons --git @args }
    function lt { eza --tree --level=2 --icons @args }
    Remove-Item Alias:ls -ErrorAction SilentlyContinue
    function ls { eza --icons @args }
}
if (Get-Command bat -ErrorAction SilentlyContinue) {
    Remove-Item Alias:cat -ErrorAction SilentlyContinue
    function cat { bat @args }
    if (-not $env:BAT_THEME) { $env:BAT_THEME = 'ansi' }
}
if (Get-Command nvim -ErrorAction SilentlyContinue) {
    Set-Alias -Name vim -Value nvim -Scope Global
    Set-Alias -Name vi  -Value nvim -Scope Global
}
if (Get-Command lazygit -ErrorAction SilentlyContinue) {
    Set-Alias -Name lg -Value lazygit -Scope Global
}

# --- unix muscle-memory ---
# `which foo` — resolve a command like the unix tool. pwsh's native equivalent
# is Get-Command (alias gcm); this prints just the path for executables and a
# short description for aliases / functions / cmdlets.
function which {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Name)
    foreach ($n in $Name) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if (-not $c) { Write-Error "which: $n not found"; continue }
        switch ($c.CommandType) {
            'Application' { $c.Source }
            'Alias'       { '{0}: aliased to {1}' -f $n, $c.Definition }
            default       { '{0}: {1}' -f $n, $c.CommandType }
        }
    }
}

# unix / mac command names → Windows equivalents (muscle memory)
function ifconfig { ipconfig @args }
function open { Invoke-Item @args }          # open a file/dir in its default app
function pbcopy { $input | Set-Clipboard }   # pipe into it: some-cmd | pbcopy
function pbpaste { Get-Clipboard }
function reboot { Restart-Computer @args }   # unix `reboot`; add -Force to skip prompts
function touch {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path)
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTime = Get-Date }
        else { New-Item -ItemType File -Path $p -Force | Out-Null }
    }
}

# --- git shortcuts live in 21_git.ps1 (full oh-my-zsh git-plugin port) ---

# --- shell / dotfiles management ---
# reload the current session's profile
function reload { . $PROFILE }
# jump to the chezmoi source dir
function chezmoi-cd { Set-Location (chezmoi source-path) }
# chezmoi apply / update, then reload (twins of the unix `cas` / `cau`)
# cau uses --init so newly-added prompts get asked on pull (noop if none added).
function cas { chezmoi apply @args; . $PROFILE }
function cau { chezmoi update --init @args; . $PROFILE }

# --- run-for: time-box an external command (e.g. `run-for 5 ping example.com`) ---
function run-for {
    param(
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Command
    )
    $rest = if ($Command.Count -gt 1) { $Command[1..($Command.Count - 1)] } else { @() }
    $p = Start-Process -FilePath $Command[0] -ArgumentList $rest -PassThru -NoNewWindow
    if (-not $p.WaitForExit($Seconds * 1000)) {
        $p.Kill()
        Write-Warning "run-for: timed out after ${Seconds}s"
    }
}
