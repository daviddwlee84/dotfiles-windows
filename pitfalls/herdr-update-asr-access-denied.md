# `herdr update` fails with "Access is denied" — Defender ASR ransomware rule blocks the staged preview binary

**Symptoms** (grep this section): `herdr update --handoff` (or `herdr update`) fails; `iex : Program 'herdr.exe' failed to run: Access is denied`; `& $stagedHerdr --version` around line 572 of herdr's `install.ps1`; `ApplicationFailedException`; `NativeCommandFailed,Microsoft.PowerShell.Commands.InvokeExpressionCommand`; `update failed: Windows installer failed with status exit code: 1`. Windows Security toast: `已阻止风险操作` / `管理员已阻止此操作` / `已阻止应用或进程: powershell.exe` / `阻止者: 攻击面减少` / `规则: Use advanced protection against ransomware` / affected item under `...HERDR~1\packages\STANDA~1\releases\STAGIN~1.<n>\herdr.exe`. Second-order symptom after the ASR fix: `Move-Item : The process cannot access the file because it is being used by another process.` / `MoveFileInfoItemIOError`.
**First seen**: 2026-07
**Affects**: `herdr` preview self-update on Windows with Microsoft Defender **Attack Surface Reduction** rule *"Use advanced protection against ransomware"* (`C1DB55AB-C21A-4637-BB3F-A12568109D35`) in **Block** mode. Generic to any freshly-downloaded, low-reputation preview `.exe` — herdr just hits it on every update because Windows builds are preview-only and change constantly.
**Status**: workaround documented — ASR-only path exclusion for the herdr tree.

## Symptom

`herdr update --handoff` downloads the new preview build, then dies when it tries to run the staged binary:

```
==> Downloading Herdr
iex : Program 'herdr.exe' failed to run: Access is denied
At line:572 char:13
+             & $stagedHerdr --version *> $null
At line:1 char:37
+ irm https://herdr.dev/install.ps1 | iex
    + CategoryInfo          : ResourceUnavailable: (:) [Invoke-Expression], ApplicationFailedException
    + FullyQualifiedErrorId : NativeCommandFailed,Microsoft.PowerShell.Commands.InvokeExpressionCommand
update failed: Windows installer failed with status exit code: 1
```

A Windows Security toast fires at the same moment (Blocker: **攻击面减少 / Attack Surface Reduction**, Rule: **Use advanced protection against ransomware**), naming the affected item as the staged `herdr.exe` under `~\.herdr\packages\standalone\releases\staging-*\`.

The *installed* herdr (`%LOCALAPPDATA%\Programs\Herdr\bin\herdr.exe`) runs fine — only the **update's freshly-downloaded** binary is blocked.

## Root cause

ASR rule `C1DB55AB-C21A-4637-BB3F-A12568109D35` ("Use advanced protection against ransomware") blocks executables that fail Defender's **cloud reputation / prevalence** check. It is not path- or signature-based: a binary with near-zero prevalence is treated as potential ransomware and denied execution.

herdr's `--handoff` updater downloads the new build to a staging dir and **runs it to verify** (`& $stagedHerdr --version`, `install.ps1:~572`) before promoting it into `Programs\Herdr\bin`. Because Windows herdr ships **preview** builds that rotate frequently, each new build has essentially no prevalence → ASR blocks that verify step → the update aborts. The already-installed herdr has accrued trust, which is why steady-state `herdr` works but every *update* fails.

Rule-action values from `Get-MpPreference` (`AttackSurfaceReductionRules_Actions`): `0`=Off/Not configured, `1`=**Block**, `2`=Audit, `6`=Warn. On the affected box `C1DB55AB…` = `1`.

The follow-on `Move-Item ... being used by another process` is unrelated to ASR: a running herdr session (or the just-blocked process) still holds a handle on the target file, so the promote/rename step can't move it. It clears on retry once the lock releases.

## Workaround

**1. Confirm ASR exclusions are locally editable** (they may be Intune/policy-locked on corp machines — this box was not; chocolatey paths were already excluded, proving local `Add-MpPreference` sticks):

```powershell
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionOnlyExclusions
```

**2. Exclude the whole herdr tree from ASR, then update** (admin pwsh — `$HOME` expands before the call):

```powershell
Add-MpPreference -AttackSurfaceReductionOnlyExclusions "$HOME\.herdr"
herdr update --handoff
```

- Exclude the **tree** (`~\.herdr`), not the versioned `staging-*` dir — each update stages under a new path, so a per-version exclusion would need re-adding every time.
- `-AttackSurfaceReductionOnlyExclusions` exempts the path from **ASR rules only**; files there are *still* real-time AV-scanned. It is the same mechanism already used for chocolatey here — minimal and targeted, not "turn Defender off".

**3. If it still trips on the promote step** (copy into `Programs\Herdr`), add that path too:

```powershell
Add-MpPreference -AttackSurfaceReductionOnlyExclusions "$HOME\AppData\Local\Programs\Herdr"
```

**4. On `Move-Item ... being used by another process`**: close running herdr sessions and re-run `herdr update --handoff` — it's a transient file lock, not ASR. (In practice a single retry succeeded.)

Verify: `herdr --version` shows the new `…-preview.<date>-<sha>` build.

## Prevention

- Keep the `~\.herdr` ASR-only exclusion in place; it survives all future preview updates, so this only bites once per machine.
- **Do not** confuse this with [`clickfix-defender-flags-cmd-irm-iex`](clickfix-defender-flags-cmd-irm-iex.md), whose advice is the *opposite* ("do NOT add a Defender exclusion / click Allow"). That trap is an **internet download-execute cradle** where clicking Allow is the attack. This is a **locally-installed, repo-trusted tool self-updating to a known path** — a path-scoped ASR-only exclusion is the correct, proportionate fix. The distinction is threat-model, not tooling: exclude *specific trusted paths*, never disable the rule or allow arbitrary cradles.

## Related

- [`clickfix-defender-flags-cmd-irm-iex`](clickfix-defender-flags-cmd-irm-iex.md) — sibling Defender false-positive; deliberately opposite guidance (see Prevention).
- `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` → `Install-Herdr` — the `irm https://herdr.dev/install.ps1 | iex` bootstrap that first installs herdr (preview channel).
- [`backlog/herdr-windows-port-verification.md`](../backlog/herdr-windows-port-verification.md) — herdr Windows port tracking.
- Microsoft, ASR rules reference (rule GUID `c1db55ab-c21a-4637-bb3f-a12568109d35`): <https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-rules-reference>
