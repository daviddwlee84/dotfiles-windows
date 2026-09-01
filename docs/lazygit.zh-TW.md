# LazyGit branch 洞察

PowerShell profile 會設定 `XDG_CONFIG_HOME`，所以 LazyGit 讀取受管理的
`~/.config/lazygit/config.yml`。設定保留既有的 `delta` diff renderer，並讓
Local branches 面板以狀態資訊為優先：

- Nerd Font v3 圖示。
- 依 feature、fix、docs、維護、worktree 與 automation branch prefix 上色。
- 依最近使用順序 (recency) 排列。
- 右側顯示 base-branch divergence (`↓N`)。

`↓N` 表示 branch 比 LazyGit 偵測到的 base branch 落後；它不代表 branch
已 merged，因為該 branch 仍可能有自己的 commit。原本的 upstream `✓` 也只
表示 local 與 upstream 同步，不代表 main 已包含該 branch。

## `I` Branch insights

在 Local branches 面板按 **`I`**，再選：

| 按鍵 | 報告 | 網路 |
|---|---|---|
| `g` | 以 local 與 remote-tracking main 做精確 Git containment 判斷 | 不使用 |
| `p` | 同一份報告，再透過一次 `gh pr list` 補近期 GitHub PR 狀態 | GitHub |

原生 PowerShell helper 完全唯讀，不會 fetch、checkout、刪除或修改 ref。
因此要依賴 remote 結果前，請先 refresh LazyGit。

```text
Local base:  main
Remote base: origin/main
Local main vs origin/main: ahead 1, behind 0

SEL LOC REM  BASE-  BASE+ UPSTREAM      WORKTREE     DATE       BRANCH  PR
    Y   Y       12      0 gone          -            2026-08-20 fix/old  MERGED->main#42
>   Y   N        0      1 up1           repo-wt      2026-09-01 feat/new OPEN->main#43
```

- `LOC` / `REM`：branch tip 是否為 local / remote main 的 ancestor。
- `BASE-` / `BASE+`：只存在 comparison base／只存在 branch 的 commit 數。
- `UPSTREAM`：`=`、`upN`、`downN`、`downN/upN`、`gone` 或 `-`。
- `WORKTREE`：正在使用該 branch 的 worktree 末層目錄名。
- `PR`：best-effort GitHub 狀態。Squash merged PR 可以同時顯示
  `PR=MERGED` 與 `REM=N`，因為兩欄回答的是不同問題。

Base 偵測依序檢查 `origin/HEAD`、`main`、`master`。使用其他 trunk 的 repo
可自行 override：

```powershell
git config lazygit.branchBase develop
```

也接受 `upstream/trunk` 一類的 remote-tracking 值。

## Diff 呈現

LazyGit v0.64+ 使用 `git.diffRenderers`；本 repo 以 `delta` 提供深色、無分頁
輸出。設定刻意不使用已棄用的 `git.pagers` 格式，避免 LazyGit 重寫 chezmoi
管理的檔案。

## 參考資料

- [LazyGit 設定](https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md)
- [LazyGit custom commands](https://github.com/jesseduffield/lazygit/blob/master/docs/Custom_Command_Keybindings.md)
- [GitHub CLI PR list](https://cli.github.com/manual/gh_pr_list)
