#!/usr/bin/env bash
# stage-agent-artifacts.sh — git-add validated agent artifacts before a commit.
#
# Exact session-only mode is fail-closed. The default broad mode preserves the
# historical branch-wide behavior for callers that intentionally want it.
# Bash 3.2 compatible (stock macOS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_DIRS_FILE="$SKILL_DIR/assets/artifact-dirs.txt"

usage() {
  cat <<'EOF'
Usage: stage-agent-artifacts.sh [OPTIONS]

Stage agent artifacts for the next commit. Must run inside a git repository.
The default is broad branch-wide compatibility mode: every dirty Markdown file
under the configured artifact directories. Use --session-only for exact mode.

Exact session-only options:
  --session-only          Select only one exact transcript plus an explicit plan.
  --check-staged          Validation-only: require selected artifacts and staged
                          non-artifact code in the current GIT_INDEX_FILE. Never
                          mutate an index. Requires --session-only.
  --session-id UUID       Exact Claude Code session UUID.
  --specstory-path PATH   Exact .specstory/history/*.md path (relative paths are
                          resolved from the git root). May accompany UUID.
  --no-specstory          Intentionally omit rendered SpecStory history. Requires
                          --session-id so the raw Claude JSONL can still be proved.
  --plan PATH             Stage this exact in-repo Markdown plan.
  --no-plan               Explicitly state that this session has no plan.

Broad-mode options:
  --include-all-plans     Re-add already-staged modified artifact files instead
                          of considering only unstaged/untracked files.
  --dirs-file PATH        Override artifact-dirs.txt.

Common options:
  --dry-run               Validate and print one proposed git-add set, but do not
                          change the index.
  --allow-empty           Allow artifact-only staging when there are no code
                          changes (default refuses accidental transcript-only work).
  --help, -h              Show this help and exit.

Exit codes:
  0  staging success, or --check-staged verification success
  1  invalid arguments
  2  not inside a git repository
  3  no code changes and no dirty artifacts
  4  artifacts are dirty but code is clean (use --allow-empty)
  5  exact selector/path validation failed; index is unchanged
EOF
}

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
has_control_bytes() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;; esac
  LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}
is_valid_utf8() {
  command -v iconv >/dev/null 2>&1 || return 1
  printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

SESSION_ONLY=0
CHECK_STAGED=0
INCLUDE_ALL_PLANS=0
DIRS_FILE="$DEFAULT_DIRS_FILE"
DRY_RUN=0
ALLOW_EMPTY=0
SESSION_ID=""
SESSION_ID_SET=0
SPECSTORY_INPUT=""
SPECSTORY_PATH_SET=0
NO_SPECSTORY=0
PLAN_INPUT=""
PLAN_SET=0
NO_PLAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session-only) SESSION_ONLY=1; shift ;;
    --check-staged) CHECK_STAGED=1; shift ;;
    --session-id)
      shift
      [ $# -gt 0 ] && [ -n "$1" ] || die "--session-id needs a non-empty UUID (value not shown)" 1
      SESSION_ID_SET=1; SESSION_ID="$1"; shift ;;
    --session-id=*)
      SESSION_ID_SET=1; SESSION_ID="${1#--session-id=}"
      [ -n "$SESSION_ID" ] || die "--session-id cannot be empty" 1
      shift ;;
    --specstory-path)
      shift
      [ $# -gt 0 ] && [ -n "$1" ] || die "--specstory-path needs a non-empty path (value not shown)" 1
      SPECSTORY_PATH_SET=1; SPECSTORY_INPUT="$1"; shift ;;
    --specstory-path=*)
      SPECSTORY_PATH_SET=1; SPECSTORY_INPUT="${1#--specstory-path=}"
      [ -n "$SPECSTORY_INPUT" ] || die "--specstory-path cannot be empty" 1
      shift ;;
    --no-specstory) NO_SPECSTORY=1; shift ;;
    --plan)
      shift
      [ $# -gt 0 ] && [ -n "$1" ] || die "--plan needs a non-empty path (value not shown)" 1
      PLAN_SET=1; PLAN_INPUT="$1"; shift ;;
    --plan=*)
      PLAN_SET=1; PLAN_INPUT="${1#--plan=}"
      [ -n "$PLAN_INPUT" ] || die "--plan cannot be empty" 1
      shift ;;
    --no-plan) NO_PLAN=1; shift ;;
    --include-all-plans) INCLUDE_ALL_PLANS=1; shift ;;
    --dirs-file)
      shift
      [ $# -gt 0 ] && [ -n "$1" ] || die "--dirs-file needs a non-empty path (value not shown)" 1
      DIRS_FILE="$1"; shift ;;
    --dirs-file=*)
      DIRS_FILE="${1#--dirs-file=}"
      [ -n "$DIRS_FILE" ] || die "--dirs-file cannot be empty" 1
      shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-empty) ALLOW_EMPTY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    -*) die "unknown flag: $1 (try --help)" 1 ;;
    *)  die "unexpected positional arg: $1 (try --help)" 1 ;;
  esac
done

command -v iconv >/dev/null 2>&1 || die "iconv is required for safe artifact path handling" 1
if [ "$SESSION_ID_SET" = "1" ] && \
   { has_control_bytes "$SESSION_ID" || ! is_valid_utf8 "$SESSION_ID"; }; then
  die "--session-id is not safe UTF-8 text (value not shown)" 1
fi
if [ "$SPECSTORY_PATH_SET" = "1" ] && \
   { has_control_bytes "$SPECSTORY_INPUT" || ! is_valid_utf8 "$SPECSTORY_INPUT"; }; then
  die "--specstory-path is not safe UTF-8 text (value not shown)" 1
fi
if [ "$PLAN_SET" = "1" ] && \
   { has_control_bytes "$PLAN_INPUT" || ! is_valid_utf8 "$PLAN_INPUT"; }; then
  die "--plan is not safe UTF-8 text (value not shown)" 1
fi
if has_control_bytes "$DIRS_FILE" || ! is_valid_utf8 "$DIRS_FILE"; then
  die "--dirs-file is not safe UTF-8 text (value not shown)" 1
fi

if [ "$CHECK_STAGED" = "1" ]; then
  [ "$SESSION_ONLY" = "1" ] || die "--check-staged requires --session-only" 1
  [ "$DRY_RUN" = "0" ] || die "--check-staged cannot be combined with --dry-run" 1
  [ "$ALLOW_EMPTY" = "0" ] || die "--check-staged cannot be combined with --allow-empty" 1
  [ "$INCLUDE_ALL_PLANS" = "0" ] || die "--check-staged cannot be combined with --include-all-plans" 1
fi

if [ "$SESSION_ONLY" = "0" ]; then
  if [ "$SESSION_ID_SET" = "1" ] || [ "$SPECSTORY_PATH_SET" = "1" ] || [ "$NO_SPECSTORY" = "1" ] || \
     [ "$PLAN_SET" = "1" ] || [ "$NO_PLAN" = "1" ]; then
    die "exact selectors require --session-only (omit them to use broad branch-wide mode)" 1
  fi
else
  [ "$INCLUDE_ALL_PLANS" = "0" ] || die "--include-all-plans applies only to broad mode" 1
  if [ "$PLAN_SET" = "1" ] && [ "$NO_PLAN" = "1" ]; then
    die "choose exactly one of --plan PATH or --no-plan" 1
  fi
  if [ "$PLAN_SET" = "0" ] && [ "$NO_PLAN" = "0" ]; then
    die "--session-only requires an explicit --plan PATH or --no-plan decision" 1
  fi
  if [ "$NO_SPECSTORY" = "1" ] && [ "$SPECSTORY_PATH_SET" = "1" ]; then
    die "--no-specstory cannot be combined with --specstory-path" 1
  fi
  if [ "$NO_SPECSTORY" = "1" ] && [ "$SESSION_ID_SET" = "0" ]; then
    die "--no-specstory requires --session-id so exact raw-session identity can be validated" 1
  fi
  if [ "$NO_SPECSTORY" = "0" ] && [ "$SESSION_ID_SET" = "0" ] && [ "$SPECSTORY_PATH_SET" = "0" ]; then
    die "--session-only requires --session-id or --specstory-path (or --session-id with --no-specstory)" 1
  fi
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  die "not inside a git repository" 2
fi
REPO_ROOT="$(git rev-parse --show-toplevel)"
INVOCATION_DIR="$PWD"
cd "$REPO_ROOT"

# Preserve a caller-supplied dirs file relative to the invocation directory.
case "$DIRS_FILE" in
  /*) ;;
  *) DIRS_FILE="$INVOCATION_DIR/$DIRS_FILE" ;;
esac
[ -f "$DIRS_FILE" ] || die "artifact-dirs.txt was not found (path not shown)" 1

ARTIFACT_DIRS=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  while [ "${line%/}" != "$line" ]; do line="${line%/}"; done
  [ -n "$line" ] && ARTIFACT_DIRS+=("$line")
done < "$DIRS_FILE"

canonical_existing_file() {
  local input="$1" absolute parent base
  case "$input" in
    /*) absolute="$input" ;;
    *)  absolute="$REPO_ROOT/$input" ;;
  esac
  [ ! -L "$absolute" ] || return 2
  [ -f "$absolute" ] || return 1
  parent="$(cd "$(dirname "$absolute")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$absolute")"
  printf '%s/%s' "$parent" "$base"
}

repo_relative_path() {
  local absolute="$1"
  case "$absolute" in
    "$REPO_ROOT"/*) printf '%s' "${absolute#"$REPO_ROOT"/}" ;;
    *) return 1 ;;
  esac
}

is_configured_artifact_path() {
  local path="$1" dir
  for dir in "${ARTIFACT_DIRS[@]}"; do
    case "$path" in "$dir"/*) return 0 ;; esac
  done
  return 1
}

is_exact_plan_path() {
  local path="$1"
  is_configured_artifact_path "$path" || return 1
  # The transcript namespace can be configured for broad collection but cannot
  # be mislabeled as an exact plan.
  case "$path" in .specstory/history/*) return 1 ;; esac
  return 0
}

validate_candidate_path() {
  local path="$1"
  if has_control_bytes "$path"; then
    die "artifact path contains unsupported control bytes (value not shown)" 5
  fi
  case "$path" in
    /*|../*|*/../*|*/..|.|..) die "artifact path is not a safe repo-relative path (value not shown)" 5 ;;
    *.md) ;;
    *) die "artifact path must be Markdown (value not shown)" 5 ;;
  esac
  is_configured_artifact_path "$path" || die "artifact path is outside configured directories (value not shown)" 5
  if [ -e "$path" ]; then
    [ -f "$path" ] || die "artifact path is not a regular file (value not shown)" 5
    [ ! -L "$path" ] || die "artifact path must not be a symlink (value not shown)" 5
  elif ! GIT_LITERAL_PATHSPECS=1 git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    die "artifact path does not exist and is not tracked (value not shown)" 5
  fi
}

