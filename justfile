# Windows dotfiles task runner. Install with: scoop install just
# Recipes run under PowerShell 7.
set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]
set shell := ["pwsh", "-NoLogo", "-Command"]

# list recipes
default:
    @just --list

# preview pending changes
diff:
    chezmoi diff

# apply dotfiles
apply:
    chezmoi apply

# pull latest from the repo and apply
update:
    chezmoi update

# edit the source of a managed file
edit FILE:
    chezmoi edit {{FILE}}

# upgrade CLI tools (scoop)
upgrade-scoop:
    scoop update
    scoop update *

# upgrade GUI apps (winget)
upgrade-winget:
    winget upgrade --all --accept-source-agreements --accept-package-agreements

# upgrade everything
upgrade: upgrade-scoop upgrade-winget

# lint PowerShell with PSScriptAnalyzer
lint:
    Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 | Format-Table -AutoSize

# run Pester tests
test:
    Invoke-Pester -CI

# serve the docs site locally
docs-serve:
    uv run --with mkdocs-material --with mkdocs-static-i18n mkdocs serve

# build the docs site (strict)
docs-build:
    uv run --with mkdocs-material --with mkdocs-static-i18n mkdocs build --strict
