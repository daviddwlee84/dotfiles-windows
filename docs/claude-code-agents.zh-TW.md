# 附錄：同時執行多個 Claude Code agent

!!! note "為什麼有這一頁"
    這個 repo 大多由**並行的 Claude Code agent** 維護（例如 herdr 那次改動就是由一個
    背景 job 在隔離的 worktree 裡完成的）。本頁與 Windows 無關 —— 它記錄多 session 的
    工作流,以及 **git worktree 隔離**模型,讓未來的我(和未來的 agent)不必重新推敲。
    以下行為以 Claude Code **2.1.x**(2026 年中)為準;鍵位會演進,在 Agent View 按 `?`
    可看即時清單。

## 心智模型:三種並行方式

| 方式 | 是什麼 | 隔離 | 何時用 |
|---|---|---|---|
| **Subagent**(Task/Agent 工具) | *單一 session 內*、有自己 context 的 worker,回傳摘要 | 共用該 session 的工作副本 | 側支任務(搜尋、調研)會淹沒主 context 時 |
| **背景 session**(`claude --bg`、Agent View) | *獨立*、卸離的 Claude Code 行程 | **自動隔離在各自的 git worktree** | 多個獨立任務,丟出去之後再回來看 |
| **手動 worktree**(`claude --worktree`、`EnterWorktree`) | 在隔離的 checkout 裡跑一般 session | 自己的 worktree + branch | 想要一個不會和 `main` 衝突的前景 session |

消除心智負擔的關鍵:**你很少需要手動管理 worktree。** 背景 session 會替你建立、命名、
清理它們;Agent View 就是你唯一要看的儀表板。

## 磁碟上實際發生什麼(不是 symlink、也不是 `.claude/workspace`)

當背景 job 準備改檔案時,它會先把自己隔離:

```
<repo>/.claude/worktrees/<name>/      ← 一個真正的 git worktree(完整 checkout)
   └── .git                            ← 是「檔案」而非目錄:"gitdir: <repo>/.git/worktrees/<name>"
```

- 它是**標準的 `git worktree`**,位於新分支 **`worktree-<name>`**,可用
  `git worktree list` 列出。它**不是 symlink**,也**沒有 `.claude/workspace/`**
  這個目錄 —— 如果你在 `.claude/` 底下看到 symlink,那是別的東西(例如共用的
  `skills/`,或 repo 自己的 `CLAUDE.md → AGENTS.md`)。
- 分支預設從 **`origin/HEAD`**(遠端預設分支)切出,因此基底是乾淨的 —— 見下方
  `worktree.baseRef`。

隨時可驗證:

```bash
git worktree list          # 每個 checkout 與其 branch
cat .claude/worktrees/<name>/.git   # 證明它是 worktree 指標,不是複製
```

## 控制隔離的設定

在 `.claude/settings.json`:

| 設定 | 值 | 效果 |
|---|---|---|
| `worktree.bgIsolation` | *(未設 = 隔離)* / `"none"` | `"none"` 會**關閉**背景 job 的自動隔離 —— 它們直接改主 checkout。worktree 不方便時用。 |
| `worktree.baseRef` | `"fresh"`(預設) / `"head"` | `fresh` 從 `origin/HEAD` 切出(乾淨);`head` 從你本地 `HEAD` 切出(帶著未推送/進行中的 commit)。 |

自動隔離是強制的:在背景 job 裡,**對共用 checkout 的檔案編輯會被拒絕,直到你隔離為止**。
拒絕訊息還會告訴你退出方式(`worktree.bgIsolation: "none"`)。前景互動 session **不會**
自動隔離 —— 想在那邊要隔離,就用 `claude --worktree <name>` 或 `EnterWorktree` 工具。

## Agent View —— 多 session 儀表板

用 `claude agents` 開啟(或在 session 內用 `/background` / `/bg`)。

**範圍 —— 回答「是不是整臺機器?」:** 是。Agent View 預設列出**這臺機器上、你這個
使用者的每一個背景 session,跨所有 repo 與目錄。** 要限縮到單一專案,用
`claude agents --cwd <path>` 啟動。新 session 會派送到你開啟該 view 的目錄;要派到別的
repo,在 prompt 裡用 `@` 提及它。

常用鍵(按 `?` 看完整清單):

| 鍵 | 動作 |
|---|---|
| `↑` / `↓` | 在 session 間移動 |
| `Enter` / `→` | 附著(attach)到選定的 session |
| **`←`** | 卸離 / 回到 Agent View(就是你注意到的那個鍵) |
| `Space` | 偷看(peek)—— 狀態 / 待回覆問題,可就地回覆 |
| `Shift+Enter` | 派送新 session **並**立即附著 |
| `Ctrl+T` | 釘選(閒置時保持行程存活) |
| `Ctrl+X` | 停止(約 2 秒內再按一次即刪除) |

## 最佳實踐

1. **一個 worktree = 一件工作。** 別把不相關的改動疊在已合併的分支上。herdr 那次改動與
   *這份*文件是在不同 worktree 裡做的(`worktree-herdr`、`worktree-docs-agents`),各有
   自己的分支與 PR。
2. **要交付,別卡住。** 背景 job 不是「程式碼寫完」就結束:commit → push 分支 → 開
   **draft PR**,再讓人來 merge。本 repo 的 agent 絕不 push 到 `main`、絕不 force-push、
   絕不自己 merge(見 `AGENTS.md`)。
3. **讓 CI 當合併前的關卡。** 在非 Windows 上我們只能 render/parse/lint;`windows-latest`
   的 PR check 才是權威。綠燈後再合。
4. **用工具而非記憶對抗「我在哪個分支?」的混淆:**
    - 在 prompt 保留**分支欄位**(starship 的 `git_branch` 已經會顯示),讓每條指令都告訴你身處何處;
    - 把 **Agent View** 當唯一儀表板,而不是靠追蹤一堆終端機;
    - 不確定時跑 `git worktree list` —— 那是事實來源。
5. **注意清理。** 沒有未提交/未追蹤/未推送變更的 worktree,會在 `cleanupPeriodDays`
   (預設 30 天)後自動移除。已合併的工作 → 讓它被回收,或現在用 `ExitWorktree`(remove)/
   `git worktree remove <path>` 加 `git push origin --delete <branch>` 移除。
6. **留意成本。** 每個背景 session 各自消耗 token、各自受 rate limit —— 並行會使用量倍增。
   只開你真的會看的那幾個。

## 這個 repo 的 agent 工作流(具體範例)

herdr 那次改動就是這個迴圈的實例:

1. 背景 job → 自動隔離到 `.claude/worktrees/herdr`(`worktree-herdr`)。
2. 在 worktree 內編輯 + 驗證(render/parse、`tomllib`、PSScriptAnalyzer、Pester、`mkdocs --strict`)。
3. `commit` → `git push -u origin worktree-herdr` → `gh pr create --draft`。
4. 人來 review、CI 綠燈、人來 merge。agent **不會**合併到 `main`。

## 參考

- [Worktrees](https://code.claude.com/docs/en/worktrees.md) —— `--worktree`、隔離、`baseRef`、清理、`.worktreeinclude`
- [Agent View](https://code.claude.com/docs/en/agent-view.md) —— 儀表板、鍵位、範圍、派送
- [Common workflows → 並行 session](https://code.claude.com/docs/en/common-workflows.md) —— worktree 對比 subagent
- [選擇 agent 方式](https://code.claude.com/docs/en/agents.md) · [Settings](https://code.claude.com/docs/en/settings.md) · [`.claude` 目錄](https://code.claude.com/docs/en/claude-directory.md)
