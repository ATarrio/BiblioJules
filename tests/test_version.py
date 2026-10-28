"""The Python, mobile and package versions must agree."""

from __future__ import annotations

import re
from pathlib import Path

from app import __version__

ROOT = Path(__file__).resolve().parent.parent


def _pubspec_version() -> str:
    text = (ROOT / "mobile" / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"^version:\s*(.+)$", text, re.MULTILINE)
    assert match is not None
    return match.group(1).strip().split("+")[0]


def _mobile_constant() -> str:
    text = (
        ROOT / "mobile" / "lib" / "src" / "core" / "providers.dart"
    ).read_text(encoding="utf-8")
    match = re.search(r"kAppVersion\s*=\s*'([^']+)'", text)
    assert match is not None
    return match.group(1)


def test_versions_match():
    assert __version__ == _pubspec_version() == _mobile_constant()
