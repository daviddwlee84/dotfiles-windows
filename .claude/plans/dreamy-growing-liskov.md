# Context

目前 `main` 落後 upstream 三個 commit，但工作樹同時含 staged/unstaged 的 SpecStory artifacts 與舊版 PowerShell 修補；upstream 又把 `00_env.ps1` 改名為 `00_env.ps1.tmpl` 並修改相同 PATH 區段，因此直接 `git pull` 有覆寫或衝突風險。先前 `chezmoi apply` 實際 exit 0，但暴露 Rime 已安裝卻被誤判失敗、舊 Herdr 不支援 `--skill`、錯誤 retry state key；完整測試另有 Codex double-mojibake BOM 回歸。目標是在不遺失任何本機 bytes／index 狀態、不建立未要求的 commit 下安全更新 upstream，修復真實失敗，再完成 apply 與新 shell smoke test。

## 1. 保存工作樹並安全 fast-forward

- 記錄 `git status --porcelain=v2`、staged/unstaged binary diff、現有 stash 清單。
- 用具名 `git stash push --include-untracked` 保存 index、工作樹和未追蹤檔，立即記錄 stash object ID；不使用 `pop`，也不碰既有 stashes。
- 確認工作樹乾淨後執行 `git pull --ff-only origin main`，確認 `HEAD...origin/main` 無 divergence；若不能 fast-forward，停止而不改寫歷史。
- 以固定 stash OID 執行 `git stash apply --index`。保留 SpecStory history/statistics 原本的 staged/unstaged 邊界與 bytes。
- 針對 rename 衝突保留 upstream 的 `dot_config/powershell/profile.d/00_env.ps1.tmpl`；不重播會讓 bare `dev` 再次搶名的舊 PATH 重排。保留 commit `33ba77f` 的共存契約：Microsoft DevTool 使用 `dev`，repo-owned binary 使用 `dev-cli`，completion 與 Herdr 也使用 `dev-cli`。
- 將 `tests/DevCli.Tests.ps1` 中指向舊 `00_env.ps1` 且未使用的 `$EnvProfile` delta 還原為 upstream；原內容仍留在 safety stash。

## 2. 先重現並修復現有測試失敗

- 針對 `tests/CodexConfig.Tests.ps1` 的 double-mojibake BOM fixture 單獨重現，追蹤 `dot_codex/modify_config.toml.ps1.tmpl` 的 prefix repair、TOML merge 與 `tui.status_line` 驗證。
- 修復根因但不削弱 fail-closed 契約：未知／非法輸入仍 byte-preserving，真正 double BOM 仍拒絕，成功輸出維持 BOM-free UTF-8/LF、保留非 managed TOML，並保持 managed status-line 最終驗證。
- 加強 fixture 驗證 exit 0、repair diagnostic、原 root keys 保留、managed status line 正確及第二次執行 byte-idempotent。

## 3. 修復 apply 暴露的三個問題

- **Rime/Weasel detection**：抽出 repo 既有 include/core-script 風格的共用 helper，透過 `Microsoft.Win32.RegistryView.Registry64` 與 `Registry32` 查找 `SOFTWARE\Rime\Weasel\InstallDir`，供以下兩處共用，避免 WOW6432Node 安裝被誤判：
  - `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl`
  - `.chezmoiscripts/run_onchange_after_50_rime_deploy.ps1.tmpl`
  保留 `--custom '/T'`、run-script 不終止 apply 等既有 invariant，並補 32/64-bit、缺 executable、未安裝測試。
- **Retry state key**：將 package installer 訊息由 domain-qualified `.chezmoi.username` 改為正規化的 `.chezmoi.homeDir`，補 domain account 渲染測試；只允許刪除精確 entry-state key，不清空整個 bucket。
- **Herdr skill sync**：在 `scripts/herdr-skill-sync.ps1` 區分舊版不支援 `--skill` 與其他錯誤，保留既有 skill copies 並輸出明確 `just upgrade-herdr` 指示；補 fail-closed 測試。維持 apply install-only，不在 apply 中暗中升級。

## 4. 驗證 incoming Pi/external 與 Herdr 升級

- 用 `git ls-remote https://github.com/daviddwlee84/pi-agents.git HEAD` 作為 private external 的實際 access gate；不因獨立的 `gh auth status` 過期警告削弱 external 或改憑證。
- 執行 incoming `tests/PiAgents.Tests.ps1`，確認 external gating、shallow/fast-forward-only 與 explicit `upgrade-pia` 行為。
- 在非 Herdr pane 中執行 repo 的 `just upgrade-herdr`；若 installer hash drift，停止並審核，不繞過 pin。升級後要求 `herdr --skill` 成功。

## 5. 分層驗證與實際 apply

- 依修正逐項跑 focused Pester：CodexConfig、DevCli、PiAgents、Rime、HerdrSkill、HerdrUpgrade、HerdrConfigEdit 及 package-related tests。
- 跑 PSScriptAnalyzer（Error 必須為零）、所有模板 render/parse、完整 Pester（零失敗）及 `just docs-build`（若本次修改牽涉 docs）。
- 執行 `git diff --check -- ':!.specstory/**'`；SpecStory whitespace/churn 不與 runtime 修復混為一談。
- 在 real apply 前檢查 `chezmoi diff` 與 `chezmoi apply --dry-run --verbose`，重驗 private external access，再執行使用者已授權的 `chezmoi apply --init --verbose`。
- 即使 apply exit 0，也將 package summary 的 `N item(s) failed` 視為真失敗逐項處理；未知 warning 不預設為 benign。必要時只刪除已驗證的單一 installer state entry 後重試。

## 6. Post-apply smoke test 與保護狀態

- 新開 `pwsh` 並確認無 startup stderr；驗證 `Get-Command dev,dev-cli`、`dev-cli --version` 與 completion cache。
- 驗證 `herdr --version/--skill`、兩份 skill copy、`pi/pia/omp`、PIA env、private checkout，以及 Weasel executable/deployer。
- 再跑 `chezmoi diff` 和必要的 focused/full tests，區分 runtime-owned drift 與真正未收斂。
- 最後確認 `main` 與 `origin/main` 同步、SpecStory staged/unstaged 狀態仍符合保存紀錄、沒有建立 commit，也沒有改動既有 stashes。
- Safety stash 保留到所有 bytes/index 比對與驗證完成；因其中仍含刻意捨棄的舊 PATH delta，本次不自動 drop，避免不可逆遺失。
