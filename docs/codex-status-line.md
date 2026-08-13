# Codex status line

The Windows profile uses Codex's built-in TUI footer. Chezmoi enforces only
this list and preserves all unrelated live TOML, including providers, project
trust, plugins, feature flags, and nested keymaps:

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

The modifier uses Bun's built-in TOML parser, which is installed in the baseline
toolset. It performs no Python or package-registry access during `chezmoi apply`,
so managed machines that block PyPI still get the footer. It accepts one leading
UTF-8 BOM as an encoding signature.
Malformed TOML, invalid UTF-8, a parser failure, or an invalid managed overlay is
fail-closed: the original stdin bytes are emitted exactly, including CRLF. A
successful merge is normalized to UTF-8 without BOM, LF line endings, and one
final newline. The file is deployed only when **Install coding agents** is
enabled.

Use `/status` as the routing proof. A `codex-copilot` session should show the
localhost provider even though the Account line can still show the logged-in
ChatGPT account. The managed footer omits `five-hour-limit` and `weekly-limit`
because those may remain ChatGPT-account counters while inference uses Copilot.

No Claude-HUD-style extension is installed. Stock Codex accepts only fixed
built-in item IDs, while `@jiawang1209/codex-hud` patches and compiles an older
Codex tree and adds a PATH shim. The maintenance and supply-chain cost is too
high for a footer.

`codex_apps` is a separate remote ChatGPT MCP at
`https://chatgpt.com/backend-api/wham/apps`, not an Apple Silicon Desktop bridge.
Use `copilot-proxy doctor --live` to compare its direct and HTTP-proxy routes.

See [copilot-proxy](copilot-proxy.md) and the
[Codex config reference](https://developers.openai.com/codex/config-reference).