append_unique_candidate() {
  local path="$1" existing
  for existing in "${CANDIDATES[@]:-}"; do
    [ "$existing" = "$path" ] && return 0
  done
  CANDIDATES+=("$path")
}

status_needs_add() {
  local status="$1" index_status worktree_status
  [ "$status" = "??" ] && return 0
  index_status="${status:0:1}"
  worktree_status="${status:1:1}"
  [ "$worktree_status" != " " ] && return 0
  [ "$INCLUDE_ALL_PLANS" = "1" ] && [ "$index_status" != " " ] && return 0
  return 1
}

# One porcelain snapshot for every configured directory. Rename/copy origins are
# consumed as part of their preceding XY record and are never reclassified as a
# standalone path.
collect_broad_artifacts() {
  local entry status destination origin=""
  while IFS= read -r -d '' entry; do
    [ "${#entry}" -ge 3 ] || die "malformed git status record while collecting artifacts" 5
    status="${entry:0:2}"
    destination="${entry:3}"
    origin=""
    case "$status" in
      DD|AU|UD|UA|DU|AA|UU)
        case "$destination" in
          *.md) is_configured_artifact_path "$destination" && \
            die "unmerged artifact conflicts must be resolved explicitly; index unchanged" 5 ;;
        esac
        continue ;;
    esac
    case "$status" in
      *R*|*C*)
        IFS= read -r -d '' origin || die "incomplete rename/copy record from git status" 5 ;;
    esac
    status_needs_add "$status" || continue
    case "$destination" in
      *.md) is_configured_artifact_path "$destination" && append_unique_candidate "$destination" ;;
    esac
    if [ "${status:1:1}" = "R" ]; then
      case "$origin" in
        *.md) is_configured_artifact_path "$origin" && append_unique_candidate "$origin" ;;
      esac
    fi
  done < <(git -c core.quotePath=false status --porcelain=v1 -z -uall 2>/dev/null)
}

