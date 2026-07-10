# 28_tldr.ps1 — tldr language-preference helper.
#
# Native PowerShell port of the cross-platform dot_config/shell/28_tldr.sh.
# `tldrf` runs the tldr client (tlrc, installed via scoop) with a fallback chain
# of languages: tlrc accepts `-L` multiple times and tries them in order, so a
# page missing in zh_TW falls back to zh, then en. Plain `tldr` keeps its native
# behaviour. Override the order in your untracked local.ps1 if you like.

# Language preference order for tldrf fallback.
$TLDR_LANGUAGES = @('zh_TW', 'zh', 'en')

function tldrf {
    if (-not (Get-Command tldr -ErrorAction SilentlyContinue)) { return }
    $langFlags = foreach ($lang in $TLDR_LANGUAGES) { '-L'; $lang }
    & tldr @langFlags @args
}
