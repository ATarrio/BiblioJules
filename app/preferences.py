"""Tiny JSON preferences store for the desktop app (and any future shared use).

Lives next to the SQLite database in the project ``data/`` directory so a single
file follows the user regardless of their working directory. It holds the UI
language, the accent colour, the chosen data source (local database or a hosted
server) and, for remote mode, the access token — so the file is written with
``0600`` permissions and must never be committed.
"""

from __future__ import annotations

from typing import Callable

from . import themes
from .config import DATA_DIR
from .i18n import DEFAULT_LANGUAGE, normalize_language
from .services.jsonstore import load_json, save_json, update_json_object

PREFS_FILE = DATA_DIR / "preferences.json"

#: Data-source modes.
MODE_LOCAL = "local"
MODE_REMOTE = "remote"
MODES = (MODE_LOCAL, MODE_REMOTE)


def load_preferences() -> dict:
    data = load_json(PREFS_FILE, {})
    return data if isinstance(data, dict) else {}


def save_preferences(preferences: dict) -> None:
    save_json(PREFS_FILE, preferences)


def _update_preferences(mutate: Callable[[dict], None]) -> dict:
    """Apply one change without losing a concurrent writer's update."""
    return update_json_object(PREFS_FILE, mutate)


def get_preferred_language() -> str:
    return normalize_language(load_preferences().get("language", DEFAULT_LANGUAGE))


def set_preferred_language(code: str) -> str:
    language = normalize_language(code)
    _update_preferences(lambda preferences: preferences.update(language=language))
    return language


# --------------------------------------------------------------------------- #
# Appearance (the accent colour the whole UI is drawn in)
# --------------------------------------------------------------------------- #
def get_color_theme() -> str:
    """The saved accent, falling back to the default theme."""
    return themes.normalize_theme(load_preferences().get("color_theme"))


def set_color_theme(slug: str) -> str:
    color_theme = themes.normalize_theme(slug)
    _update_preferences(
        lambda preferences: preferences.update(color_theme=color_theme)
    )
    return color_theme


# --------------------------------------------------------------------------- #
# Data source (local database vs. hosted server)
# --------------------------------------------------------------------------- #
def get_mode() -> str:
    mode = load_preferences().get("mode")
    return mode if mode in MODES else MODE_LOCAL


def set_mode(mode: str) -> str:
    value = mode if mode in MODES else MODE_LOCAL
    _update_preferences(lambda preferences: preferences.update(mode=value))
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

    def mutate(preferences: dict) -> None:
        if backend_url is not None:
            preferences["backend_url"] = backend_url.strip()
        preferences["api_token"] = (token or "").strip()
        preferences["account_name"] = (account or "").strip()

    _update_preferences(mutate)


# --------------------------------------------------------------------------- #
# Shared library (file-based sync)
# --------------------------------------------------------------------------- #
# The desktop keeps its own copy of the folder setting: it may point at a
# different folder than the web app's stored setting, and it must work even when
# only the desktop is installed. The sync service still uses the same snapshot
# format, so both can share one folder when they run on the same machine.
def get_sync_file() -> str:
    return str(load_preferences().get("sync_file") or "").strip()


def set_sync_file(path: str) -> str:
    value = (path or "").strip()
    _update_preferences(lambda preferences: preferences.update(sync_file=value))
    return value


def get_sync_on_start() -> bool:
    return bool(load_preferences().get("sync_on_start", False))


def set_sync_on_start(enabled: bool) -> bool:
    value = bool(enabled)
    _update_preferences(
        lambda preferences: preferences.update(sync_on_start=value)
    )
    return value