# The feature-diff guard is about what the next commit will contain, not merely
# dirty working-tree files. Parse staged rename/copy records as paired records.
has_staged_code_changes() {
  local status path origin destination
  while IFS= read -r -d '' status; do
    case "$status" in
      U*)
        IFS= read -r -d '' path || return 1
        continue ;;
      R*)
        IFS= read -r -d '' origin || return 1
        IFS= read -r -d '' destination || return 1
        if ! is_configured_artifact_path "$origin" || ! is_configured_artifact_path "$destination"; then return 0; fi ;;
      C*)
        IFS= read -r -d '' origin || return 1
        IFS= read -r -d '' destination || return 1
        # A copy changes only the destination; its origin is context, not a
        # separately staged code path.
        is_configured_artifact_path "$destination" || return 0 ;;
      *)
        IFS= read -r -d '' path || return 1
        is_configured_artifact_path "$path" || return 0 ;;
    esac
  done < <(git -c core.quotePath=false diff --cached --name-status -z --find-renames --find-copies --)
  return 1
}

INDEX_TRANSACTION_ACTIVE=0
INDEX_PATH=""
INDEX_LOCK_PATH=""
TEMP_INDEX_PATH=""

cleanup_index_transaction() {
  if [ "$INDEX_TRANSACTION_ACTIVE" = "1" ]; then
    [ -z "$TEMP_INDEX_PATH" ] || rm -f "$TEMP_INDEX_PATH"
    [ -z "$INDEX_LOCK_PATH" ] || rm -f "$INDEX_LOCK_PATH"
    INDEX_TRANSACTION_ACTIVE=0
  fi
}
trap 'cleanup_index_transaction' EXIT
trap 'exit 130' HUP INT TERM

