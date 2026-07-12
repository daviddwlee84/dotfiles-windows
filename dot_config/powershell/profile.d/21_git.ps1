# 21_git.ps1 — the oh-my-zsh `git` plugin, ported to native PowerShell functions.
#
# Mirrors ~/.oh-my-zsh/plugins/git (the same alias set the companion macOS/Linux
# dotfiles get for free) so git muscle memory carries across to Windows / pwsh.
# `gst`, `gco`, `gcam`, `glol`, `gp`, `gl`, … all mean what they mean under omz.
#
# Deliberate deviations from upstream omz (Windows-specific):
#   * gcm / gm are NOT defined — they would shadow the PowerShell built-in
#     aliases `gcm` (Get-Command) and `gm` (Get-Member), which are worth keeping.
#     Use `gswm` (switch to main) and the gma/gmc/gms/gmff merge family instead.
#   * gl = `git pull` (upstream omz default), replacing this repo's earlier
#     gl = git log. For a graph log use glo / glog / glol / glola / glod.
#   * gs is kept as a bonus alias for `git status` (not an omz binding) so the
#     older habit still resolves; `gst` is the omz-canonical one.
#   * PowerShell command names are case-INSENSITIVE, so omz's case-only variants
#     collapse into their lowercase twin: gbD -> gbd, gcB -> gcb, gbgD -> gbgd.
#     Only the safe (lowercase) form is defined, so a mistyped `gbD` never force-
#     deletes. For the force variants use the explicit flag: `gbd --force <b>`,
#     `gco -B <b>`.
#   * A few zsh-pipeline / GUI-only aliases are intentionally omitted — see the
#     "not ported" note at the foot of this file.
#
# Static one-to-one passthroughs are generated from the table below; anything
# that needs the current/main/develop branch, a pipeline, or `&&` is written out
# explicitly further down.

# --- branch helpers (ports of omz git_current_branch / _main_branch / _develop_branch) ---
function git_current_branch {
    $ref = git symbolic-ref --quiet --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { $ref = git rev-parse --short HEAD 2>$null }
    $ref
}
function git_main_branch {
    git rev-parse --git-dir *> $null
    if ($LASTEXITCODE -ne 0) { return }
    foreach ($loc in 'refs/heads', 'refs/remotes/origin', 'refs/remotes/upstream') {
        foreach ($name in 'main', 'trunk', 'mainline', 'default', 'stable', 'master') {
            git show-ref -q --verify "$loc/$name" 2>$null
            if ($LASTEXITCODE -eq 0) { return $name }
        }
    }
    'master'
}
function git_develop_branch {
    git rev-parse --git-dir *> $null
    if ($LASTEXITCODE -ne 0) { return }
    foreach ($name in 'dev', 'devel', 'development') {
        git show-ref -q --verify "refs/heads/$name" 2>$null
        if ($LASTEXITCODE -eq 0) { return $name }
    }
    'develop'
}

