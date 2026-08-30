"""Regression tests for bootstrap-project.sh's SpecStory state hygiene."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parents[1]
BOOTSTRAP = SKILL_DIR / "scripts" / "bootstrap-project.sh"


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=check,
        capture_output=True,
        text=True,
    )


def init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "agent-history-test@example.invalid")
    git(repo, "config", "user.name", "Agent History Test")
    # Avoid installing real hooks in the throwaway repo. bootstrap treats an
    # existing custom hooksPath as an intentional global-wrapper setup.
    git(repo, "config", "core.hooksPath", ".test-hooks")
    return repo


def run_bootstrap(repo: Path, tmp_path: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = str(tmp_path / "home")
    return subprocess.run(
        ["bash", str(BOOTSTRAP), *args],
        cwd=repo,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )


def test_adds_precise_rules_idempotently_and_keeps_history_visible(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)

    run_bootstrap(repo, tmp_path)
    ignore_file = repo / ".specstory" / ".gitignore"
    first = ignore_file.read_text()
    run_bootstrap(repo, tmp_path)

    assert ignore_file.read_text() == first
    assert first.count("/.project.json") == 1
    assert first.count("/statistics.json") == 1

    history = repo / ".specstory" / "history" / "session.md"
    history.parent.mkdir()
    history.write_text("# Session\n")
    ignored = git(repo, "check-ignore", "-q", str(history.relative_to(repo)), check=False)
    assert ignored.returncode == 1


def test_preserves_existing_nested_ignore_content(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    ignore_file = repo / ".specstory" / ".gitignore"
    ignore_file.parent.mkdir()
    ignore_file.write_text("# keep me\n/custom-local.json")

    run_bootstrap(repo, tmp_path)
    content = ignore_file.read_text()

    assert content.startswith("# keep me\n/custom-local.json\n")
    assert content.count("/.project.json") == 1
    assert content.count("/statistics.json") == 1


def test_dry_run_does_not_create_specstory_directory(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)

    result = run_bootstrap(repo, tmp_path, "--dry-run")

    assert not (repo / ".specstory").exists()
    assert "[dry-run] add '/.project.json'" in result.stderr
    assert "[dry-run] add '/statistics.json'" in result.stderr


def test_tracked_state_warns_until_explicitly_untracked(tmp_path: Path) -> None:
    repo = init_repo(tmp_path)
    specstory = repo / ".specstory"
    specstory.mkdir()
    project = specstory / ".project.json"
    statistics = specstory / "statistics.json"
    project.write_text('{"workspace_id":"machine-a"}\n')
    statistics.write_text('{"sessions":{}}\n')
    git(repo, "add", "-f", ".specstory/.project.json", ".specstory/statistics.json")
    git(repo, "commit", "-qm", "track old SpecStory state")
    statistics.write_text('{"sessions":{"new-machine":{}}}\n')

    warned = run_bootstrap(repo, tmp_path)
    assert "SpecStory machine state is already tracked" in warned.stderr
    assert git(repo, "ls-files", ".specstory/.project.json").stdout.strip()
    assert git(repo, "ls-files", ".specstory/statistics.json").stdout.strip()

    migrated = run_bootstrap(repo, tmp_path, "--untrack-specstory-state")
    assert "files remain on disk" in migrated.stderr
    assert project.exists()
    assert statistics.exists()
    assert git(repo, "ls-files", ".specstory/.project.json").stdout == ""
    assert git(repo, "ls-files", ".specstory/statistics.json").stdout == ""
    assert "D  .specstory/.project.json" in git(repo, "status", "--short").stdout
    assert "D  .specstory/statistics.json" in git(repo, "status", "--short").stdout
