"""Small atomic JSON file store shared by preferences and personal lists.

Writes go to a unique temporary file in the destination directory and are then
renamed over the target, so a reader never sees a half-written document. A
per-path thread lock plus ``flock`` (where available) serializes read-modify-
write cycles between threads and between the web server and the desktop app.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

try:  # POSIX file locks; Windows falls back to the in-process lock.
    import fcntl
except ImportError:  # pragma: no cover - Windows
    fcntl = None  # type: ignore[assignment]

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
def file_lock(path: Path):
    """Serialize read-modify-write cycles for one JSON file."""
    path.parent.mkdir(parents=True, exist_ok=True)
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
                    except OSError:  # pragma: no cover - best effort
                        pass
                handle.close()


def load_json(path: Path, default: Any) -> Any:
    """Return the document at ``path``, or ``default`` when it is unreadable."""
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def save_json(path: Path, data: Any) -> None:
    """Write ``data`` atomically, using a unique temporary file per writer."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    tmp = Path(tmp_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            # These files can hold a remote access token; keep them private.
            tmp.chmod(0o600)
        except OSError:  # pragma: no cover - non-POSIX filesystems
            pass
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def update_json_object(
    path: Path,
    mutate: Callable[[dict], None],
    default: dict | None = None,
) -> dict:
    """Lock, load, mutate and atomically save a JSON object."""
    fallback = {} if default is None else default
    with file_lock(path):
        data = load_json(path, fallback)
        if not isinstance(data, dict):
            data = dict(fallback)
        mutate(data)
        save_json(path, data)
        return data
