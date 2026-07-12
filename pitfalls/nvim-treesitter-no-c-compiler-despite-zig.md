# nvim-treesitter: "No C compiler found" even though zig is installed

**Symptoms** (grep this section): `:checkhealth nvim-treesitter` shows
`C compiler ❌` / `No C compiler found`; parser install fails while `curl`,
`tar`, and the `tree-sitter` CLI all report OK; the hint reads
`Install a C compiler with winget install --id=BrechtSanders.WinLabs.POSIX.UCRT -e`.
`zig` is on PATH but treesitter still won't compile parsers.
**First seen**: 2026-07
**Affects**: nvim-treesitter **`main`** branch (LazyVim default) on Windows;
tree-sitter CLI ≥ 0.25; any host where only `zig` is installed as the "compiler".
**Status**: fixed — baseline installer now ships `gcc` on all arches (dropped `zig`).

## Symptom

`:checkhealth nvim-treesitter` (or a parser build triggered by LazyVim / `:TSInstall`)
reports the C compiler missing while everything else is present:

```
nvim-treesitter: require("nvim-treesitter.health").check()
- OK tree-sitter-cli 0.26.x (found)
- OK curl found
- OK tar found
- ERROR No C compiler found
  Install a C compiler with `winget install --id=BrechtSanders.WinLabs.POSIX.UCRT -e`
```

The trap: `scoop install zig` succeeded, `zig` is on PATH, yet treesitter
insists there is no C compiler.

## Root cause

nvim-treesitter's `master` branch is **retired/locked** (kept only for
backward-compat with older Neovim); LazyVim now pins the **`main`** branch,
which is a full, incompatible rewrite. The two branches find a compiler very
differently:

- **`master`** compiled parsers itself using an internal compiler list that
  **included `zig`** (with `zig cc` special-casing). Installing `zig` worked.
- **`main`** does **not** compile parsers itself and has **no compiler list**.
  It shells out to the external CLI — `tree-sitter build -o parser.so`
  (`lua/nvim-treesitter/install.lua`). `tree-sitter build` compiles via Rust's
  **`cc` crate**, whose Windows toolchains are **MSVC (`cl`) / GCC / Clang only**
  — it has **no concept of `zig`**. The README requirements say exactly this:
  "a C compiler in your path (see <https://docs.rs/cc/latest/cc/#compile-time-requirements>)".

So on `main`, `zig` is inert for treesitter. With only `zig` installed the
`cc` crate finds nothing it recognizes → "No C compiler found". This bites x64
hosts hardest: the installer historically shipped `zig` for everyone but a real
`gcc` **only on ARM64**, so a plain x64 box had no cc-crate-compatible compiler.

## Workaround

Install a real MinGW-w64 GCC (or MSVC/Clang) so `gcc`/`cc` is on PATH:

```powershell
scoop install gcc                                   # nuwen MinGW-w64 (repo default)
# leaner alternative (niXman MinGW-w64 UCRT):
scoop install mingw
# or exactly what the tool suggests (winlibs UCRT):
winget install --id=BrechtSanders.WinLabs.POSIX.UCRT -e
```

Then re-open Neovim and re-run `:checkhealth nvim-treesitter` /
`:TSInstall <lang>`. `gcc` must be amd64 to match the (amd64 / x64-emulated on
ARM64) scoop `neovim`.

## Prevention

Fixed in-repo: `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` now
lists **`gcc`** in the always-installed core scoop set (replacing `zig`) instead
of adding it only inside the ARM64 branch. One line covers x64 and ARM64 because
scoop's `gcc` is amd64-only. Don't reintroduce `zig` as "the treesitter
compiler" — it only ever worked on the retired `master` branch.

## Related

- Installer: `.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl` (core scoop set)
- Docs: `docs/tools.md` / `docs/tools.zh-TW.md` (gcc row)
- Backlog: [`backlog/windows-arm64-managed-machine-rough-edges.md`](../backlog/windows-arm64-managed-machine-rough-edges.md) (point 1, now resolved)
- Upstream: nvim-treesitter `main` requirements — <https://github.com/nvim-treesitter/nvim-treesitter#requirements>
- Rust `cc` crate compile-time requirements — <https://docs.rs/cc/latest/cc/#compile-time-requirements>
