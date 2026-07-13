# 磁碟空間

完整 apply 大約會用掉多少磁碟，依初始化開關分組估算。安裝清單在
`.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`（單一事實來源）；各套件
用途見 [工具索引](tools.md)，開關見 [安裝](setup.md)。

!!! warning "這是估計值，不是實測"
    表中數字是各套件在 Windows 上的典型 **安裝後** 體積，並非在你機器上實測 ——
    實際值會因版本、架構（x64 vs ARM64）與已裝項目而浮動。也 **不含** 下方四個
    「無底洞」類別（Docker image、Ollama 模型、WSL distro 增長、scoop 下載
    cache），這些經常遠超靜態安裝量。要看真實佔用，用內建的 **WinDirStat** /
    **TreeSize**（utility apps），或 `scoop cache show`。

## 各開關的估算

| 開關 | 主要吃空間的項目 | 估計（安裝後） | `workstation` 預設開 |
|---|---|---|---|
| **Baseline**（一定裝） | gcc/MinGW 工具鏈 ~1–1.3 GB、node+bun ~200 MB、uv+Python ~200 MB、neovim/yazi + 一堆小 CLI | **~2 GB** | 永遠 |
| `installCodingAgents` | Claude Code（winget）+ 3 個 npm agent（opencode/codex/copilot）+ opencode-desktop + apprise | **~0.7 GB** | ✅ |
| `installWindowsApps` | **Docker Desktop ~2.5 GB**、Cursor/Antigravity 各 ~0.6 GB、VSCode/PowerToys 各 ~0.35 GB、4 個瀏覽器、Claude/ChatGPT desktop、Hack Nerd Fonts ~0.4 GB | **~7 GB** | ✅ |
| `installWsl` | WSL2 平台 + kernel（不含 distro） | **~1.5 GB** | ✅ |
| `installWslUbuntu` | Ubuntu rootfs + distro 內 dotfiles bootstrap | **~2.5 GB** | — |
| `installUtilityApps` | OBS ~0.45 GB、VLC ~0.2 GB、ShareX、Tailscale、CPU-Z/GPU-Z/HWiNFO… | **~1 GB** | ✅ |
| `installExtraRuntimes` | **rust/rustup ~1.5 GB**、go ~0.5 GB、ruby ~0.2 GB | **~2.2 GB** | ✅ |
| `installMediaTools` | ffmpeg + imagemagick | **~0.3 GB** | — |
| `installLlmTools` | **Ollama ~1.5 GB**（不含模型）+ LiteLLM | **~1.8 GB** | — |
| `installTunnelTools` | ngrok + cloudflared | **~0.1 GB** | — |
| `installIacTools` | **Azure CLI ~1 GB** + Terraform + OpenTofu | **~1.5 GB** | — |
| `installGamingApps` | Steam 客戶端（不含遊戲） | **~0.4 GB** | — |
| `installSshServer` | OpenSSH Server（Windows optional feature） | **~0.01 GB** | — |
| `installHerdr` | herdr preview | **~0.03 GB** | — |
| `installClink` | clink + lua 橋接 | **~0.02 GB** | — |
| `installTry` | ruby（若 Extra runtimes 已開則 ≈0）+ try-cli gem | **~0.2 GB / ~0** | — |

## 情境

| 設定檔 | 開了什麼 | 估計合計 |
|---|---|---|
| **`minimal` role** | 只有 baseline | **~2 GB** |
| **`workstation` role（預設）** | baseline + CodingAgents + WindowsApps + WSL + UtilityApps + ExtraRuntimes | **~14–15 GB** |
| **全部開關打開** | 所有開關 | **~21–25 GB** |

`workstation` 的算式：

```
baseline 2.0 + agents 0.7 + WindowsApps 7.0 + WSL 1.5 + utility 1.0 + runtimes 2.2
≈ 14–15 GB
```

## 無底洞項目

不在上表數字內 —— 這些會在 **執行期** 增長，常常超過整個靜態安裝量：

- **Docker Desktop** —— image 加上 `docker-desktop` WSL VM 磁碟，隨你 pull/build 變大。
- **Ollama**（`installLlmTools`）—— 每個模型 **4–70 GB**；上表算的 ~1.5 GB 只是應用程式本身。
- **WSL Ubuntu**（`installWslUbuntu`）—— distro 磁碟會隨使用膨脹。
- **scoop cache** —— 下載的壓縮檔留在 `~/scoop/cache`（約等於每個下載再存一份）。用 `scoop cache rm *` 清掉。

## 瘦身建議

- 單一最大效益：關掉 **`installWindowsApps`**（−~7 GB，Docker Desktop 佔大宗）、
  **`installLlmTools`**（−~1.8 GB，還沒算模型）、**`installIacTools`**
  （−~1.5 GB，大多是 Azure CLI）。
- **baseline** 裡最重的是 **gcc/MinGW 工具鏈**（約佔 baseline 一半）—— 但它是
  必裝：LazyVim 的 `nvim-treesitter` `main` 分支要用真 gcc 編 parser。較精簡的
  替代是 scoop `mingw`（niXman MinGW-w64 UCRT）—— 見 [工具索引](tools.md)。
- apply 後回收空間：`scoop cache rm *`，再 `scoop cleanup *` 移除舊版本。