# --- static passthroughs: <function name> = <args appended after `git`> ---
# Generated from the omz git plugin; each becomes `function <name> { git <args> @args }`.
$GitAliases = [ordered]@{
    'g'         = ''
    'ga'        = 'add'
    'gaa'       = 'add --all'
    'gapa'      = 'add --patch'
    'gau'       = 'add --update'
    'gav'       = 'add --verbose'
    'gam'       = 'am'
    'gama'      = 'am --abort'
    'gamc'      = 'am --continue'
    'gamscp'    = 'am --show-current-patch'
    'gams'      = 'am --skip'
    'gap'       = 'apply'
    'gapt'      = 'apply --3way'
    'gbs'       = 'bisect'
    'gbsb'      = 'bisect bad'
    'gbsg'      = 'bisect good'
    'gbsn'      = 'bisect new'
    'gbso'      = 'bisect old'
    'gbsr'      = 'bisect reset'
    'gbss'      = 'bisect start'
    'gbl'       = 'blame -w'
    'gb'        = 'branch'
    'gba'       = 'branch --all'
    'gbd'       = 'branch --delete'
    'gbm'       = 'branch --move'
    'gbnm'      = 'branch --no-merged'
    'gbr'       = 'branch --remote'
    'gco'       = 'checkout'
    'gcor'      = 'checkout --recurse-submodules'
    'gcb'       = 'checkout -b'
    'gcp'       = 'cherry-pick'
    'gcpa'      = 'cherry-pick --abort'
    'gcpc'      = 'cherry-pick --continue'
    'gclean'    = 'clean --interactive -d'
    'gcl'       = 'clone --recurse-submodules'
    'gclf'      = 'clone --recursive --shallow-submodules --filter=blob:none --also-filter-submodules'
    'gcam'      = 'commit --all --message'
    'gcas'      = 'commit --all --signoff'
    'gcasm'     = 'commit --all --signoff --message'
    'gcs'       = 'commit --gpg-sign'
    'gcss'      = 'commit --gpg-sign --signoff'
    'gcssm'     = 'commit --gpg-sign --signoff --message'
    'gcmsg'     = 'commit --message'
    'gcsm'      = 'commit --signoff --message'
    'gc'        = 'commit --verbose'
    'gca'       = 'commit --verbose --all'
    'gca!'      = 'commit --verbose --all --amend'
    'gcan!'     = 'commit --verbose --all --no-edit --amend'
    'gcans!'    = 'commit --verbose --all --signoff --no-edit --amend'
    'gcann!'    = 'commit --verbose --all --date=now --no-edit --amend'
    'gc!'       = 'commit --verbose --amend'
    'gcn'       = 'commit --verbose --no-edit'
    'gcn!'      = 'commit --verbose --no-edit --amend'
    'gcf'       = 'config --list'
    'gcfu'      = 'commit --fixup'
    'gd'        = 'diff'
    'gdca'      = 'diff --cached'
    'gdcw'      = 'diff --cached --word-diff'
    'gds'       = 'diff --staged'
    'gdw'       = 'diff --word-diff'
    'gdt'       = 'diff-tree --no-commit-id --name-only -r'
    'gf'        = 'fetch'
    'gfo'       = 'fetch origin'
    'gg'        = 'gui citool'
    'gga'       = 'gui citool --amend'
    'ghh'       = 'help'
    'glgg'      = 'log --graph'
    'glgga'     = 'log --graph --decorate --all'
    'glgm'      = 'log --graph --max-count=10'
    'glo'       = 'log --oneline --decorate'
    'glog'      = 'log --oneline --decorate --graph'
    'gloga'     = 'log --oneline --decorate --graph --all'
    'glg'       = 'log --stat'
    'glgp'      = 'log --stat --patch'
    'gma'       = 'merge --abort'
    'gmc'       = 'merge --continue'
    'gms'       = 'merge --squash'
    'gmff'      = 'merge --ff-only'
    'gmtl'      = 'mergetool --no-prompt'
    'gmtlvim'   = 'mergetool --no-prompt --tool=vimdiff'
    'gl'        = 'pull'
    'gpr'       = 'pull --rebase'
    'gprv'      = 'pull --rebase -v'
    'gpra'      = 'pull --rebase --autostash'
    'gprav'     = 'pull --rebase --autostash -v'
    'gp'        = 'push'
    'gpd'       = 'push --dry-run'
    'gpf!'      = 'push --force'
    'gpv'       = 'push --verbose'
    'gpod'      = 'push origin --delete'
    'gpu'       = 'push upstream'
    'grb'       = 'rebase'
    'grba'      = 'rebase --abort'
    'grbc'      = 'rebase --continue'
    'grbi'      = 'rebase --interactive'
    'grbo'      = 'rebase --onto'
    'grbs'      = 'rebase --skip'
    'grf'       = 'reflog'
    'gr'        = 'remote'
    'grv'       = 'remote --verbose'
    'gra'       = 'remote add'
    'grrm'      = 'remote remove'
    'grmv'      = 'remote rename'
    'grset'     = 'remote set-url'
    'grup'      = 'remote update'
    'grh'       = 'reset'
    'gru'       = 'reset --'
    'grhh'      = 'reset --hard'
    'grhk'      = 'reset --keep'
    'grhs'      = 'reset --soft'
    'grs'       = 'restore'
    'grss'      = 'restore --source'
    'grst'      = 'restore --staged'
    'grev'      = 'revert'
    'greva'     = 'revert --abort'
    'grevc'     = 'revert --continue'
    'grm'       = 'rm'
    'grmc'      = 'rm --cached'
    'gcount'    = 'shortlog --summary --numbered'
    'gsh'       = 'show'
    'gsps'      = 'show --pretty=short --show-signature'
    'gstall'    = 'stash --all'
    'gstaa'     = 'stash apply'
    'gstc'      = 'stash clear'
    'gstd'      = 'stash drop'
    'gstl'      = 'stash list'
    'gstp'      = 'stash pop'
    'gsts'      = 'stash show --patch'
    'gst'       = 'status'
    'gs'        = 'status'   # bonus (not omz): keep the old muscle memory working
    'gss'       = 'status --short'
    'gsb'       = 'status --short --branch'
    'gsi'       = 'submodule init'
    'gsu'       = 'submodule update'
    'gsd'       = 'svn dcommit'
    'gsr'       = 'svn rebase'
    'gsw'       = 'switch'
    'gswc'      = 'switch --create'
    'gstu'      = 'stash push --include-untracked'
    'gta'       = 'tag --annotate'
    'gts'       = 'tag --sign'
    'gignore'   = 'update-index --assume-unchanged'
    'gunignore' = 'update-index --no-assume-unchanged'
    'gwch'      = 'log --patch --abbrev-commit --pretty=medium --raw'
    'gwt'       = 'worktree'
    'gwta'      = 'worktree add'
    'gwtls'     = 'worktree list'
    'gwtmv'     = 'worktree move'
    'gwtrm'     = 'worktree remove'
}
foreach ($name in $GitAliases.Keys) {
    # A built-in alias (e.g. gc->Get-Content, gp->Get-ItemProperty, gl->Get-Location)
    # outranks a same-named function, so drop it first — otherwise the function is
    # dead. gcm (Get-Command) / gm (Get-Member) are deliberately never in this table.
    Remove-Item -Path "Alias:$name" -Force -ErrorAction SilentlyContinue
    Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create("git $($GitAliases[$name]) @args"))
}

