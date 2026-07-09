-- WakaTime time-tracking. Disabled by default on Windows: vim-wakatime
-- re-downloads wakatime-cli to ~/.wakatime/ on EVERY launch when the binary
-- can't persist (Defender quarantine / blocked downloads on managed machines),
-- and it needs a WakaTime API key (~/.wakatime.cfg) to do anything useful.
-- Flip enabled = true if you actually use WakaTime.
return {
  "wakatime/vim-wakatime",
  enabled = false,
  lazy = false,
}
