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

# upgrade npm coding agents (close Pi/OpenCode/Codex/Copilot first; Windows locks live executables)
upgrade-npm-agents:
    pwsh -NoProfile -File ./scripts/run-package-source-command.ps1 -Action UpgradeNpmAgents

# upgrade the summarize CLI (plain npm global, not part of the agent stack)
upgrade-summarize:
    pwsh -NoProfile -File ./scripts/run-package-source-command.ps1 -Action UpgradeSummarize

# upgrade Oh My Pi through its official prebuilt-binary installer
upgrade-omp:
    pwsh -NoProfile -File ./scripts/upgrade-omp.ps1

# fast-forward the chezmoi-managed pi-agents external checkout
upgrade-pia:
    chezmoi apply --refresh-externals

# upgrade the complete Pi/pia/OMP + npm-agent stack (close running agents first)
# Deliberately not part of `just upgrade`: live executables may be locked.
upgrade-agents: upgrade-npm-agents upgrade-omp upgrade-pia

# Upgrade the Go-installed dev CLI (installed with the optional Herdr stack).
# Deliberately not in `just upgrade`: on a host without Herdr this would install it.
upgrade-dev:
    $env:GOBIN = Join-Path $HOME '.local\bin'; $env:GOPATH = Join-Path $HOME '.local\share\go'; $env:GOTOOLCHAIN = 'auto'; go install github.com/daviddwlee84/dev-cli/cmd/dev@latest

# upgrade everything
upgrade: upgrade-scoop upgrade-winget

# Deliberately NOT part of `just upgrade`: on a box without installTranslate this
# would install rather than upgrade. (`just upgrade-scoop` does cover it once
# installed — this recipe is the targeted version.)
# upgrade the translate CLI from the daviddwlee84 scoop bucket
upgrade-translate:
    scoop update translate

# Verified official-installer Herdr update plus binary-matched global skill refresh.
# Run outside Herdr after detaching; restart Herdr deliberately after completion.
upgrade-herdr:
    pwsh -NoProfile -File ./scripts/upgrade-herdr.ps1

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
    pwsh -NoProfile -File ./scripts/run-package-source-command.ps1 -Action DocsServe

# build the docs site (strict)
docs-build:
    pwsh -NoProfile -File ./scripts/run-package-source-command.ps1 -Action DocsBuild
