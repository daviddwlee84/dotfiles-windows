# Yazi 檔案管理員

Yazi 透過 Scoop 安裝，並由受管的 `YAZI_CONFIG_HOME` 讀取 `~/.config/yazi`。
在 PowerShell 執行 `y`，離開後會停在 Yazi 最後瀏覽的目錄；在 Herdr 使用
`prefix+Y`，則會從聚焦 agent pane 的 cwd 開啟一次性的檔案管理 pane。

## Git 狀態標記

受管的 [`git.yazi`](https://github.com/yazi-rs/plugins/tree/main/git.yazi)
fetcher 會替檔案與目錄顯示彩色狀態，涵蓋 untracked、unstaged、staged、added、
deleted、updated 與 ignored。子孫的變更會向上彙總到父目錄。

釘選的 plugin 需要配對的 Yazi／Ya **26.8.15+**：

```powershell
just upgrade-yazi-plugins
```

此指令會先升級 Scoop 的 `yazi` package，再執行 `ya pkg upgrade`。
`chezmoi apply` 維持 install-only：self-healing hook 只補裝缺少的 locked revision，
不會自行升版。

升級後要把重新產生的 `~/.config/yazi/package.toml` 複製回 chezmoi source 的
`dot_config/yazi/package.toml` 再 commit，否則後續 apply 會恢復成先前 commit 的 revision。

升級空窗期間舊主機仍可正常瀏覽。`init.lua` 會顯示警告，而跨平台逐位元組相同的
`git-guard.yazi` 會改用 Yazi 的 `noop` fetcher，直到真正的 plugin 能載入。

## Herdr launcher

Windows Herdr preview 仍不接受 `type = "popup"`，所以 `prefix+Y` 會開 temporary
command pane。它與 macOS/Linux 使用相同按鍵與聚焦 pane cwd，離開 Yazi 後自動關閉。
最後目錄不會改變來源 agent pane；需要這個行為時請用 PowerShell `y` helper。
