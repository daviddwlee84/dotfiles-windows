# 32_summarize.ps1 — summarize CLI helpers.
#
# Native PowerShell port of the cross-platform dot_config/shell/32_summarize.sh; the
# fragment number matches on purpose. Output language and length come from the managed
# ~/.summarize/config.json overlay (dot_summarize/modify_config.json.ps1), so plain
# `summarize <url>` already answers in 繁體中文. These wrappers only add per-source
# prompt presets on top; override the language per call with `--language en`.
#
# https://github.com/steipete/summarize

if (Get-Command summarize -ErrorAction SilentlyContinue) {

    $script:SummarizePromptDir = Join-Path $HOME '.config/summarize/prompts'

    # YouTube / long video: TL;DR + 論點 + 時間點 + 值不值得看
    function ytsum {
        & summarize @args --prompt-file (Join-Path $script:SummarizePromptDir 'youtube-zhtw.md')
    }

    # 30-second triage of any source: read it or skip it
    function sumq {
        & summarize @args --prompt-file (Join-Path $script:SummarizePromptDir 'quickscan-zhtw.md') --length short
    }

    # Full-length summary, upstream's built-in structure
    function suml {
        & summarize @args --length long
    }

    # Machine-readable envelope, for piping into jq or an agent
    function sumj {
        & summarize @args --json
    }
}
