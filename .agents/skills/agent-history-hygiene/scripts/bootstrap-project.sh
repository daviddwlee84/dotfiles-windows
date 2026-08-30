#!/usr/bin/env bash
# bootstrap-project.sh — wire pre-commit + gitleaks + the redact-agent-
# secrets hook into a new project so agent chat/plan files can be
# committed safely.
#
# Bash 3.2 compatible (stock macOS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$SKILL_DIR/assets"

CHEZMOI_SRC="${CHEZMOI_SOURCE_DIR:-$HOME/.local/share/chezmoi}"

# The redactor now ships as a PINNED REMOTE pre-commit hook (not a vendored
# copy), so fixes propagate via `pre-commit autoupdate`. Keep these in lockstep
# with assets/pre-commit-config.yaml.template and the repo's .pre-commit-hooks.yaml.
HOOK_REPO_URL="https://github.com/daviddwlee84/agent-skills"
HOOK_REV="ahh-v1.1.0"

usage() {
  cat <<'EOF'
Usage: bootstrap-project.sh [OPTIONS]

Install agent-history-hygiene's pre-commit stack into the current repo:
  .pre-commit-config.yaml   redact-agent-secrets (pinned remote hook) +
                            gitleaks-system + standard hygiene
  .gitleaks.toml            (portable subset; real leaks still fire)
  .specstory/.gitignore     ignores only machine-local project identity +
                            generated statistics; keeps history committable
  .git/hooks/pre-commit     (via `pre-commit install`)

The redactor is NOT vendored -- it's a pinned pre-commit hook from the
agent-skills repo, so `pre-commit autoupdate` keeps every repo current.

Options:
  --from-chezmoi      Symlink .pre-commit-config.yaml + .gitleaks.toml from your
                      chezmoi source ($HOME/.local/share/chezmoi) so updates
                      propagate. Fails if chezmoi source is missing.
  --migrate           Convert a repo from the OLD vendored layout: remove
                      scripts/redact_secrets.py and rewrite the local
                      redact-agent-secrets hook into the pinned remote hook.
                      Leaves other hooks + .gitleaks.toml untouched.
  --install-hook      Install a validation-only prepare-commit-msg hook. Explicit
                      AGENT_HISTORY_* identity/plan must already have staged diffs
                      in the commit index; the hook never mutates any index.
                      Missing identity remains a visible no-op.
  --untrack-specstory-state
                      Stop tracking .specstory/.project.json and
                      .specstory/statistics.json after adding precise ignore
                      rules. Files remain on disk; stages their Git removals.
  --force             Overwrite existing files instead of skipping.
  --dry-run           Print what would happen without making changes.
  --help, -h          Show this help and exit.

Exit codes:
  0  success
  1  invalid arguments
  2  not inside a git repo
  3  chezmoi source missing (and --from-chezmoi was requested)
  4  pre-commit tool unavailable and `uvx` fallback failed
  5  --migrate could not find the old hook to rewrite (manual edit needed)
  6  --install-hook requested while core.hooksPath redirects repo hooks
EOF
}

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit "${2:-1}"; }

FROM_CHEZMOI=0
INSTALL_HOOK=0
FORCE=0
DRY_RUN=0
MIGRATE=0
UNTRACK_SPECSTORY_STATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from-chezmoi)  FROM_CHEZMOI=1; shift ;;
    --migrate)       MIGRATE=1; shift ;;
    --install-hook)  INSTALL_HOOK=1; shift ;;
    --untrack-specstory-state) UNTRACK_SPECSTORY_STATE=1; shift ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --help|-h)       usage; exit 0 ;;
    -*)              die "unknown flag: $1 (try --help)" 1 ;;
    *)               die "unexpected positional arg: $1 (try --help)" 1 ;;
  esac
done

