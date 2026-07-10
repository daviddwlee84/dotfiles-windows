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

-- Open pwsh, not the default cmd.exe ("DOS").
--
-- Point at the REAL pwsh.exe, NOT the scoop shim on PATH. Scoop's
-- ~/scoop/shims/pwsh.exe is a console-subsystem helper that re-launches the real
-- binary; when a GUI app like WezTerm spawns it, Windows pops a stray empty "DOS"
-- console window alongside the terminal (ScoopInstaller/Scoop#5049). Launching the
-- shimmed target directly avoids that phantom window. Falls back to the PATH shim
-- (still better than cmd.exe) if none of the known install paths exist.
local function pwsh_exe()
  local candidates = {
    wezterm.home_dir .. '\\scoop\\apps\\pwsh\\current\\pwsh.exe', -- scoop (this repo's bootstrap)
    'C:\\Program Files\\PowerShell\\7\\pwsh.exe',                 -- winget / MSI install
  }
  for _, path in ipairs(candidates) do
    local f = io.open(path, 'r')
    if f then f:close(); return path end
  end
  return 'pwsh.exe'
end

config.default_prog = { pwsh_exe(), '-NoLogo' }

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
