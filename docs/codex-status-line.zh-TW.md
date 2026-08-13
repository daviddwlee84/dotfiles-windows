# Codex status line

Windows profile 使用 Codex 內建 TUI footer。Chezmoi 只強制下列清單，並保留其餘
live TOML，包括 providers、project trust、plugins、feature flags 與 nested keymaps：

```toml
[tui]
status_line = [
  "model-with-reasoning",
  "fast-mode",
  "git-branch",
  "context-remaining",
  "task-progress",
  "current-dir",
]
```

Modifier 以 `uv` 執行釘選版本的 `tomlkit` parser；bootstrap 會在 chezmoi 前安裝
`uv`。它接受一個開頭的 UTF-8 BOM 作為 encoding signature。TOML 損壞、UTF-8 無效、
parser 失敗或 managed overlay 無效時一律 fail-closed，逐 byte 輸出原始 stdin（包括
CRLF）。只有成功 merge 才正規化成無 BOM 的 UTF-8、LF line ending 與一個結尾換行。
只有啟用 **Install coding agents** 才會部署此檔。

實際路由以 `/status` 為準。`codex-copilot` session 應顯示 localhost provider；Account
仍顯示已登入 ChatGPT 帳號不代表 inference 沒走 Copilot。Footer 刻意省略
`five-hour-limit` 與 `weekly-limit`，因為 provider 已切到 Copilot 時，這些仍可能是
ChatGPT-account counters。

不安裝 Claude-HUD 類 extension。原生 Codex 只接受固定 built-in item ID；
`@jiawang1209/codex-hud` 則 patch/compile 舊 Codex tree 並加入 PATH shim。為 footer
承擔這個維護與 supply-chain cost 不划算。

`codex_apps` 是 `https://chatgpt.com/backend-api/wham/apps` 的獨立遠端 ChatGPT
MCP，不是 Apple Silicon Desktop bridge。用 `copilot-proxy doctor --live` 比較它的
direct 與 HTTP-proxy 路徑。

另見 [copilot-proxy](copilot-proxy.zh-TW.md) 與
[Codex config reference](https://developers.openai.com/codex/config-reference)。