# Must be inside a git repo (or the pre-commit install step fails anyway).
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  die "not inside a git repo" 2
fi
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Track key presence separately from its value. Even `.git/hooks` is unsafe in
# linked worktrees because `.git` is a file there, so automatic repo-hook install
# is supported only when core.hooksPath is genuinely unset.
configured_hooks_path=""
HOOKS_PATH_CONFIGURED=0
if configured_hooks_path="$(git config --get core.hooksPath 2>/dev/null)"; then
  HOOKS_PATH_CONFIGURED=1
fi
HOOKS_REDIRECTED="$HOOKS_PATH_CONFIGURED"
HOOKS_PATH_INVALID=0
[ "$HOOKS_PATH_CONFIGURED" = "1" ] && [ -z "$configured_hooks_path" ] && HOOKS_PATH_INVALID=1

# Fail before writing bootstrap files so --install-hook cannot report success for
# a path that is root-relative, external, or non-traversable in a linked worktree.
if [ "$INSTALL_HOOK" = "1" ] && [ "$HOOKS_PATH_INVALID" = "1" ]; then
  die "--install-hook cannot use an explicitly empty core.hooksPath; unset the key first" 6
fi
if [ "$INSTALL_HOOK" = "1" ] && [ "$HOOKS_PATH_CONFIGURED" = "1" ]; then
  die "--install-hook requires core.hooksPath to be genuinely unset. Integrate the validation-only hook into the configured directory yourself, or unset the key." 6
fi

if [ "$FROM_CHEZMOI" = "1" ] && [ ! -d "$CHEZMOI_SRC" ]; then
  die "chezmoi source not found at $CHEZMOI_SRC (skip --from-chezmoi to use bundled copies)" 3
fi

dryrun_say() {
  [ "$DRY_RUN" = "1" ] && log "[dry-run] $*"
}

# install_file <dest> <src_copy> <src_chezmoi>
install_file() {
  local dest="$1" src_copy="$2" src_chezmoi="$3"
  local src
  if [ "$FROM_CHEZMOI" = "1" ]; then
    src="$src_chezmoi"
    [ -e "$src" ] || die "missing upstream file: $src" 3
  else
    src="$src_copy"
    [ -e "$src" ] || die "missing bundled asset: $src" 1
  fi

  if [ -e "$dest" ] && [ "$FORCE" != "1" ]; then
    log "skip: $dest already exists (use --force to overwrite)"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"

  if [ "$DRY_RUN" = "1" ]; then
    if [ "$FROM_CHEZMOI" = "1" ]; then
      log "[dry-run] ln -sf $src -> $dest"
    else
      log "[dry-run] cp $src -> $dest"
    fi
    return 0
  fi

  if [ "$FROM_CHEZMOI" = "1" ]; then
    ln -sf "$src" "$dest"
    log "linked: $dest -> $src"
  else
    cp "$src" "$dest"
    log "wrote: $dest"
  fi
}

# migrate_config: convert an OLD vendored layout to the pinned remote hook.
# Removes scripts/redact_secrets.py and rewrites the `- repo: local` block whose
# hook id is redact-agent-secrets into the pinned remote hook. Idempotent.
migrate_config() {
  local cfg=".pre-commit-config.yaml"
  # 1) Drop the vendored redactor.
  if [ -e "scripts/redact_secrets.py" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] remove vendored scripts/redact_secrets.py"
    elif git ls-files --error-unmatch "scripts/redact_secrets.py" >/dev/null 2>&1; then
      git rm -q -f "scripts/redact_secrets.py"; log "removed (git): scripts/redact_secrets.py"
    else
      rm -f "scripts/redact_secrets.py"; log "removed: scripts/redact_secrets.py"
    fi
  fi
  # 2) Rewrite the local redact hook -> pinned remote hook.
  [ -f "$cfg" ] || die "no $cfg to migrate (run without --migrate to create one)" 5
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] rewrite local redact-agent-secrets hook in $cfg -> $HOOK_REPO_URL@$HOOK_REV"
    return 0
  fi
  local rc=0
  HOOK_REPO_URL="$HOOK_REPO_URL" HOOK_REV="$HOOK_REV" python3 - "$cfg" <<'PY' || rc=$?
