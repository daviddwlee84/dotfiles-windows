-- ~/.config/yazi/init.lua (Windows)
-- Managed by chezmoi; YAZI_CONFIG_HOME is set to ~/.config/yazi.

-- Current git.yazi requires Yazi 26.8.15. Keep setup fail-soft because this
-- repo deliberately separates install from upgrade: an older host can receive
-- the config before `scoop update yazi`. git-guard.yazi makes the fetcher a
-- harmless noop until the matched yazi/ya pair is upgraded.
local git_ok, git_err = pcall(function()
	require("git"):setup({ order = 1500 })
end)

if not git_ok then
	ya.err("git.yazi failed to load: " .. tostring(git_err))
	pcall(ya.notify, {
		title = "git.yazi not loaded",
		content = "Git status signs are disabled. Upgrade yazi/ya to 26.8.15+, then run `ya pkg install`.",
		level = "warn",
		timeout = 10,
	})
end
