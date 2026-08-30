"""Guard: nothing this skill SHIPS may trip a downstream secret scanner.

`npx skills add` materialises the whole skill directory -- assets/, tests/,
fixtures/ and all -- into the consumer's repo under `.agents/skills/<name>/`
(with `.claude/skills/<name>` symlinked to it). Those files are then inside
the consumer's own pre-commit scan scope.

pre-commit's `detect-private-key` greps its BLACKLIST as plain byte
substrings and honours NO allowlist mechanism: not `<!-- gitleaks:allow -->`,
not `.github/secret_scanning.yml`, not a `# noqa`-style marker. So a single
literal key header (`BEGIN RSA ...`, spelled out in the list below) in a file
we ship fails `git commit` in every downstream repo running that hook, and the user's only escape is to edit their
own config. That is our bug to prevent, not theirs to work around.

Real symptom this guards against:

    detect private key.......................................................Failed
    Private key found: .agents/skills/agent-history-hygiene/tests/test_redact_secrets.py
    Private key found: .agents/skills/agent-history-hygiene/tests/README.md
    Private key found: .agents/skills/agent-history-hygiene/tests/fixtures/private_key.md

The fix is never a wider `exclude:` -- it is to keep the bytes out. Tests
assemble headers at runtime (see `pem_header` in conftest), fixtures carry
`__SYNTHETIC_PEM_*__` placeholders that the staging helpers expand, and
`assets/redact_secrets.py` splits its OpenVPN token across two literals.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from conftest import OPENVPN_HEADER, PUTTY_HEADER, SKILL_ROOT

# Verbatim from pre-commit/pre-commit-hooks `pre_commit_hooks/detect_private_key.py`
# (v5.0.0). Assembled from split literals so THIS file does not become the
# thing it forbids. `_PK` is "PRIVATE KEY"; do not join these back up.
_PK = "PRIVATE" + " KEY"
DETECT_PRIVATE_KEY_BLACKLIST = (
    f"BEGIN RSA {_PK}",
    f"BEGIN DSA {_PK}",
    f"BEGIN EC {_PK}",
    f"BEGIN OPENSSH {_PK}",
    f"BEGIN {_PK}",
    PUTTY_HEADER,
    f"BEGIN SSH2 ENCRYPTED {_PK}",
    f"BEGIN PGP {_PK} BLOCK",
    f"BEGIN ENCRYPTED {_PK}",
    OPENVPN_HEADER.strip("-"),
)

#: Generated/transient dirs that `npx skills add` does not ship.
_SKIP_DIRS = {"__pycache__", ".pytest_cache", ".git", "node_modules"}


def _shipped_files() -> list[Path]:
    return sorted(
        p
        for p in SKILL_ROOT.rglob("*")
        if p.is_file() and not _SKIP_DIRS & set(p.relative_to(SKILL_ROOT).parts)
    )


class TestNoBlacklistedHeadersOnDisk:
    """Every shipped file must survive `detect-private-key` unmodified."""

    def test_at_least_one_file_was_scanned(self):
        """Guard the guard: a broken glob would make this suite vacuously pass."""
        assert len(_shipped_files()) > 10

    def test_no_shipped_file_contains_a_blacklisted_header(self):
        offenders: dict[str, list[str]] = {}
        for path in _shipped_files():
            try:
                content = path.read_bytes()
            except OSError:  # pragma: no cover -- defensive
                continue
            hits = [
                token
                for token in DETECT_PRIVATE_KEY_BLACKLIST
                if token.encode() in content
            ]
            if hits:
                offenders[str(path.relative_to(SKILL_ROOT))] = hits
        assert not offenders, (
            "These shipped files carry a detect-private-key BLACKLIST substring "
            "and will fail `git commit` in every downstream repo that installs "
            f"this skill: {offenders}. Assemble the header at runtime "
            "(conftest.pem_header) or use a __SYNTHETIC_PEM_*__ placeholder "
            "instead of widening the hook's exclude."
        )


class TestCompiledBytecodeIsClean:
    """A clean `.py` is not enough -- CPython constant-folds.

    `"PuTTY-User-" + "Key-File-2"` is one literal by the time it reaches the
    `.pyc`, so the split-literal trick protects the source and nothing else. A
    downstream user who runs this suite inside their own repo materialises
    `.agents/skills/agent-history-hygiene/tests/__pycache__/*.pyc`, and if
    `__pycache__` is not gitignored there, detect-private-key fails their commit
    again -- this time pointing at a build artifact they did not write.

    The fix that holds is splitting at the version digit (`V{n}` / `File-{n}`),
    because the truncated prefix is not itself a BLACKLIST entry.
    """

    def test_no_compiled_module_contains_a_blacklisted_header(self, tmp_path: Path):
        import py_compile

        offenders: dict[str, list[str]] = {}
        for source in SKILL_ROOT.rglob("*.py"):
            if "__pycache__" in source.parts:
                continue
            out = tmp_path / (source.stem + ".pyc")
            try:
                py_compile.compile(str(source), cfile=str(out), doraise=True)
            except py_compile.PyCompileError:  # pragma: no cover -- defensive
                continue
            blob = out.read_bytes()
            hits = [t for t in DETECT_PRIVATE_KEY_BLACKLIST if t.encode() in blob]
            if hits:
                offenders[str(source.relative_to(SKILL_ROOT))] = hits
        assert not offenders, (
            "Compiling these modules produces a .pyc containing a "
            f"detect-private-key BLACKLIST substring: {offenders}. Adjacent "
            "string literals get folded -- split at the version digit and use "
            "an f-string over a named constant instead."
        )


class TestRedactorCoversTheWholeBlacklist:
    """Our redactor must scrub everything detect-private-key would reject.

    If it missed an entry, the redact hook would report a clean pass and the
    very next hook in the chain would still fail the commit -- with nothing
    left for the user to fix.
    """

    @pytest.mark.parametrize("token", DETECT_PRIVATE_KEY_BLACKLIST)
    def test_header_is_detected_and_scrubbed(
        self, redact_secrets, tmp_path: Path, token: str
    ):
        f = tmp_path / "p.md"
        f.write_text(f"pasted -----{token}----- oops\n", encoding="utf-8")

        assert redact_secrets.find_private_key_files([f]), (
            f"find_private_key_files missed BLACKLIST entry {token!r}"
        )
        assert redact_secrets.redact_private_keys(f) is True
        content = f.read_text(encoding="utf-8")
        assert token not in content, (
            f"redact_private_keys left BLACKLIST entry {token!r} in place"
        )

    @pytest.mark.parametrize("token", DETECT_PRIVATE_KEY_BLACKLIST)
    def test_redaction_converges(self, redact_secrets, tmp_path: Path, token: str):
        """The sentinel must not itself re-match -- otherwise the hook rewrites
        the file on every run and the commit never converges."""
        f = tmp_path / "p.md"
        f.write_text(f"pasted -----{token}----- oops\n", encoding="utf-8")
        assert redact_secrets.redact_private_keys(f) is True
        assert redact_secrets.redact_private_keys(f) is False
