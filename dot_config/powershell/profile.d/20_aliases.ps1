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

# --- git shortcuts ---
function gs { git status @args }
function gd { git diff @args }
function ga { git add @args }
function gc { git commit @args }
function gp { git push @args }
function gl { git log --oneline --graph --decorate @args }

# --- shell / dotfiles management ---
# reload the current session's profile
function reload { . $PROFILE }
# jump to the chezmoi source dir
function chezmoi-cd { Set-Location (chezmoi source-path) }
# chezmoi apply / update, then reload (twins of the unix `cas` / `cau`)
function cas { chezmoi apply @args; . $PROFILE }
function cau { chezmoi update @args; . $PROFILE }

# --- run-for: time-box a command (e.g. `run-for 5 ping example.com`) ---
function run-for {
    param(
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Command
    )
    $job = Start-Job -ScriptBlock { param($c) & $c[0] @($c[1..($c.Length-1)]) } -ArgumentList (,$Command)
    if (Wait-Job $job -Timeout $Seconds) { Receive-Job $job } else { Stop-Job $job; Write-Warning "run-for: timed out after ${Seconds}s" }
    Remove-Job $job -Force
}
