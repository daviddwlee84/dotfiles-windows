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
    chezmoi apply --init

# pull latest from the repo and apply
update:
    chezmoi update --init

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

# EXPERIMENTAL: build the SpecStory Windows CLI from the unmerged PR #191
# (needs git + go) -> ~/.local/bin/specstory.exe. See
# backlog/specstory-windows-native-cli.md. Run from the chezmoi source dir.
specstory-build:
    pwsh -NoProfile -File ./scripts/build-specstory.ps1

# enable the OpenSSH server (sshd) — run from an ELEVATED pwsh (opt-in; opens TCP 22)
enable-sshd:
    pwsh -NoProfile -File ./scripts/enable-sshd.ps1

# install WSL2 (Docker Desktop backend) — pops one UAC prompt; reboot required after
enable-wsl:
    pwsh -NoProfile -File ./scripts/enable-wsl.ps1

# install a WSL2 Ubuntu distro + bootstrap cross-platform dotfiles (needs installWsl + reboot first)
enable-wsl-ubuntu:
    pwsh -NoProfile -File ./scripts/enable-wsl-ubuntu.ps1

# install the cross-platform dotfiles inside an EXISTING WSL distro (VPN on if behind GFW)
wsl-dotfiles distro="Ubuntu-24.04":
    pwsh -NoProfile -File ./scripts/bootstrap-wsl-dotfiles.ps1 -Distro {{distro}}

# install Hack Nerd Font machine-wide so Alacritty sees it (run from ELEVATED pwsh)
install-fonts-machine-wide:
    pwsh -NoProfile -File ./scripts/install-fonts-machine-wide.ps1

# --- Windows-in-Docker test harness (x86-64 Linux + KVM host only) ---

# launch the test VM (web viewer http://localhost:8006, RDP localhost:3389 dev/dev)
docker-up:
    #!/usr/bin/env bash
    docker compose -f docker/windows/compose.yml up -d
    echo "Web viewer: http://localhost:8006   RDP: localhost:3389 (dev/dev)"

# stop the test VM (keeps the disk)
docker-down:
    #!/usr/bin/env bash
    docker compose -f docker/windows/compose.yml down

# stop the test VM and delete its disk
docker-clean:
    #!/usr/bin/env bash
    docker compose -f docker/windows/compose.yml down -v

# tail the VM boot/install logs
docker-logs:
    #!/usr/bin/env bash
    docker compose -f docker/windows/compose.yml logs -f

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
