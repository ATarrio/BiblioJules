"""The English source strings used by Python and Jinja exist in the catalog."""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_CATALOG = ROOT / "app" / "locales" / "es-419.json"
MOBILE_CATALOG = ROOT / "mobile" / "assets" / "locales" / "es-419.json"

_TRANSLATION_CALLS = {"_", "gettext", "ngettext"}
_TEMPLATE_CALL = re.compile(
    r"(?:_|gettext|ngettext)\(\s*(['\"])(?P<key>.*?)\1", re.DOTALL
)


def _python_keys():
    for path in (ROOT / "app").rglob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not node.args:
                continue
            name = None
            if isinstance(node.func, ast.Name):
                name = node.func.id
            elif isinstance(node.func, ast.Attribute):
                name = node.func.attr
            if name not in _TRANSLATION_CALLS:
                continue
            first = node.args[0]
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                yield first.value, path


def _template_keys():
    for path in (ROOT / "app" / "templates").rglob("*.html"):
        text = path.read_text(encoding="utf-8")
        for match in _TEMPLATE_CALL.finditer(text):
            yield match.group("key"), path


def test_bundled_catalogs_are_identical():
    assert json.loads(APP_CATALOG.read_text(encoding="utf-8")) == json.loads(
        MOBILE_CATALOG.read_text(encoding="utf-8")
    )


def test_every_catalog_entry_is_translated():
    catalog = json.loads(APP_CATALOG.read_text(encoding="utf-8"))
    empty = [key for key, value in catalog.items() if not value]
    assert empty == []


def test_python_and_template_strings_are_catalogued():
    catalog = json.loads(APP_CATALOG.read_text(encoding="utf-8"))
    missing = [
        f"{key!r} ({path.relative_to(ROOT)})"
        for key, path in [*_python_keys(), *_template_keys()]
        if key not in catalog
    ]
    assert missing == []
