#!/usr/bin/env bash
# Wrapper -> .agents/skills/project-knowledge-harness/scripts/<same-name>.sh
#
# WHY THIS EXISTS
# The project-knowledge-harness skill is vendored under `.agents/skills/`, and
# its SKILL.md documents its helpers with cwd-relative paths (`scripts/add-todo.sh`).
# That prose was copied verbatim into this repo's AGENTS.md and TODO.md, where
# `scripts/` means the repo-root script directory instead. Rather than editing
# those references -- they live inside `project-knowledge-harness` sentinels and
# would be regenerated away -- these shims make the documented paths real.
#
# All four wrappers are byte-identical; the target is derived from $0, so a new
# helper only needs a copy of this file under its own name.
# Not a symlink: AGENTS.md invariant 6 -- symlinks/junctions need elevation or
# Developer Mode on Windows.
set -euo pipefail

self="$(basename -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
real="$script_dir/../.agents/skills/project-knowledge-harness/scripts/$self"

if [[ ! -f "$real" ]]; then
    printf 'error: %s: real implementation not found at\n  %s\n' "$self" "$real" >&2
    printf 'The project-knowledge-harness skill should be vendored under .agents/skills/.\n' >&2
    exit 127
fi

# exec via bash rather than relying on the +x bit: git on Windows does not
# always preserve the executable mode in a fresh clone.
exec bash "$real" "$@"
