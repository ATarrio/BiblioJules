"""Personal reading stats and goals, stored as local JSON files in ``data/``.

These are *local-only*: they live next to the SQLite database but are never
included in the cross-device sync snapshot (``bibliojules-library.sqlite``
contains no accounts and no personal metadata).  Each device keeps its own stats
and goals; they simply don't travel when the library is merged from another
machine.

The web dashboard reaches them via the JSON API (``/api/personal-stats`` etc.);
the desktop app talks to the same endpoints (remote mode) or reads the files
directly (local mode, through this module).
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any

try:  # POSIX file locks; Windows falls back to the in-process lock.
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None  # type: ignore[assignment]

from ..config import DATA_DIR

STATS_FILE = DATA_DIR / "stats.json"
GOALS_FILE = DATA_DIR / "goals.json"
WANT_LIST_FILE = DATA_DIR / "want_list.json"

_LOCKS_GUARD = threading.Lock()
_LOCKS: dict[str, threading.RLock] = {}


def _thread_lock(path: Path) -> threading.RLock:
    key = str(path)
    with _LOCKS_GUARD:
        lock = _LOCKS.get(key)
        if lock is None:
            lock = _LOCKS[key] = threading.RLock()
        return lock


@contextmanager
def _file_lock(path: Path):
    """Serialize a read-modify-write of one JSON file.

    The thread lock covers several workers in one process; ``flock`` covers
    separate processes (the web server and the desktop app share ``data/``).
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    lock = _thread_lock(path)
    with lock:
        handle = None
        try:
            handle = open(str(path) + ".lock", "a+", encoding="utf-8")
            if fcntl is not None:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            yield
        finally:
            if handle is not None:
                if fcntl is not None:
                    try:
                        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                    except OSError:  # pragma: no cover
                        pass
                handle.close()


