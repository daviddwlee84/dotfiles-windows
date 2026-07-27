# Agent 完成音效（`agentSounds`）

Windows 上 coding agent 做完事情時怎麼通知你：toast、遊戲角色語音、兩個都要、或
什麼都不要。在 `chezmoi init` 時用 `agentSounds` prompt 決定。

這是跨平台 repo 的
[`docs/tools/agent-sounds.md`](https://github.com/daviddwlee84/dotfiles/blob/main/docs/tools/agent-sounds.zh-TW.md)
的 Windows 對應版；生態系的完整說明（OpenPeon vs peon-ping vs CESP）請看那一篇，
這裡只講差異。

## 四個層級

| `agentSounds` | 掛什麼 | 你會得到 |
|---|---|---|
| `none` | 什麼都不掛 | 安靜 |
| `notify` | `notify.ps1` → apprise → `windows://` toast | Windows toast |
| `peon` | peon-ping 的 9 個 hook 事件 | 遊戲語音 + peon 自己的 overlay |
| `both` | 以上兩者 | toast + 語音（會有兩個橫幅） |

`workstation` role 預設 `notify`，`minimal` 預設 `none`。它**只控制掛不掛 hook**
—— `peon` CLI 會跟著 coding agents 一起裝，所以 `peon preview task.complete` /
`peon packs list` 隨時都能玩。

預設音效包是 `league_of_legends`（League of Legends 英雄語音）。安裝器會下載後
再啟用它（`peon packs use league_of_legends`），所以第一次執行就有聲音——原始
安裝器否則會停在沒有任何聲音的空 `peon` pack。

`both` 有兩個橫幅是預期的。不用改層級，用 runtime 開關就好：`peon notifications off`
會保留聲音、關掉 peon 的 overlay。

## 跟 macOS/Linux repo 的三個差異

設計相同，實作細節不同。

**1. 事件集不一樣。** peon-ping 的 Windows adapter 會註冊 `PreToolUse`，而**不會**
註冊 `UserPromptSubmit` —— 跟 POSIX 那邊剛好相反（兩邊都是 9 個事件）。這是從上游
`install.ps1` 原始碼取得的，不是從 README（README 記載的指令形狀在 POSIX 那邊已被
證實是錯的，所以這裡也不採信）。

**2. hook 指令形狀。** Windows 的條目帶 `timeout = 10`、**沒有** `async`：

```
powershell -NoProfile -NonInteractive -Command "if (Test-Path '<peon.ps1>') { & '<peon.ps1>' }"
```

`Test-Path` 保護是刻意的 —— 沒裝的機器上，沒保護的 `-File <不存在>` 會讓 Claude Code
每個事件都噴 hook 錯誤。作用等同 parent repo 裡 `command -v workmux` 那個保護。

**3. peon-ping 裝在 `~/.openpeon`，不是 `~/.claude`。** 我們用 `-OpenPeon` 安裝，
它會把整棵樹改根到 tool-agnostic 的位置，這樣安裝器就永遠不會碰
`~/.claude/settings.json` —— hook 由我們自己宣告。所以 `peon.ps1` 的位置是
`~/.openpeon/hooks/peon-ping/peon.ps1`。

順帶一提，安裝器的參數區塊是
`param([string[]]$Packs, [switch]$All, [string]$Lang, [switch]$Local, [switch]$Global, [switch]$OpenPeon, [switch]$InitLocalConfig)`
—— **沒有 `-NoRc`**（那是 bash `install.sh` 的 flag），而且它不會動 `$PROFILE`。

## 接線在哪

| 負責什麼 | 檔案 |
|---|---|
| prompt | `.chezmoi.toml.tmpl` |
| hook 條目 + prune | `.chezmoiscripts/run_onchange_after_25_claude_settings.ps1.tmpl` |
| 安裝 binary | `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` |
| 非 hook overlay（statusLine、plugins） | `claude/settings-overlay.json` |

hook 條目必須從 `claude/settings-overlay.json` **搬出來**放進 run_onchange：那個 JSON
是被原封不動 `include` 進來的，沒辦法帶 Go-template 條件式。

## 唯一一處我們會「減」的地方

合併是加法式的，所以外部的 hook 條目（CodeIsland、你手動加的）都會保留。只有一個例外：
符合**我們自己**指令指紋（`notify\.ps1`、`peon\.ps1`）的條目，會在目前層級關掉它時被移除。

沒有它的話 `agentSounds` 會變成單向棘輪 —— 從 `notify` 換到 `none` 時 `notify.ps1`
會永遠留著，於是 `none` 對原本有聲音的機器根本不會變安靜。上游自己的 `install.ps1`
在重新加入前也是剝掉同樣這兩個指紋，所以行為一致。

## peon 的設定刻意不給 chezmoi 管

`peon volume` / `notifications` / `packs use` 會在 runtime 寫
`~/.openpeon/config.json`。chezmoi 不管那個檔案，所以你怎麼調都**不會**產生 drift。
安裝器只 seed 並啟用一次 `league_of_legends`，之後的 apply 會跳過（用 `peon.ps1` 是否存在來判斷），
所以你後來換的 pack 會一直留著。

## 驗證

```powershell
peon status
peon preview task.complete       # 應該說 "Job's finished!"
peon volume 0.4; chezmoi diff    # 必須是空的
```

**上面三行全過也不代表真的會發出聲音。** 這組指令曾經在 parent repo 一台完全沒聲音的
macOS 機器上全部通過
（→ [`peon-hooks-wired-but-no-sound`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/peon-hooks-wired-but-no-sound.md)）：
`peon status` 只看 `~/.openpeon`；`preview` 根本繞過 hook；settings 裡的 key 可以
全部存在、但 hook 指向的檔案不存在 —— 因為 `Test-Path` 保護會把「播放器不存在」變成
一次**成功**的 no-op，Claude Code 於是回報 `completed successfully`。

這件事在 Windows 比 macOS 更需要注意：`run_onchange_after_10_packages.ps1.tmpl` 裡
`install.ps1 -OpenPeon` 那步如果失敗，它只會呼叫 `Register-Failure`，apply 照樣繼續 ——
於是 hook 接好了、播放器卻從來沒裝上。要檢查的是產出物本身，然後用 Claude Code 的方式
實際觸發一次：

```powershell
Test-Path "$HOME\.openpeon\hooks\peon-ping\peon.ps1"   # 必須是 True
'{"hook_event_name":"Stop","session_id":"probe","cwd":"."}' |
  & "$HOME\.openpeon\hooks\peon-ping\peon.ps1"
Get-Content "$HOME\.openpeon\.state.json" | ConvertFrom-Json |
  Select-Object -Expand last_played                    # -> task.complete = sounds/JobsFinished.mp3
```

`last_played` 是唯一能被機器檢查、證明聲音真的送出去的證據；exit code 0 不是。

兩個上游行為，先知道再決定要不要怪這個 repo（都在 macOS 的 peon 2.35.1 上確認過）：

- **終端機在前景時 overlay 會被抑制** —— 聲音會播，橫幅不會。切到別的視窗再讓它跑完。
- **`peon notifications test` 是 no-op** —— 它跑的是 `PEON_TEST=1`，會關掉 peon script
  解析器的 installer-layout fallback，於是回報成功卻不發通知。請改用一次真正的、
  非前景的 turn 來測。

## 驗證狀態

template 渲染、PowerShell 剖析、以及合併/prune 行為都已在 macOS 上驗證過：四個層級
全部渲染出來，並用（跨平台的）`pwsh` 對 fixture 實際執行 —— 外部條目存活、我們的條目
被剝除、層級矩陣正確。

**尚未在真正的 Windows 機器上驗證**：peon-ping 安裝本身
（`install.ps1 -OpenPeon -Packs league_of_legends`）、toast/語音是否真的發得出來、以及
`$env:TEMP` 的行為。這些需要一台 Windows。