absolute_git_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$REPO_ROOT" "$1" ;;
  esac
}

begin_index_transaction() {
  local raw_index seed_temp
  raw_index="$(git rev-parse --git-path index)"
  INDEX_PATH="$(absolute_git_path "$raw_index")"
  INDEX_LOCK_PATH="$INDEX_PATH.lock"

  if ! (set -o noclobber; : > "$INDEX_LOCK_PATH") 2>/dev/null; then
    die "git index is already locked; retry after the other index writer finishes" 5
  fi
  INDEX_TRANSACTION_ACTIVE=1

  TEMP_INDEX_PATH="$(mktemp "$INDEX_PATH.agent-history.XXXXXX")" || \
    die "could not create alternate index beside the real index" 5
  if [ -f "$INDEX_PATH" ]; then
    cp -p "$INDEX_PATH" "$TEMP_INDEX_PATH" || die "could not copy the current index" 5
  else
    rm -f "$TEMP_INDEX_PATH"
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
      seed_temp="$TEMP_INDEX_PATH"
      GIT_INDEX_FILE="$seed_temp" git read-tree HEAD || die "could not seed a missing index from HEAD" 5
    fi
  fi
  export GIT_INDEX_FILE="$TEMP_INDEX_PATH"
}

release_index_transaction() {
  unset GIT_INDEX_FILE
  [ -z "$TEMP_INDEX_PATH" ] || rm -f "$TEMP_INDEX_PATH"
  [ -z "$INDEX_LOCK_PATH" ] || rm -f "$INDEX_LOCK_PATH"
  TEMP_INDEX_PATH=""
  INDEX_LOCK_PATH=""
  INDEX_TRANSACTION_ACTIVE=0
}