import os, re, sys

cfg = sys.argv[1]
url, rev = os.environ["HOOK_REPO_URL"], os.environ["HOOK_REV"]
lines = open(cfg, encoding="utf-8").read().splitlines(keepends=True)

remote_block = (
    f"  - repo: {url}\n"
    f"    rev: {rev}\n"
    "    hooks:\n"
    "      - id: redact-agent-secrets\n"
)

def is_top_item(l):  # a `  - repo:` list entry
    return re.match(r"^  - repo:", l) is not None

# Idempotent: already points at the pinned hook.
if any(re.match(r"^  - repo:.*agent-skills", l) for l in lines):
    print("already references the pinned hook; nothing to rewrite", file=sys.stderr)
    sys.exit(0)

start = None
for i, l in enumerate(lines):
    if re.match(r"^  - repo:\s*local\b", l):
        j = i + 1
        while j < len(lines) and not is_top_item(lines[j]):
            j += 1
        body = "".join(lines[i:j])
        if "redact-agent-secrets" in body or "redact_secrets.py" in body:
            start, end = i, j
            break

if start is None:
    sys.exit(5)  # no local redact hook found -> caller prints manual instructions

# Don't swallow the blank line / comments that head the NEXT block.
while end - 1 > start and (lines[end - 1].strip() == "" or lines[end - 1].lstrip().startswith("#")):
    end -= 1

open(cfg, "w", encoding="utf-8").write("".join(lines[:start] + [remote_block] + lines[end:]))
print(f"rewrote {cfg}: local redact hook -> {url}@{rev}", file=sys.stderr)
PY
  if [ "$rc" = "5" ]; then
    warn "could not find a local redact-agent-secrets hook in $cfg."
    warn "  Add this under 'repos:' by hand, then re-run:"
    warn "    - repo: $HOOK_REPO_URL"
    warn "      rev: $HOOK_REV"
    warn "      hooks:"
    warn "        - id: redact-agent-secrets"
    exit 5
  fi
  [ "$rc" = "0" ] || die "migration rewrite failed (python exit $rc)" "$rc"
}

if [ "$MIGRATE" = "1" ]; then
  migrate_config
else
  # 1. .pre-commit-config.yaml (redact hook is a pinned remote hook, not vendored)
  install_file ".pre-commit-config.yaml" \
    "$ASSETS_DIR/pre-commit-config.yaml.template" \
    "$CHEZMOI_SRC/.pre-commit-config.yaml"

  # 2. .gitleaks.toml
  install_file ".gitleaks.toml" \
    "$ASSETS_DIR/gitleaks.toml.template" \
    "$CHEZMOI_SRC/.gitleaks.toml"
fi

# 3. Keep SpecStory's machine-local state out of Git without hiding the
#    review-bearing .specstory/history/*.md files. Merge exact, nested rules
#    instead of ignoring the whole .specstory directory. Idempotent.
append_specstory_ignore_rule() {
  local file="$1" pattern="$2" comment="$3"
  if [ -f "$file" ] && grep -Fqx "$pattern" "$file"; then
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] add '$pattern' to $file"
    return 0
  fi

  mkdir -p "$(dirname "$file")"
  if [ -s "$file" ]; then
    # Preserve hand-written content, including a file missing its final newline.
    if [ "$(tail -c 1 "$file" | wc -l | tr -d '[:space:]')" = "0" ]; then
      printf '\n' >> "$file"
    fi
    printf '\n' >> "$file"
  fi
  printf '%s\n%s\n' "$comment" "$pattern" >> "$file"
  log "updated: $file (added $pattern)"
}

