# 跨平台 Git checkout

Repository 同時在 Windows、macOS、Linux 與 WSL 使用時，會跨越 Git 無法完全抹平的
filesystem 差異。受管的全域預設刻意保持精簡：`core.autocrlf = input` 讓 commit 中的
文字維持 LF，`core.symlinks = true` 則要求 Git 在 Windows 建立真正的 link。個別檔案的
EOL 與 binary 規則仍以 repo 自己的 `.gitattributes` 為準。

## 檢查與修復

```powershell
# 唯讀檢查目前 repository
git-windows-doctor

# 只修復安全的 symlink placeholder
gwinfix

# 檢查或修復一批既有 repository
git-windows-doctor -Root ~/Documents/Program
gwinfix -Root ~/Documents/Program -WhatIf
gwinfix -Root ~/Documents/Program
```

`gwinfix` 只會替換 bytes 與目前 Git index 內 symlink target 完全一致的普通檔案，
或還原目前缺少的 tracked symlink。它會拒絕已修改的檔案、真正目錄、target 不符的
link 與 unmerged index entry，並在刪除任何內容前先測試 Windows symlink 建立能力。
成功修復後，它會移除 repo-local `core.symlinks` override，讓受管的 user-level `true`
成為有效值。只改 Git 設定不會重寫已 checkout 的路徑，因此舊 clone 仍需要這次性修復。

其他 findings 一律唯讀；尤其不會自動執行 `git add --renormalize .`、修改 executable
bit、重新命名路徑、安裝 Git LFS，或切換 filesystem case sensitivity。

## 常見 portability 邊界

| 項目 | 換 OS 時的故障模式 | Policy／修復方式 |
|---|---|---|
| Symbolic link | Git for Windows 把 link checkout 成只有一行 target 的普通檔案 | 開啟 Windows Developer Mode、維持 `core.symlinks=true`，舊 checkout 再執行一次 `gwinfix`。 |
| 換行 | Shell script 變成 CRLF、generated file 出現 mixed EOL，或 `safecrlf` 拒絕 `git add` | 提交明確的 `.gitattributes`，用 `git ls-files --eol` 檢查；只在乾淨 branch 上 renormalize 並審查 diff。 |
| Executable bit | Windows 無法從 filesystem 推斷 Unix execute bit | 用 `git update-index --chmod=+x path/to/script` 寫進 index；不要用全域 `core.filemode=true` 代替。 |
| 大小寫 | 一般 Windows/macOS volume 無法同時可靠處理 `Foo.py` 與 `foo.py`，case-only rename 也可能失敗 | 檔名在不分大小寫後仍須唯一；只改大小寫時先 `git mv` 到中間名稱。 |
| Windows 檔名 | `CON`、`NUL`、尾端句點／空白，以及 `:`、`*` 等字元無法正常 checkout | 從相容 filesystem 於 Git 中改名；不要把停用 `core.protectNTFS` 當成日常解法。 |
| 過長路徑 | Git 或下游 Windows 工具在傳統 path 長度附近失敗 | 優先縮短 repo／路徑名稱；只有需要時才開 `core.longpaths`，因為 Git 以外的程式仍可能有限制。 |
| Git LFS | Checkout 後只剩 pointer 文字而非 binary asset | 安裝 Git LFS、執行 `git lfs install`，再 fetch／checkout 所需 objects。 |
| Windows + WSL | 兩套 Git 對同一 worktree 套用不同 config、permission、path 與 watcher 行為 | 原生 Windows 與 WSL 優先使用不同 clone；若一定要共用，只讓其中一套 Git 執行寫入。 |
| Encoding | UTF-8 BOM 破壞 Unix shebang；Windows PowerShell 5.1 對無 BOM UTF-8 的解讀不同於 PowerShell 7 | Shell scripts 使用無 BOM UTF-8/LF；legacy Windows PowerShell 檔案應個別處理，不要對整個 repo 套同一種 encoding rewrite。 |

## 建議的 `.gitattributes` baseline

請依 repo 調整；binary 與 generated-file exceptions 是 policy 的一部分，不是可省略的裝飾：

```gitattributes
* text=auto eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf
*.png binary
*.jpg binary
*.pdf binary
```

新增或修改 `.gitattributes` 後，任何有意的 renormalization 都應獨立執行：

```powershell
git status --short
git add --renormalize .
git diff --cached --check
git diff --cached
```

只在乾淨、專用的 branch 上進行。EOL normalization 合理地可能改動大量檔案，因此
永遠不屬於 `gwinfix` 的工作。
