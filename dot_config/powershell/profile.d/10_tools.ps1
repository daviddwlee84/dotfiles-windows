# 10_tools.ps1 — activate CLI tools. Each block no-ops if the tool is absent,
# so a partial install (or the minimal role) never errors the prompt.

# starship prompt
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (& starship init powershell)
}

# zoxide — smarter cd (rebinds `cd` to `z`)
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell --cmd cd | Out-String) })
}

# mise — runtime version manager (node/bun/uv/…)
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Invoke-Expression (& mise activate pwsh | Out-String)
}

# atuin — SQLite shell history with fuzzy search (Ctrl+R)
if (Get-Command atuin -ErrorAction SilentlyContinue) {
    Invoke-Expression (& atuin init powershell | Out-String)
}

# fzf — fuzzy finder + PSFzf key bindings (Ctrl+t files, Ctrl+r history)
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    $env:FZF_DEFAULT_OPTS = '--height 40% --layout=reverse --border'
    if (Get-Command fd -ErrorAction SilentlyContinue) {
        $env:FZF_DEFAULT_COMMAND = 'fd --hidden --strip-cwd-prefix --exclude .git'
    }
    if (Get-Module -ListAvailable -Name PSFzf) {
        Import-Module PSFzf
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
    }
}

# direnv — per-directory environments
if (Get-Command direnv -ErrorAction SilentlyContinue) {
    Invoke-Expression (& direnv hook pwsh | Out-String)
}

# television (tv) — fuzzy picker shell integration. tv 0.15+ renamed the shell
# value `powershell` -> `power-shell`; older builds used `powershell`. Try the
# new spelling first, fall back, and only eval non-empty output so a version
# mismatch never errors the prompt.
if (Get-Command tv -ErrorAction SilentlyContinue) {
    $tvInit = (tv init power-shell 2>$null | Out-String)
    if (-not $tvInit.Trim()) { $tvInit = (tv init powershell 2>$null | Out-String) }
    if ($tvInit.Trim()) { try { Invoke-Expression $tvInit } catch { $null = $_ } }
}
