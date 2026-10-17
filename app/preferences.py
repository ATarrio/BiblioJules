"""Tiny JSON preferences store for the desktop app (and any future shared use).

Lives next to the SQLite database in the project ``data/`` directory so a single
file follows the user regardless of their working directory. Only small,
non-critical UI choices belong here (language, ...); real data lives in the DB.
"""

from __future__ import annotations

import json
from pathlib import Path

from .config import DATA_DIR
from .i18n import DEFAULT_LANGUAGE, normalize_language

PREFS_FILE = DATA_DIR / "preferences.json"


def load_preferences() -> dict:
    try:
        with PREFS_FILE.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_preferences(preferences: dict) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(PREFS_FILE) + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(preferences, handle, ensure_ascii=False, indent=2)
    tmp.replace(PREFS_FILE)


def get_preferred_language() -> str:
    return normalize_language(load_preferences().get("language", DEFAULT_LANGUAGE))


def set_preferred_language(code: str) -> str:
    preferences = load_preferences()
    language = normalize_language(code)
    preferences["language"] = language
    save_preferences(preferences)
    return language
