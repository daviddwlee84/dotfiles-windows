# Disk space

Rough budget for how much disk a full apply consumes, broken down by init
toggle. The install set is
`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (the single source of
truth); see [Tools](tools.md) for what each package is and [Setup](setup.md) for
the toggles.

!!! warning "These are estimates, not measurements"
    Sizes are typical **installed** footprints for each package on Windows, not
    values measured on your machine — real numbers vary by version, arch
    (x64 vs ARM64), and what's already present. They **exclude** the four
    "bottomless" categories below (Docker images, Ollama models, WSL distro
    growth, scoop's download cache), which routinely dwarf the static install.
    To see the truth on a real box, use the bundled **WinDirStat** / **TreeSize**
    (utility apps) or `scoop cache show`.

## Per-toggle estimate

| Toggle | Biggest items | Est. (installed) | Default on `workstation` |
|---|---|---|---|
| **Baseline** (always) | gcc/MinGW toolchain ~1–1.3 GB, node+bun ~200 MB, uv+Python ~200 MB, neovim/yazi + many small CLIs | **~2 GB** | always |
| `installCodingAgents` | Claude Code (winget) + 3 npm agents (opencode/codex/copilot) + opencode-desktop + apprise | **~0.7 GB** | ✅ |
| `installWindowsApps` | **Docker Desktop ~2.5 GB**, Cursor/Antigravity ~0.6 GB each, VSCode/PowerToys ~0.35 GB each, 4 browsers, Claude/ChatGPT desktop, Hack Nerd Fonts ~0.4 GB | **~7 GB** | ✅ |
| `installWsl` | WSL2 platform + kernel (no distro) | **~1.5 GB** | ✅ |
| `installWslUbuntu` | Ubuntu rootfs + in-distro dotfiles bootstrap | **~2.5 GB** | — |
| `installUtilityApps` | OBS ~0.45 GB, VLC ~0.2 GB, ShareX, Tailscale, CPU-Z/GPU-Z/HWiNFO… | **~1 GB** | ✅ |
| `installExtraRuntimes` | **rust/rustup ~1.5 GB**, go ~0.5 GB, ruby ~0.2 GB | **~2.2 GB** | ✅ |
| `installMediaTools` | ffmpeg + imagemagick | **~0.3 GB** | — |
| `installLlmTools` | **Ollama ~1.5 GB** (no models) + LiteLLM | **~1.8 GB** | — |
| `installTunnelTools` | ngrok + cloudflared | **~0.1 GB** | — |
| `installIacTools` | **Azure CLI ~1 GB** + Terraform + OpenTofu | **~1.5 GB** | — |
| `installGamingApps` | Steam client (no games) | **~0.4 GB** | — |
| `installSshServer` | OpenSSH Server (Windows optional feature) | **~0.01 GB** | — |
| `installHerdr` | herdr preview | **~0.03 GB** | — |
| `installClink` | clink + lua bridges | **~0.02 GB** | — |
| `installTry` | ruby (≈0 if Extra runtimes already on) + try-cli gem | **~0.2 GB / ~0** | — |

## Scenarios

| Profile | What's on | Est. total |
|---|---|---|
| **`minimal` role** | baseline only | **~2 GB** |
| **`workstation` role (default)** | baseline + CodingAgents + WindowsApps + WSL + UtilityApps + ExtraRuntimes | **~14–15 GB** |
| **Everything on** | all toggles | **~21–25 GB** |

The `workstation` math:

```
baseline 2.0 + agents 0.7 + WindowsApps 7.0 + WSL 1.5 + utility 1.0 + runtimes 2.2
≈ 14–15 GB
```

## The bottomless items

Not in the numbers above — these grow at **runtime**, often past the entire
static install:

- **Docker Desktop** — images + the `docker-desktop` WSL VM disk grow with what
  you pull/build.
- **Ollama** (`installLlmTools`) — each model is **4–70 GB**; the app itself is
  the ~1.5 GB counted above.
- **WSL Ubuntu** (`installWslUbuntu`) — the distro disk expands as you use it.
- **scoop cache** — downloaded archives sit in `~/scoop/cache` (~another copy of
  every download, compressed). Reclaim with `scoop cache rm *`.

## Trimming tips

- The biggest single wins are turning off **`installWindowsApps`** (−~7 GB,
  Docker Desktop dominates), **`installLlmTools`** (−~1.8 GB before any models),
  and **`installIacTools`** (−~1.5 GB, mostly Azure CLI).
- The heaviest **baseline** item is the **gcc/MinGW toolchain** (~half of
  baseline) — but it's mandatory: LazyVim's `nvim-treesitter` `main` branch
  compiles parsers with a real gcc. A leaner alternative is scoop `mingw`
  (niXman MinGW-w64 UCRT) — see [Tools](tools.md).
- Reclaim space after apply: `scoop cache rm *`, then `scoop cleanup *` to drop
  old app versions.
