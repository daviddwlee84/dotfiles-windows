# Yazi file manager

Yazi is installed through Scoop and reads `~/.config/yazi` through the managed
`YAZI_CONFIG_HOME`. Run `y` from PowerShell to return in the directory where
Yazi exits, or use Herdr `prefix+Y` for a disposable file-manager pane rooted at
the focused agent pane's cwd.

## Git status signs

The managed [`git.yazi`](https://github.com/yazi-rs/plugins/tree/main/git.yazi)
fetcher appends colored signs to files and directories for untracked, unstaged,
staged, added, deleted, updated, and ignored states. Dirty descendant states
bubble up to their parent directories.

The pinned plugin requires a matched Yazi/Ya **26.8.15+** pair. Run:

```powershell
just upgrade-yazi-plugins
```

This upgrades the Scoop `yazi` package first and then runs `ya pkg upgrade`.
`chezmoi apply` remains install-only: its self-healing hook installs the locked
revision when missing but never advances it.

After an upgrade, copy the regenerated `~/.config/yazi/package.toml` back to
`dot_config/yazi/package.toml` in the chezmoi source before committing, or a
later apply will restore the previously committed revision.

Older hosts remain usable during the upgrade gap. `init.lua` shows a warning,
and the byte-identical cross-platform `git-guard.yazi` delegates to Yazi's
`noop` fetcher until the real plugin can load.

## Herdr launcher

`prefix+Y` opens Yazi in a temporary command pane because the Windows Herdr
preview still rejects `type = "popup"`. It uses the same key and focused-pane
cwd as macOS/Linux, then closes when Yazi exits. Its final directory does not
change the source agent pane; use the PowerShell `y` helper for that behavior.