# --- dynamic: literal `@{upstream}` (must be quoted so pwsh doesn't parse a hashtable) ---
function gdup { git diff '@{upstream}' @args }

# --- dynamic: pretty-format graph logs (single-quoted format; --all/--stat/date variants) ---
function glol  { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ar) %C(bold blue)<%an>%Creset' @args }
function glola { glol --all @args }
function glols { glol --stat @args }
function glod  { git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ad) %C(bold blue)<%an>%Creset' @args }
function glods { glod --date=short @args }
function glp   { param([string]$Format) if ($Format) { git log --pretty=$Format } }

# --- dynamic: operate on the main / develop / current branch ---
function gcd   { git checkout (git_develop_branch) @args }
function gswd  { git switch (git_develop_branch) @args }
function gswm  { git switch (git_main_branch) @args }
function grbd  { git rebase (git_develop_branch) @args }
function grbm  { git rebase (git_main_branch) @args }
function grbom { git rebase "origin/$(git_main_branch)" @args }
function grbum { git rebase "upstream/$(git_main_branch)" @args }
function gmom  { git merge "origin/$(git_main_branch)" @args }
function gmum  { git merge "upstream/$(git_main_branch)" @args }
function gprom  { git pull --rebase origin (git_main_branch) @args }
function gpromi { git pull --rebase=interactive origin (git_main_branch) @args }
function gprum  { git pull --rebase upstream (git_main_branch) @args }
function gprumi { git pull --rebase=interactive upstream (git_main_branch) @args }
function gluc  { git pull upstream (git_current_branch) @args }
function glum  { git pull upstream (git_main_branch) @args }
function ggsup { git branch --set-upstream-to="origin/$(git_current_branch)" @args }
function gpsup { git push --set-upstream origin (git_current_branch) @args }
function groh  { git reset "origin/$(git_current_branch)" --hard @args }