ensure_specstory_gitignore() {
  local file=".specstory/.gitignore"
  append_specstory_ignore_rule "$file" "/.project.json" \
    "# SpecStory machine-local project identity"
  append_specstory_ignore_rule "$file" "/statistics.json" \
    "# SpecStory generated session statistics"
}

handle_tracked_specstory_state() {
  local path
  local tracked=()
  for path in .specstory/.project.json .specstory/statistics.json; do
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      tracked+=("$path")
    fi
  done
  [ "${#tracked[@]}" -gt 0 ] || return 0

  if [ "$UNTRACK_SPECSTORY_STATE" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "[dry-run] git rm --cached -- ${tracked[*]}"
    else
      git rm --cached -- "${tracked[@]}" >/dev/null
      log "untracked SpecStory machine state (files remain on disk): ${tracked[*]}"
    fi
    return 0
  fi

  warn "SpecStory machine state is already tracked, so .gitignore cannot hide it:"
  for path in "${tracked[@]}"; do
    warn "  $path"
  done
  warn "  Re-run with --untrack-specstory-state to keep the files locally and stage their Git removals."
}

ensure_specstory_gitignore
handle_tracked_specstory_state

# 4. `pre-commit install`. Prefer a local `pre-commit` binary; fall back to
#    `uvx pre-commit@4` so users without a manual install still get hooks.
#    Skipped if `core.hooksPath` is set globally (chezmoi pattern) — the
#    global hook wrapper already runs `.pre-commit-config.yaml` for us.
install_hooks() {
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] pre-commit install (or skip if core.hooksPath set)"
    return 0
  fi

  # A genuinely redirected core.hooksPath is expected to provide its own global
  # wrapper. A configured value resolving to the default hooks directory is not
  # a redirect and should receive the normal pre-commit install.
  if [ "$HOOKS_REDIRECTED" = "1" ]; then
    log "core.hooksPath is redirected to '$configured_hooks_path' — skipping \`pre-commit install\`."
    log "  Your global hook wrapper should run the repo's .pre-commit-config.yaml automatically."
    log "  To use per-repo hooks instead, run: git config --unset core.hooksPath"
    return 0
  fi

  if command -v pre-commit >/dev/null 2>&1; then
    pre-commit install || return $?
    return 0
  fi
  if command -v uvx >/dev/null 2>&1; then
    log "pre-commit not found — using uvx fallback"
    uvx pre-commit@4 install || return $?
    return 0
  fi
  warn "neither pre-commit nor uvx available; install pre-commit manually"
  warn "  macOS: brew install pre-commit"
  warn "  or:    pipx install pre-commit"
  return 4
}
install_hooks || rc=$?
if [ "${rc:-0}" != "0" ]; then
  exit "$rc"
fi

# 5. Optional validation-only prepare-commit-msg hook. It never mutates an
#    index: explicit selectors are checked against the commit's current
#    GIT_INDEX_FILE, including Git's temporary -a/--only indexes.
if [ "$INSTALL_HOOK" = "1" ]; then
  hook_path="$(git rev-parse --git-path hooks/prepare-commit-msg)"
  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] write $hook_path + chmod +x (explicit AGENT_HISTORY_* selectors only)"
  else
    if [ -e "$hook_path" ] && [ "$FORCE" != "1" ]; then
      warn "$hook_path already exists (use --force to overwrite)"
    else
      mkdir -p "$(dirname "$hook_path")"
      printf -v stage_script_quoted '%q' "$SCRIPT_DIR/stage-agent-artifacts.sh"
      {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '# Installed by agent-history-hygiene bootstrap-project.sh --install-hook.'
        printf '%s\n' '# Validation-only: AGENT_HISTORY_* identity and plan policy must already be staged.'
        printf '%s\n' 'set -eu'
        printf 'stage_script=%s\n' "$stage_script_quoted"
        cat <<'HOOK'

if [ -z "${AGENT_HISTORY_SESSION_ID:-}" ] && [ -z "${AGENT_HISTORY_SPECSTORY_PATH:-}" ]; then
  printf '%s\n' 'agent-history: no AGENT_HISTORY_SESSION_ID or AGENT_HISTORY_SPECSTORY_PATH; skipping staged-artifact validation.' >&2
  exit 0
fi

args=(--session-only)
[ -z "${AGENT_HISTORY_SESSION_ID:-}" ] || args+=(--session-id "$AGENT_HISTORY_SESSION_ID")
[ -z "${AGENT_HISTORY_SPECSTORY_PATH:-}" ] || args+=(--specstory-path "$AGENT_HISTORY_SPECSTORY_PATH")

case "${AGENT_HISTORY_NO_SPECSTORY:-}" in
  "") ;;
  1) args+=(--no-specstory) ;;
  *) printf '%s\n' 'agent-history: AGENT_HISTORY_NO_SPECSTORY must be 1 or unset.' >&2; exit 1 ;;
