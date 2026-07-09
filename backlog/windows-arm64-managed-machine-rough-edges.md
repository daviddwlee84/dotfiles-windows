# Windows-on-ARM64 + managed-machine rough edges

**Status**: P? — environmental; workarounds documented, no clean fix yet
**Effort**: L
**Related**: `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` · `dot_config/nvim/**` · `AppData/Roaming/alacritty/alacritty.toml.tmpl`

## Context

2026-07. First real deploy target turned out to be **Windows 11 on ARM64**
(Snapdragon / Surface-class) that is also a **managed/corporate** machine
(`OneDrive - Microsoft`, org install policies). Several things work under x64
emulation but have sharp edges. Captured here so we don't re-derive them.

## Symptoms + root causes

1. **nvim-treesitter: "C compiler ❌ / tree-sitter (CLI) ❌"** even after adding
   `zig`.
   - LazyVim now defaults to nvim-treesitter's **`main`** branch, which needs
     the **`tree-sitter` CLI** (not just a compiler). → fixed: added
     `tree-sitter` to the core scoop set.
   - Arch mismatch: scoop installed **arm64-native `zig`** (`zig-aarch64-
     windows`) but scoop **`neovim` is amd64** (runs under x64 emulation). A
     parser compiled by arm64 zig won't load in amd64 nvim. An **amd64**
     compiler matches the emulated nvim — `scoop install gcc` (amd64 MinGW) is
     the pragmatic fix on ARM64. nvim-treesitter also may just not tick "C
     compiler" for zig on the main branch.
   - Open question: ship an arm64-native nvim (winget `Neovim.Neovim`?) so the
     whole toolchain is arm64, vs. force amd64 everything.

2. **mason.nvim fails to install marksman / lua_ls / taplo / ruff / tree-sitter-
   cli.** mason downloads tools from the internet at runtime; the managed
   machine blocks / Defender-quarantines them. Not fixable from config. Options:
   pre-install the LSPs via scoop/winget and point LazyVim at them, or accept a
   degraded LSP set on locked-down machines.

3. **Fonts: Alacritty/WT can't find "Hack Nerd Font Mono"; text renders italic.**
   scoop nerd-fonts register per-user (`%LOCALAPPDATA%\Microsoft\Windows\Fonts`
   + HKCU). Suspected: registration didn't stick (managed-machine restriction)
   or the terminal was running during install (font cache is per-process).
   Italic = fallback-font substitution symptom. Diagnostic:
   `[System.Drawing.Text.InstalledFontCollection]::new().Families.Name |
   Select-String Hack`. If absent → reinstall the font / sign out+in; if present
   → fully restart the terminal.

4. **Defender PUA blocks low-reputation installers** (Notepad++ ARM64 → dropped;
   wakatime-cli re-download loop → plugin disabled). Managed machines run
   aggressive PUA protection.

5. **Org policy blocks MSIs** (Tailscale exit 1625, Grammarly) → the
   `managedMachine` init toggle now skips these.

## Decision (so far)

Handle the cheap/clear ones in-repo (tree-sitter CLI, wakatime disable,
managedMachine toggle, Notepad++ drop, UTF-8 console). Leave the arch-mismatch
(nvim/zig) and mason-download story as documented workarounds until we decide
whether to commit to an all-arm64 or all-amd64 Neovim toolchain.

## References

- nvim-treesitter main branch requirements: https://github.com/nvim-treesitter/nvim-treesitter
- Neovim Windows releases (arch availability): https://github.com/neovim/neovim/releases
- scoop nerd-fonts (per-user registration): https://github.com/matthewjberger/scoop-nerd-fonts