# --------------------------------------------------------------------------- #
# JSON helpers
# --------------------------------------------------------------------------- #
def _load_json(path: Path, default: Any) -> Any:
    try:
        with path.open(encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _save_json(path: Path, data: Any) -> None:
    """Write atomically, using a unique temporary file per writer.

    A fixed ``.tmp`` name let two requests overwrite each other's partial file
    and publish a truncated JSON document.
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    descriptor, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    tmp = Path(tmp_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        try:
            tmp.chmod(0o600)
        except OSError:  # pragma: no cover - non-POSIX filesystems
            pass
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return default


def _scoped_path(path: Path, user_id: int | None) -> Path:
    """Goals/wantlist are per account on a shared server, per device offline."""
    if user_id is None:
        return path
    return path.with_name(f"{path.stem}.u{_as_int(user_id)}{path.suffix}")


def _read_scoped(
    path: Path, default: Any, user_id: int | None, *, locked: bool = False
) -> Any:
    target = _scoped_path(path, user_id)
    # Lock the file this caller actually reads: the legacy migration and a
    # concurrent save must not race and copy the old shared file over the
    # account's newer data. Callers that already hold this file's lock pass
    # ``locked=True`` — flock is not re-entrant across two open handles.
    if locked:
        return _read_scoped_unlocked(path, target, default, user_id)
    with _file_lock(target):
        return _read_scoped_unlocked(path, target, default, user_id)


def _read_scoped_unlocked(
    path: Path, target: Path, default: Any, user_id: int | None
) -> Any:
    if user_id is not None and not target.exists() and path.exists():
        # One-time migration: the old shared file becomes this account's file.
        # Re-checked under the lock, so only the first reader copies.
        data = _load_json(path, default)
        _save_json(target, data)
        return data
    return _load_json(target, default)


def _write_scoped(path: Path, data: Any, user_id: int | None) -> None:
    _save_json(_scoped_path(path, user_id), data)


# --------------------------------------------------------------------------- #
# Stats – computed from the shared library DB on each read
# --------------------------------------------------------------------------- #


def compute_stats(db) -> dict:
    """Return stats derived from the shared library database.

    These numbers are read-only aggregations computed on every call, so they
    always reflect the current library state.  They are *not* persisted here —
    only goals and the want-to-read list are saved to disk.
    """
    from ..services.library import get_stats, query_books

    shared = get_stats(db)

    # Fetch every book once and tally by read status, so "currently reading",
    # DNF, lost and donated are not silently counted from the read-only subset.
    books = query_books(db)
    by_status: dict[str, int] = {}
    for book in books:
        slug = book.read_status or "unread"
        by_status[slug] = by_status.get(slug, 0) + 1

    read_books = [b for b in books if b.read_status == "read"]
    books_read = len(read_books)
    pages_read = sum(b.page_count or 0 for b in read_books if b.page_count)

    rated = [b for b in read_books if b.score is not None]
    avg_rating = round(sum(b.score for b in rated) / len(rated), 1) if rated else None

    return {
        "total_books": shared["total"],
        "in_library": (shared["total"] - shared["wishlist"]) if shared["total"] >= shared["wishlist"] else shared["total"],
        "books_read": books_read,
        "pages_read": pages_read,
        "avg_rating": avg_rating,
        "currently_reading": by_status.get("currently_reading", 0),
        "loans": shared["loans"],
        "wishlist": shared["wishlist"],
        "authors": shared["authors"],
        "status_breakdown": {
            "read": by_status.get("read", 0),
            "currently_reading": by_status.get("currently_reading", 0),
            "dnf": by_status.get("dnf", 0),
            "lost": by_status.get("lost", 0),
            "donated": by_status.get("donated", 0),
            "unread": by_status.get("unread", 0),
            "to_read": by_status.get("to_read", 0),
        },
    }


def load_stats_file() -> dict:
    """Return the persisted per-device stats dict (currently empty by default)."""
    return _load_json(STATS_FILE, {})


def save_stats_file(stats: dict) -> None:
    """Persist per-device local stats (e.g. a last-updated timestamp)."""
    _save_json(STATS_FILE, stats)


# --------------------------------------------------------------------------- #
# Goals
# --------------------------------------------------------------------------- #


def load_goals(user_id: int | None = None) -> dict:
    """Return the goals dict for ``user_id`` (or the offline device)."""
    data = _read_scoped(
        GOALS_FILE,
        {"year": None, "target_books": 0, "target_pages": 0, "progress": {}},
        user_id,
    )
    if not isinstance(data, dict):
        data = {}
    progress = data.get("progress")
    return {
        "year": _as_int(data.get("year"), 0) or None,
        "target_books": _as_int(data.get("target_books")),
        "target_pages": _as_int(data.get("target_pages")),
        "progress": dict(progress) if isinstance(progress, dict) else {},
    }


def save_goals(goals: dict, user_id: int | None = None) -> None:
    """Replace the goals dict for ``user_id`` (or the offline device)."""
    if not isinstance(goals, dict):
        goals = {}
    progress = goals.get("progress")
    clean = {
        "year": _as_int(goals.get("year"), 0) or None,
        "target_books": _as_int(goals.get("target_books")),
        "target_pages": _as_int(goals.get("target_pages")),
        "progress": dict(progress) if isinstance(progress, dict) else {},
    }
    with _file_lock(_scoped_path(GOALS_FILE, user_id)):
        _write_scoped(GOALS_FILE, clean, user_id)


# --------------------------------------------------------------------------- #
# Want-to-read list
# --------------------------------------------------------------------------- #


def load_want_list(user_id: int | None = None) -> list[dict]:
    """Return the want-to-read list for ``user_id`` (or the offline device)."""
    data = _read_scoped(WANT_LIST_FILE, [], user_id)
    return [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []


def save_want_list(items: list[dict], user_id: int | None = None) -> None:
    """Replace the want-to-read list for ``user_id`` (or the offline device)."""
    clean = [item for item in items if isinstance(item, dict)]
    with _file_lock(_scoped_path(WANT_LIST_FILE, user_id)):
        _write_scoped(WANT_LIST_FILE, clean, user_id)


def add_want_entry(entry: dict, user_id: int | None = None) -> None:
    """Append an entry, deduplicating by ISBN (or title) when present."""
    if not isinstance(entry, dict):
        return
    with _file_lock(_scoped_path(WANT_LIST_FILE, user_id)):
        data = _read_scoped(WANT_LIST_FILE, [], user_id, locked=True)
        items = [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []
        isbn = (entry.get("isbn") or "").strip()
        title = (entry.get("title") or "").strip().casefold()
        if isbn:
            items = [i for i in items if (i.get("isbn") or "").strip() != isbn]
        elif title:
            items = [
                i for i in items if (i.get("title") or "").strip().casefold() != title
            ]
        items.append(entry)
        _write_scoped(WANT_LIST_FILE, items, user_id)


def remove_want_entry(
    isbn: str | None = None,
    entry_id: str | None = None,
    user_id: int | None = None,
) -> None:
    """Remove an entry by its id (or by ISBN as a fallback)."""
    with _file_lock(_scoped_path(WANT_LIST_FILE, user_id)):
        data = _read_scoped(WANT_LIST_FILE, [], user_id, locked=True)
        items = [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []
        if entry_id:
            items = [i for i in items if i.get("id") != entry_id]
        elif isbn:
            items = [i for i in items if i.get("isbn") != isbn]
        _write_scoped(WANT_LIST_FILE, items, user_id)