esac

[ -z "${AGENT_HISTORY_PLAN:-}" ] || args+=(--plan "$AGENT_HISTORY_PLAN")
case "${AGENT_HISTORY_NO_PLAN:-}" in
  "") ;;
  1) args+=(--no-plan) ;;
  *) printf '%s\n' 'agent-history: AGENT_HISTORY_NO_PLAN must be 1 or unset.' >&2; exit 1 ;;
esac

if bash "$stage_script" "${args[@]}" --check-staged; then
  exit 0
else
  verify_rc=$?
fi

printf '%s\n' \
  'agent-history: commit index is missing exact artifacts or staged feature code.' \
  'agent-history: stage feature paths, then run this exact staging command:' >&2
printf '  bash %q' "$stage_script" >&2
for arg in "${args[@]}"; do printf ' %q' "$arg" >&2; done
printf '%s\n' '' \
  'agent-history: retry with a normal git commit; -a/--only may exclude artifacts.' >&2
exit "$verify_rc"
HOOK
      } > "$hook_path"
      chmod +x "$hook_path"
      log "installed: $hook_path (validation-only exact gate; visible no-op without identity)"
    fi
  fi
fi

# 6. Audit .gitignore / .git/info/exclude — warn if any artifact dir is
#    silently hidden so pre-commit won't actually see those files.
audit_ignore() {
  local dirs_file="$ASSETS_DIR/artifact-dirs.txt"
  [ -f "$dirs_file" ] || return 0
  local dir
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    dir="$line"
    # check-ignore returns 0 when the path matches an ignore rule.
    if git check-ignore -q "$dir" 2>/dev/null; then
      warn "$dir is gitignored — staged files under it won't be committed"
      warn "  Check .gitignore and .git/info/exclude for a matching rule."
    fi
  done < "$dirs_file"
}
audit_ignore

# 7. Verify ~/.claude/settings.json has plansDirectory set. Don't silently
#    edit — print the patch for the user.
check_plans_directory() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || {
    log ""
    log "note: ~/.claude/settings.json not found. To keep Claude Code plan"
    log "      files inside each project, create it with:"
    log ""
    log '      { "plansDirectory": "./.claude/plans" }'
    log ""
    return 0
  }
  if grep -q '"plansDirectory"' "$settings"; then
    return 0
  fi
  log ""
  log "note: ~/.claude/settings.json exists but does NOT set plansDirectory."
  log '      Add:  "plansDirectory": "./.claude/plans"'
  log "      so Claude Code writes plan files inside each project (committable"
  log "      with the feature diff)."
  log ""
}
check_plans_directory

log ""
log "Bootstrap complete. Recommended next steps:"
log "  1. Review .pre-commit-config.yaml + .gitleaks.toml for project-specific tweaks."
log "  2. pre-commit run --all-files      # shake out any existing issues"
log "  3. Have the agent commit code + chat together; scan with:"
log "     bash $SCRIPT_DIR/scan-staged.sh"
