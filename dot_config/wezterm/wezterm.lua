-- wezterm.lua — managed by chezmoi (Windows dotfiles).
--
-- WezTerm is installed as the tmux-like multiplexer (see docs/rationale.md). On
-- Windows it otherwise defaults default_prog to cmd.exe ("DOS"), so we point it at
-- PowerShell 7 and match the Alacritty / Windows Terminal font + theme.
--
-- WezTerm reads this from ~/.config/wezterm/wezterm.lua on Windows too (XDG),
-- consistent with starship / yazi. User tweaks: keep them in a separate file and
-- require() it here, or edit via `chezmoi edit`.
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Open pwsh, not the default cmd.exe. pwsh.exe resolves via ~/scoop/shims on PATH.
config.default_prog = { 'pwsh.exe', '-NoLogo' }

-- Same Nerd Font the other terminals use. Unlike Alacritty, WezTerm sees per-user
-- (scoop-installed) fonts, so no machine-wide install is required here.
config.font = wezterm.font('Hack Nerd Font Mono')
config.font_size = 11.0

config.color_scheme = 'One Half Dark'
config.window_background_opacity = 0.95
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false
config.default_cursor_style = 'SteadyBlock'
config.scrollback_lines = 10000
config.audible_bell = 'Disabled'

return config
