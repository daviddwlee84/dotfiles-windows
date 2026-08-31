# summarize (YouTube / web / PDF → LLM summary)

Enabled by **Install summarize** (`installSummarize`).
[`steipete/summarize`](https://github.com/steipete/summarize) turns a URL or a file into
a summary: YouTube videos, podcasts, webpages, PDFs, local audio and video. It owns the
ingestion pipeline (captions → transcript APIs → `yt-dlp` audio → Whisper) and then
hands the text to whichever model you point it at.

Two properties earn it a place here. It can drive an **already-authenticated coding
CLI** as its backend (`--cli claude`, `--cli codex`, `--cli gemini`, `--cli pi`), so no
extra API key is involved. And the output language is a config key, so summaries come
back in 繁體中文 with the Windows and browser UI left in English.

Same toggle, same config overlay and same wrapper names as the parent
`daviddwlee84/dotfiles` repo — this is a native port, not a shared implementation.

## Install

There is **no scoop or winget manifest** for summarize. The packages script installs it
as an npm global, which needs **Node 24+** — met by the baseline `nodejs-lts`:

```powershell
Scoop-Install @('ffmpeg', 'yt-dlp', 'tesseract')
Npm-InstallGlobal @('@steipete/summarize')
```

`ffmpeg` and `yt-dlp` back the audio pipeline; `tesseract` backs `--slides-ocr`. All
three come from the `main` bucket that `Ensure-Scoop` already adds, and `ffmpeg` is
shared with `installMediaTools` if that toggle is also on.

Apply is install-only, as everywhere in this repo. Upgrade explicitly:

```powershell
just upgrade-summarize
```

That is deliberately **not** part of `just upgrade-npm-agents` — summarize is a plain
npm global, not part of Pi's owned agent prefix.

## Configuration

`~/.summarize/config.json` is a chezmoi **`modify_` overlay**
(`dot_summarize/modify_config.json.ps1`), for two reasons:

- **The path cannot be moved.** summarize hardcodes `~/.summarize/config.json` — no XDG
  lookup, no `SUMMARIZE_CONFIG` override. No junction or symlink is used
  (hard invariant 6: links need elevation or Developer Mode on Windows).
- **summarize writes this file itself.** `summarize refresh-free` rewrites the
  OpenRouter free-model presets into it and `--set-default` persists a model choice. A
  plain managed file would clobber both on every apply.

The overlay is small on purpose:

```json
{
  "output": {
    "language": "zh-TW",
    "length": "medium"
  }
}
```

Merge model: the live file is the base, overlay leaves win, nested objects merge
recursively, and scalars and arrays are replaced wholesale. Property order of the live
file is preserved, so re-applies are byte-stable. Every failure path — unreadable stdin,
non-UTF-8 bytes, invalid JSON, a non-object root — echoes the original bytes back
unchanged and warns on stderr; config recovery is always explicit.

The top-level `prompt` key is **deliberately absent**: it replaces summarize's built-in
summary instructions for *every* source type, not just video. Per-source prompts go
through `--prompt-file`.

!!! note "This is the repo's first JSON `modify_`"
    Hard invariant 5 sends *editor* JSON through a `run_onchange` merger because
    `modify_` interpreter selection is unreliable on Windows. The `.ps1` suffix removes
    that ambiguity — `[interpreters.ps1]` in `.chezmoi.toml.tmpl` maps it to pwsh and
    chezmoi strips it when resolving the target name — which is the same mechanism
    `dot_codex/modify_config.toml.ps1.tmpl` and the herdr overlay already rely on.

## Prompt presets

Plain managed files under `~/.config/summarize/prompts/` (summarize never writes here).
They are kept **byte-identical to the parent repo's copies** by hand — the same
arrangement as the shared `copilot-throttle-shim.js`.

| File | Shape |
|---|---|
| `youtube-zhtw.md` | TL;DR → 主要論點 → 值得注意的細節 → 重要時間點 → 值不值得完整觀看 |
| `quickscan-zhtw.md` | 一句話結論 → 三個重點 → 值得 / 略讀即可 / 跳過 |

## Commands

`dot_config/powershell/profile.d/32_summarize.ps1` — the fragment number matches the
POSIX sibling on purpose.

```powershell
# Plain call — already 繁體中文, thanks to the managed config
summarize 'https://youtu.be/xxxx'

ytsum 'https://youtu.be/xxxx'                  # video: TL;DR + 論點 + 時間點 + 值不值得看
sumq  'https://example.com/long-post'          # 30-second triage: read it or skip it
suml  'https://youtu.be/xxxx'                  # long, upstream's built-in structure
sumj  'https://youtu.be/xxxx' | ConvertFrom-Json   # JSON envelope

summarize 'https://youtu.be/xxxx' --cli claude     # reuse an authenticated agent
summarize 'https://youtu.be/xxxx' --language en    # override the managed language once
summarize status --verbose                          # which providers does this box have?
```

## How the YouTube pipeline degrades

```text
official caption track
        │ unavailable
youtubei / Apify transcript
        │ unavailable
yt-dlp audio → Whisper
        │
        └─→ your chosen model
```

`--slides` adds scene-change keyframes, `--slides-ocr` OCRs them, and `--extract` skips
the model entirely and returns the cleaned source text.