# --- dynamic: push/pull to a branch (defaults to the current branch, omz ggX family) ---
function ggl { $b = if ($args.Count) { $args[0] } else { git_current_branch }; git pull origin $b }
function ggp { $b = if ($args.Count) { $args[0] } else { git_current_branch }; git push origin $b }
function ggf { $b = if ($args.Count) { $args[0] } else { git_current_branch }; git push --force origin $b }
function ggfl { $b = if ($args.Count) { $args[0] } else { git_current_branch }; git push --force-with-lease origin $b }
function ggu { $b = if ($args.Count) { $args[0] } else { git_current_branch }; git pull --rebase origin $b }
function ggpnp { ggl @args; if ($LASTEXITCODE -eq 0) { ggp @args } }
Set-Alias -Name ggpur -Value ggu -Scope Global
function ggpull { git pull origin (git_current_branch) @args }
function ggpush { git push origin (git_current_branch) @args }

# --- dynamic: multi-step / `&&` chains ---
function gpristine { git reset --hard && git clean --force -dfx }
function gwipe     { git reset --hard && git clean --force -df }
function gpoat     { git push origin --all && git push origin --tags }
function grt {
    $top = git rev-parse --show-toplevel 2>$null
    if ($top) { Set-Location $top } else { Set-Location . }
}
function gdct { git describe --tags (git rev-list --tags --max-count=1) @args }
function gtv  { git tag --sort=version:refname @args }   # omz `git tag | sort -V`
function gtl  { param([string]$Prefix) git tag --sort=-v:refname -n --list "$Prefix*" }
function gdnolock { git diff @args ':(exclude)package-lock.json' ':(exclude)*.lock' }
function gfg { git ls-files | Select-String @args }
function gignored { git ls-files -v | Select-String -CaseSensitive '^[a-z]' }

# --- dynamic: work-in-progress stash helpers ---
function gwip {
    git add -A
    $deleted = git ls-files --deleted
    if ($deleted) { git rm -- $deleted 2>$null }
    git commit --no-verify --no-gpg-sign --message '--wip-- [skip ci]'
}
function gunwip {
    $subject = git rev-list --max-count=1 --format='%s' HEAD 2>$null
    if ($subject -match '--wip--') { git reset HEAD~1 }
}

# --- dynamic: branch housekeeping ---
function gbg { git branch -vv | Select-String ': gone]' }
function gbgd {
    git branch --no-color -vv | Select-String ': gone]' | ForEach-Object {
        $name = ($_.Line.Trim() -split '\s+')[0]
        if ($name -and $name -ne '*') { git branch -d $name }
    }
}
function gbda {
    $main = git_main_branch
    $dev = git_develop_branch
    git branch --no-color --merged |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^[+*]' -and $_ -ne $main -and $_ -ne $dev } |
        ForEach-Object { git branch --delete $_ 2>$null }
}
function grename {
    param([string]$Old, [string]$New)
    if (-not $Old -or -not $New) { Write-Host 'Usage: grename <old_branch> <new_branch>'; return }
    git branch -m $Old $New
    git push origin :$Old
    if ($LASTEXITCODE -eq 0) { git push --set-upstream origin $New }
}
function gccd {
    git clone --recurse-submodules @args
    if ($LASTEXITCODE -ne 0) { return }
    $target = ($args[-1] -replace '\.git/?$', '') -replace '.*[/:]', ''
    if ($target -and (Test-Path -LiteralPath $target)) { Set-Location $target }
}

# --- dynamic: gitk launchers (GUI; no-op if gitk isn't installed) ---
function gk  { Start-Process gitk -ArgumentList '--all', '--branches' }
function gke {
    $revs = git log --walk-reflogs --pretty=%h
    Start-Process gitk -ArgumentList (@('--all') + $revs)
}

# Not ported (deliberate): gcm, gm (see header); git-svn-dcommit-push (svn +
# hard-coded remote), gunwipall / work_in_progress / gdv (zsh/vim-specific).
