"""Tiny JSON preferences store for the desktop app (and any future shared use).

Lives next to the SQLite database in the project ``data/`` directory so a single
file follows the user regardless of their working directory. It holds the UI
language, the chosen data source (local database or a hosted server) and, for
remote mode, the access token — so the file is written with ``0600``
permissions and must never be committed.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from .config import DATA_DIR
from .i18n import DEFAULT_LANGUAGE, normalize_language

PREFS_FILE = DATA_DIR / "preferences.json"

#: Data-source modes.
MODE_LOCAL = "local"
MODE_REMOTE = "remote"
MODES = (MODE_LOCAL, MODE_REMOTE)


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
    try:
        # The file can hold a remote access token; keep it private to the user.
        os.chmod(tmp, 0o600)
    except OSError:  # pragma: no cover - non-POSIX filesystems
        pass
    tmp.replace(PREFS_FILE)


def get_preferred_language() -> str:
    return normalize_language(load_preferences().get("language", DEFAULT_LANGUAGE))


def set_preferred_language(code: str) -> str:
    preferences = load_preferences()
    language = normalize_language(code)
    preferences["language"] = language
    save_preferences(preferences)
    return language


# --------------------------------------------------------------------------- #
# Data source (local database vs. hosted server)
# --------------------------------------------------------------------------- #
def get_mode() -> str:
    mode = load_preferences().get("mode")
    return mode if mode in MODES else MODE_LOCAL


def set_mode(mode: str) -> str:
    value = mode if mode in MODES else MODE_LOCAL
    preferences = load_preferences()
    preferences["mode"] = value
    save_preferences(preferences)
    return value


def get_backend_url() -> str:
    return str(load_preferences().get("backend_url") or "").strip()


def get_api_token() -> str:
    return str(load_preferences().get("api_token") or "").strip()


def get_account_name() -> str:
    return str(load_preferences().get("account_name") or "").strip()


def set_remote_session(
    *, backend_url: str | None = None, token: str | None = None, account: str | None = None
) -> None:
    """Store (or, with empty values, clear) the remote connection details."""
    preferences = load_preferences()
    if backend_url is not None:
        preferences["backend_url"] = backend_url.strip()
    preferences["api_token"] = (token or "").strip()
    preferences["account_name"] = (account or "").strip()
    save_preferences(preferences)
