# Agent 語言規則（`agentLanguagePolicy`）

Coding agent 用什麼語言寫東西，取決於**誰會讀、會留多久**：對話用繁體中文；plan 檔用繁體中文，專有名詞保留英文；長期文件跟著 repo 既有慣例，沒有慣例就用英文。Key、prompt 文字和規則內容都跟 parent（macOS/Linux）repo 相同。

> **TL;DR** —— 在 *Agent language policy (none|zh-TW)* 這題選 `zh-TW`，`chezmoi apply` 之後會部署 `%USERPROFILE%\.claude\rules\language-policy.md`。你自己的 `~/.claude/CLAUDE.md` 如果存在，完全不會被動到。

## 規則內容

| 輸出 | 語言 |
|---|---|
| 對話：回覆、提問（包含選擇題選項）、進度回報 | 繁體中文（台灣用語） |
| Plan mode 的 plan 檔 | 敘述用繁體中文，標題可以中英並列 |
| README、`docs/`、ADR、docstring、code comment、commit message、PR | 照 repo 慣例（以 repo 的 CLAUDE.md / AGENTS.md 為準），沒有慣例就用英文 |
| 內部推理（thinking） | 不限制，用最有效的方式（通常是英文） |

中文內容裡，翻譯後可能有歧義的技術名詞、identifier 和產品名稱都保留英文。

規則原文以 `.chezmoitemplates/agent-language-policy.md` 為準，跟 parent repo 的那份逐字相同。`.gitattributes` 把它固定成 LF，所以 Windows checkout 下兩份也不會出現差異。兩個 repo 並排 checkout 時，`tests/AgentLanguagePolicy.Tests.ps1` 會比對兩份內容。

## 怎麼接起來的

- **Prompt**：`agentLanguagePolicy`（`none` | `zh-TW`，預設 `none`），要搭配 `installCodingAgents` 才會生效。
- **部署目標**：`~/.claude/rules/language-policy.md`。Claude Code 會把 `~/.claude/rules/` 底下每個檔案當作 user-level rule，在所有 project 中跟 `~/.claude/CLAUDE.md` 一起載入。
- **Gate**：沒開 gate 時，`dot_claude/rules/language-policy.md.tmpl` 會 render 成空字串；chezmoi 遇到 render 結果是空的 target 會把它刪掉，所以改回 `none` 就會移除這個 rule。這是一般檔案，不是 `modify_` script，也不是 deep-merger：Claude Code 不會寫入這個檔案，所以不需要跟其他程式共用它。

改設定：修改 `%USERPROFILE%\.config\chezmoi\chezmoi.toml` 裡的 `agentLanguagePolicy`（或重跑 `chezmoi init --prompt`），再執行 `chezmoi apply`。驗證方式：在新的 Claude Code session 執行 `/memory`。

## 設計取捨

- **不用 `settings.json` 的 `language`**：Claude Code 會把它原樣變成「always respond in X」，commit 和 docs 也會被拉成中文，還會一起改 voice dictation 和 session title 的語言。
- **不寫進 `~/.claude/CLAUDE.md`**：那是使用者手寫的檔案。改用獨立的 rules 檔，就完全不需要 migration 或 merge。如果你的 CLAUDE.md 也有語言規則，兩邊會同時載入，Claude 可能照任一邊做，所以請刪掉其中一邊。
- **Plan 檔單獨列一條**，不然會被「文件用英文」那條規則吃掉。
- **不限制 thinking**：強制用使用者的語言寫 thinking trace 會降低準確度（例如 Qi et al. 2025）。
- **目前只涵蓋 Claude Code**，Codex 的延伸記在 `TODO.md`。
