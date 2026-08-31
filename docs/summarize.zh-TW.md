# summarize（YouTube／網頁／PDF → LLM 摘要）

由 **Install summarize** (`installSummarize`) 啟用。
[`steipete/summarize`](https://github.com/steipete/summarize) 把一個 URL 或檔案變成摘要：
YouTube 影片、podcast、網頁、PDF、本地音訊與影片。它自己負責內容擷取管線
（官方字幕 → transcript API → `yt-dlp` 音訊 → Whisper），再把文字交給你指定的模型。

有兩個特性讓它值得放進來：它可以直接沿用**已登入的 coding CLI** 當後端
（`--cli claude`、`--cli codex`、`--cli gemini`、`--cli pi`），完全不需要額外的 API key；
而且輸出語言是一個 config 鍵，所以 Windows 與瀏覽器介面維持英文的同時，摘要仍固定回繁體中文。

與上游 `daviddwlee84/dotfiles` 使用相同的 toggle、相同的 config overlay、相同的包裝函式名稱——
這是原生移植 (native port)，不是共用實作。

## 安裝

summarize **沒有 scoop 或 winget manifest**。packages 腳本以 npm 全域套件安裝，需要
**Node 24+**，由 baseline 的 `nodejs-lts` 滿足：

```powershell
Scoop-Install @('ffmpeg', 'yt-dlp', 'tesseract')
Npm-InstallGlobal @('@steipete/summarize')
```

`ffmpeg` 與 `yt-dlp` 支撐音訊管線，`tesseract` 支撐 `--slides-ocr`。三者都來自
`Ensure-Scoop` 已經加入的 `main` bucket；若 `installMediaTools` 也開著，`ffmpeg` 會共用。

如同本 repo 各處，apply 只負責安裝 (install-only)。升級要明確執行：

```powershell
just upgrade-summarize
```

它刻意**不**併入 `just upgrade-npm-agents`——summarize 是一般 npm 全域套件，
不屬於 Pi 自有的 agent prefix。

## 設定

`~/.summarize/config.json` 是 chezmoi 的 **`modify_` overlay**
（`dot_summarize/modify_config.json.ps1`），原因有兩個：

- **這個路徑搬不走。** summarize 把 `~/.summarize/config.json` 寫死了——沒有 XDG 查找，
  也沒有 `SUMMARIZE_CONFIG` 覆寫。這裡不使用 junction 或 symlink
  （hard invariant 6：Windows 上建立連結需要提權或 Developer Mode）。
- **summarize 自己會寫這個檔。** `summarize refresh-free` 會把 OpenRouter 免費模型
  presets 寫進去，`--set-default` 則持久化模型選擇。一般受管檔案會在每次 apply 覆蓋掉兩者。

overlay 刻意寫得很小：

```json
{
  "output": {
    "language": "zh-TW",
    "length": "medium"
  }
}
```

合併模型：以現存檔案為基底 (base)，overlay 的葉節點勝出，巢狀物件遞迴合併，
純量與陣列整個取代。現存檔案的屬性順序會保留，所以重複 apply 是位元組穩定 (byte-stable) 的。
所有失敗路徑——stdin 讀不到、非 UTF-8 位元組、無效 JSON、根節點不是物件——
都原封不動地把原始位元組輸出回去並在 stderr 警告；設定的復原永遠是明確動作。

頂層的 `prompt` 鍵**刻意不設**：它會取代 summarize 內建的摘要指令，而且對**所有**來源類型
生效，不只影片。分來源的 prompt 改走 `--prompt-file`。

!!! note "這是本 repo 第一個 JSON `modify_`"
    Hard invariant 5 把*編輯器*的 JSON 交給 `run_onchange` merger 處理，是因為
    `modify_` 在 Windows 上的直譯器 (interpreter) 選擇不可靠。`.ps1` 後綴消除了這個歧義——
    `.chezmoi.toml.tmpl` 裡的 `[interpreters.ps1]` 把它對應到 pwsh，chezmoi 在解析目標檔名時
    會把它去掉——這正是 `dot_codex/modify_config.toml.ps1.tmpl` 與 herdr overlay 已經在用的機制。

## Prompt presets

放在 `~/.config/summarize/prompts/` 的一般受管檔案（summarize 不會寫這裡）。
它們與上游 repo 的副本以手動維持**位元組相同 (byte-identical)**——
與共用的 `copilot-throttle-shim.js` 是同一種安排。

| 檔案 | 結構 |
|---|---|
| `youtube-zhtw.md` | TL;DR → 主要論點 → 值得注意的細節 → 重要時間點 → 值不值得完整觀看 |
| `quickscan-zhtw.md` | 一句話結論 → 三個重點 → 值得 / 略讀即可 / 跳過 |

## 指令

`dot_config/powershell/profile.d/32_summarize.ps1`——fragment 編號刻意與 POSIX 版一致。

```powershell
# 直接呼叫——因為受管 config，已經是繁體中文
summarize 'https://youtu.be/xxxx'

ytsum 'https://youtu.be/xxxx'                  # 影片：TL;DR + 論點 + 時間點 + 值不值得看
sumq  'https://example.com/long-post'          # 30 秒分流：要讀還是跳過
suml  'https://youtu.be/xxxx'                  # 長版，使用上游內建結構
sumj  'https://youtu.be/xxxx' | ConvertFrom-Json   # JSON envelope

summarize 'https://youtu.be/xxxx' --cli claude     # 沿用已登入的 agent
summarize 'https://youtu.be/xxxx' --language en    # 單次覆蓋受管語言
summarize status --verbose                          # 這台機器有哪些 provider？
```

## YouTube 管線如何降級 (degrade)

```text
官方字幕軌
        │ 取不到
youtubei / Apify transcript
        │ 取不到
yt-dlp 音訊 → Whisper
        │
        └─→ 你選的模型
```

`--slides` 會加上場景變化的關鍵影格 (keyframes)，`--slides-ocr` 對它們做 OCR，
`--extract` 則完全跳過模型，只回傳清理過的原始文字。