commit_index_transaction() {
  [ -f "$TEMP_INDEX_PATH" ] || die "alternate index was not produced; real index unchanged" 5
  # Keep the canonical lock path present throughout both atomic renames. Other
  # normal Git writers cannot enter between validation and publication.
  mv -f "$TEMP_INDEX_PATH" "$INDEX_LOCK_PATH" || die "could not prepare the locked index update" 5
  TEMP_INDEX_PATH=""
  mv -f "$INDEX_LOCK_PATH" "$INDEX_PATH" || die "could not atomically publish the validated index" 5
  INDEX_LOCK_PATH=""
  INDEX_TRANSACTION_ACTIVE=0
  unset GIT_INDEX_FILE
}

reject_unmerged_candidates() {
  local path
  for path in "${CANDIDATES[@]}"; do
    if GIT_LITERAL_PATHSPECS=1 git ls-files -u -- "$path" | grep -q .; then
      die "unmerged artifact conflicts must be resolved explicitly; index unchanged" 5
    fi
  done
}

verify_selected_staged() {
  local path diff_rc
  reject_unmerged_candidates
  if ! has_staged_code_changes; then
    die "current commit index has no staged non-artifact feature diff; stage code explicitly before committing" 4
  fi
  for path in "${CANDIDATES[@]}"; do
    diff_rc=0
    GIT_LITERAL_PATHSPECS=1 git diff --cached --quiet -- "$path" || diff_rc=$?
    case "$diff_rc" in
      1) printf 'verified-staged: %s\n' "$path" ;;
      0) die "selected exact artifact has no staged diff in the current commit index; run exact staging first" 5 ;;
      *) die "could not verify selected artifact in the current commit index" 5 ;;
    esac
  done
  log "${#CANDIDATES[@]} exact artifact(s) verified in the current commit index."
}

# Validate the whole add set against the alternate index before its single
# mutating git process. The batch ignore check prevents partial staging, and
# --dry-run catches every other addability failure.
preflight_candidates() {
  local ignored_file check_rc=0
  ignored_file="$(mktemp "${TMPDIR:-/tmp}/agent-history-ignored.XXXXXX")"
  printf '%s\0' "${CANDIDATES[@]}" | git check-ignore -z --stdin > "$ignored_file" 2>/dev/null || check_rc=$?
  case "$check_rc" in
    0)
      rm -f "$ignored_file"
      die "selected artifact is ignored and cannot be staged safely (value not shown)" 5 ;;
    1) rm -f "$ignored_file" ;;
    *) rm -f "$ignored_file"; die "git check-ignore failed while validating the atomic add set" 5 ;;
  esac
  GIT_LITERAL_PATHSPECS=1 git add --dry-run -- "${CANDIDATES[@]}" >/dev/null 2>&1 || \
    die "one or more selected artifacts are not addable; index unchanged" 5
}

