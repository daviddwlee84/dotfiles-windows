# Evaluate converging claude-hud installation architecture

- **Status**: P? — deferred 2026-08
- **Effort**: M
- **Related**: `TODO.md` · `claude/settings-overlay.json` · `claude/hud-full-overlay.json` · `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl` · parent `dot_ansible/roles/coding_agents/files/claude_hud_sync.py`

## Context

The two dotfiles repositories currently reach the same visible HUD through different installation lifecycles:

- **dotfiles-windows** uses Claude Code's marketplace/plugin lifecycle. It registers the `claude-hud` marketplace, keeps `claude-hud@claude-hud` enabled so a fresh machine can install and update it, and runs the newest cached runtime from the status line. The enabled plugin also exposes the rarely used `claude-hud:setup` and `claude-hud:configure` command descriptions; their full bodies remain lazy-loaded.
- **daviddwlee84/dotfiles** uses `claude_hud_sync.py` to populate the versioned cache and `installed_plugins.json` directly. Its status line executes that cached runtime while the plugin stays disabled, so the two commands are absent. Installation and upgrades remain available through the helper rather than Claude Code's plugin loader.

The direct-sync approach is more deterministic at apply time and avoids the small command-description context cost. The plugin-native approach uses the supported lifecycle and avoids maintaining internal cache/registry behavior. Neither advantage currently dominates enough to justify a migration.

## Current decision

**2026-08: keep the architectures distinct.**

- Windows remains plugin-native and enabled.
- The parent repo keeps direct cached-runtime sync and the plugin disabled.
- Synchronize HUD configuration policy and visible behavior, not necessarily installation mechanics.
- Do not port the direct-sync helper to Windows merely to remove two short command descriptions.
- If convergence later becomes worthwhile, plugin-native is the tentative long-term direction, subject to the criteria below.

## Revisit criteria

Re-evaluate when one or more of these becomes true:

- A supported plugin-native flow can be verified to install reliably on a fresh machine before first use.
- Marketplace refresh and third-party plugin updates become deterministic and testable enough for dotfiles bootstrap.
- Plugin command/skill exposure can be suppressed reliably while retaining the status-line runtime; specifically retest plugin-qualified `skillOverrides`.
- Direct sync repeatedly breaks because the cache layout or `installed_plugins.json` schema changes.
- The helper's maintenance, security, or provenance burden becomes material.
- The parent needs the plugin commands often enough that keeping it disabled becomes a real limitation.
- Measured context overhead becomes material rather than only a few short descriptions.
- A genuinely shared cross-platform helper can replace duplicated Python/PowerShell implementations.
- Version pinning, rollback, offline recovery, or provenance requirements favor one architecture decisively.

## Evaluation dimensions

1. Fresh-machine reproducibility and first-run behavior.
2. Install, update, version-pin, downgrade, and rollback semantics.
3. Offline operation and recovery after cache deletion.
4. Reliance on supported plugin lifecycle versus internal cache/registry formats.
5. Enabled-plugin effects: command availability, description exposure, and measured context cost.
6. Config ownership and compatibility with per-config overrides.
7. Marketplace versus direct release/tag provenance and trust.
8. Cross-platform dependencies and implementation burden.
9. Automated testability and failure visibility.
10. Long-term maintenance when Claude Code or claude-hud changes format.

## Adjacent work — separate scope

The parent repo can independently adopt the remaining Full 0.8 display leaves while preserving its existing direct-sync/disabled lifecycle and parent-specific advanced overrides. Treat that as a focused parent-repository config/docs change, not as a prerequisite for installation convergence.
