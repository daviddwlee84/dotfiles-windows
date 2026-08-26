---
name: verify
description: Exercise this Windows dotfiles repo's PowerShell CLI wrappers through their public commands.
---

# Runtime verification

- Run PowerShell surfaces with `pwsh -NoProfile` and import the deployed module
  from `~/.config/powershell/modules/Copilot/Copilot.psd1` after a targeted
  `chezmoi apply`.
- Capture `git status --short` before and after. Do not restore or delete
  `.specstory` files while another recorder may be writing them.
- **Ask before exercising the automatic SpecStory path.** `specstory run` may
  cloud-sync the captured session and update `.specstory/statistics.json`; a
  temporary `CODEX_HOME` does not make that publication local-only.
- Default real Codex probes to `codex-copilot-once --no-specstory ...`. A real
  `exec --json <prompt>` proves inference when it emits `thread.started`, an
  agent message, and exit 0.
- Use `codex-copilot-once --no-specstory doctor --summary --ascii` for a safe
  deployed-provider check. It must report provider auth and reachable endpoints.
- A healthy port 4142 may still be an older in-memory shim. Applying
  `copilot-throttle-shim.js` does not reload its Bun process. Do not restart it
  while active Claude/Codex sessions exist; verify changed retry/stream logic on
  isolated temporary ports, then restart explicitly after sessions end.