run_exact_selector() {
  local selector_output selector_rc=0
  set -- "$SCRIPT_DIR/find-session.sh" --quiet --format "$1"
  [ "$SESSION_ID_SET" = "1" ] && set -- "$@" --session-id "$SESSION_ID"
  [ "$SPECSTORY_PATH_SET" = "1" ] && set -- "$@" --specstory-path "$SPECSTORY_INPUT"
  selector_output="$("$@")" || selector_rc=$?
  if [ "$selector_rc" != "0" ]; then
    printf '%s\n' "$selector_output" >&2
    die "exact session selector failed (find-session exit $selector_rc); index unchanged" 5
  fi
  printf '%s' "$selector_output"
}

CANDIDATES=()

if [ "$SESSION_ONLY" = "1" ]; then
  if [ "$NO_SPECSTORY" = "1" ]; then
    # Prove that the explicitly named raw Claude session belongs to this checkout.
    selector_output="$(run_exact_selector claude)"
  else
    # Prove both rendered and raw artifacts describe the same checkout/session.
    selector_output="$(run_exact_selector both)"
    specstory_absolute="$(printf '%s\n' "$selector_output" | awk -F '\t' '$1=="specstory_path" {print $2; exit}')"
    [ -n "$specstory_absolute" ] || die "exact selector returned no SpecStory path; index unchanged" 5
    if ! specstory_relative="$(repo_relative_path "$specstory_absolute")"; then
      die "exact selector returned a transcript outside the git root: $specstory_absolute" 5
    fi
    append_unique_candidate "$specstory_relative"
  fi

  if [ "$PLAN_SET" = "1" ]; then
    plan_rc=0
    plan_absolute="$(canonical_existing_file "$PLAN_INPUT")" || plan_rc=$?
    case "$plan_rc" in
      0) ;;
      2) die "--plan must not be a symlink (value not shown); index unchanged" 5 ;;
      *) die "--plan does not exist as a regular file (value not shown); index unchanged" 5 ;;
    esac
    if ! plan_relative="$(repo_relative_path "$plan_absolute")"; then
      die "--plan is outside the git root (value not shown); index unchanged" 5
    fi
    is_exact_plan_path "$plan_relative" || die "--plan must be Markdown under a configured artifact directory other than .specstory/history (value not shown)" 5
    append_unique_candidate "$plan_relative"
  fi
else
  collect_broad_artifacts
fi

# Complete path, ignore, and addability validation before any index mutation.
for artifact in "${CANDIDATES[@]:-}"; do
  [ -n "$artifact" ] || continue
  validate_candidate_path "$artifact"
done

if [ "$CHECK_STAGED" = "1" ]; then
  verify_selected_staged
  exit 0
fi

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  if has_staged_code_changes; then
    log "No agent artifacts to stage; staged non-artifact code changes are present — nothing to do."
    exit 0
  fi
  log "Nothing to stage: no staged non-artifact code and no dirty artifacts."
  exit 3
fi

begin_index_transaction
reject_unmerged_candidates
preflight_candidates

if [ "$ALLOW_EMPTY" = "0" ] && ! has_staged_code_changes; then
  log "Refusing: artifacts are dirty but no non-artifact code changes are staged."
  log "         Unstaged working-tree code will not be part of the next commit."
  log "         Stage the feature diff first, or use --allow-empty only for an intentional artifact-only commit."
  exit 4
fi

if [ "$DRY_RUN" = "1" ]; then
  for artifact in "${CANDIDATES[@]}"; do
    printf '[dry-run] would git add: %s\n' "$artifact"
  done
  release_index_transaction
  log "${#CANDIDATES[@]} artifact(s) validated; index unchanged."
  exit 0
fi

# One git process mutates only the alternate index while the real index lock is
# held. Publishing the validated result is a final atomic rename.
GIT_LITERAL_PATHSPECS=1 git add -- "${CANDIDATES[@]}"
commit_index_transaction
for artifact in "${CANDIDATES[@]}"; do
  printf 'staged: %s\n' "$artifact"
done
log "${#CANDIDATES[@]} artifact(s) staged atomically with the feature index."
