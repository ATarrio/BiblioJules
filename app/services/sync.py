"""Sharing one library between devices, without a server.

The design is deliberately boring: each app keeps its own SQLite file, and the
shared folder (Google Drive, Syncthing, a USB stick — anything that copies a
file) carries a *snapshot*. ``sync_now`` reads that snapshot, merges it into the
local library, then writes the merged result back. Nothing ever opens the shared
file live, so no amount of cloud latency can corrupt a library.

A snapshot is a normal BiblioJules database — ``VACUUM INTO`` of the live one —
minus ``users``/``tokens`` (accounts stay on the machine that authenticates),
plus one extra table, ``sync_meta``: a small key/value header with the format,
a fresh ``snapshot_id``, a generation counter and the exporting device's name.

Merging is last-write-wins per row, keyed by ``sync_id`` (see
``app/models/common.py``). Some tables also have a natural key, so the *first*
sync can marry rows that were created independently on two devices:

* statuses by ``slug``, then name (the system statuses are seeded on both);
* authors and publishers by name;
* books by ISBN (two people scanning the same book);
* locations only by ``sync_id`` — two shelves can honestly share a name.

Deletions travel as tombstones (``app/models/sync.py``). A tombstone wins if it
is newer than the row; a newer edit resurrects the row and drops the tombstone.

The merge is SQLite-only. It needs the file path for ``VACUUM INTO`` and talks
to the live database through a second connection, so a PostgreSQL deployment
would have to keep using the hosted-server mode instead. That trade is what
buys a single implementation shared by the web and desktop apps, and a Dart port
that maps statement for statement (``mobile/lib/src/local/sync.dart``).
"""

from __future__ import annotations

import json
import os
import socket
import sqlite3
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from ..config import settings

#: Bumped if the layout of a snapshot (not the library schema) ever changes.
FORMAT = 1

#: One fixed name in every shared folder, whichever client wrote it.
SNAPSHOT_NAME = "bibliojules-library.sqlite"

#: Where the per-device identity and the last seen snapshot are remembered.
STATE_NAME = "sync_state.json"
#: The folder chosen from the web admin page (kept out of ``.env``).
SYNC_SETTINGS_NAME = "sync_settings.json"
BACKUP_FOLDER = "backups"
KEEP_BACKUPS = 10

#: Tables a snapshot must contain to be usable.
REQUIRED_TABLES = (
    "authors",
    "publishers",
    "locations",
    "statuses",
    "books",
    "book_authors",
    "loans",
)

#: Tables whose rows carry a ``sync_id``/``updated_at`` pair.
SYNCED_TABLES = ("books", "authors", "publishers", "locations", "statuses", "loans")

STATUS_FIELDS = (
    "name",
    "slug",
    "color",
    "icon",
    "description",
    "sort_order",
    "is_system",
    "is_default",
)
LOCATION_FIELDS = ("name", "kind", "description")
NAME_FIELDS = ("name",)
BOOK_FIELDS = (
    "isbn",
    "title",
    "subtitle",
    "published_date",
    "published_year",
    "description",
    "page_count",
    "language",
    "cover_url",
    "cover_type",
    "read_status",
    "score",
    "saga",
    "saga_number",
    "source",
    "notes",
)
LOAN_FIELDS = (
    "borrower_name",
    "borrower_contact",
    "lent_at",
    "due_at",
    "returned_at",
    "notes",
)

TABLE_LABELS = {
    "books": "books",
    "authors": "authors",
    "publishers": "publishers",
    "locations": "shelves",
    "statuses": "statuses",
    "loans": "loans",
}


class SyncError(RuntimeError):
    """A problem the user can act on: wrong file, missing folder, no SQLite."""


@dataclass
class SnapshotMeta:
    format: int
    schema_version: int
    snapshot_id: str
    generation: int
    exported_at: str
    device_id: str
    device_name: str
    based_on: str | None
    row_counts: dict[str, int]

    def as_dict(self) -> dict:
        return {
            "format": self.format,
            "schema_version": self.schema_version,
            "snapshot_id": self.snapshot_id,
            "generation": self.generation,
            "exported_at": self.exported_at,
            "device_id": self.device_id,
            "device_name": self.device_name,
            "based_on": self.based_on,
            "row_counts": dict(self.row_counts),
        }


@dataclass
class MergeSummary:
    """What changed locally because of the snapshot, in user-facing terms."""

    source_device: str = ""
    source_generation: int = 0
    added: dict[str, int] = field(default_factory=dict)
    updated: dict[str, int] = field(default_factory=dict)
    deleted: dict[str, int] = field(default_factory=dict)
    conflicts: list[str] = field(default_factory=list)

    def bump(self, bucket: dict[str, int], table: str, count: int = 1) -> None:
        bucket[table] = bucket.get(table, 0) + count

    @property
    def changes(self) -> int:
        return sum(self.added.values()) + sum(self.updated.values()) + sum(self.deleted.values())

    def as_dict(self) -> dict:
        return {
            "source_device": self.source_device,
            "source_generation": self.source_generation,
            "added": dict(self.added),
            "updated": dict(self.updated),
            "deleted": dict(self.deleted),
            "conflicts": list(self.conflicts),
            "changes": self.changes,
        }


@dataclass
class SyncResult:
    snapshot: SnapshotMeta
    merge: MergeSummary | None = None
    pushed: bool = False
    merged_snapshot: bool = False

    def as_dict(self) -> dict:
        return {
            "snapshot": self.snapshot.as_dict(),
            "merge": self.merge.as_dict() if self.merge else None,
            "pushed": self.pushed,
            "merged_snapshot": self.merged_snapshot,
        }


def stamp_now() -> str:
    """The same textual timestamp SQLAlchemy writes to SQLite."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")


def _stamp(value) -> float:
    """Seconds since the epoch for a stored timestamp; 0 when empty.

    Timestamps are compared as instants, never as strings: SQLite stores
    ``YYYY-MM-DD HH:MM:SS.ffffff``, the mobile app can write ISO ``T`` values,
    and a snapshot might come from a build that appended ``Z`` or an offset.
    """
    if not value:
        return 0.0
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    text = text.replace("T", " ", 1)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return 0.0
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    stamp = parsed.timestamp()
    # A device whose clock is set years ahead would otherwise win every future
    # conflict forever. Treat anything beyond a small tolerance as "now" so the
    # next edit with a sane clock can still win.
    now = time.time()
    if stamp > now + 300:
        return now
    return stamp


class SyncState:
    """The little bit of per-device bookkeeping a sync needs."""

    def __init__(
        self,
        device_id: str = "",
        device_name: str = "",
        last_snapshot_id: str | None = None,
        last_change_at: str | None = None,
        last_sync_at: str | None = None,
        last_result: dict | None = None,
    ) -> None:
        self.device_id = device_id
        self.device_name = device_name
        self.last_snapshot_id = last_snapshot_id
        self.last_change_at = last_change_at
        self.last_sync_at = last_sync_at
        self.last_result = last_result

    def ensure_identity(self) -> None:
        if not self.device_id:
            self.device_id = uuid.uuid4().hex
        if not self.device_name:
            self.device_name = socket.gethostname() or "This device"

    def as_dict(self) -> dict:
        return {
            "device_id": self.device_id,
            "device_name": self.device_name,
            "last_snapshot_id": self.last_snapshot_id,
            "last_change_at": self.last_change_at,
            "last_sync_at": self.last_sync_at,
            "last_result": self.last_result,
        }

    @classmethod
    def load(cls, path: Path) -> "SyncState":
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            return cls()
        return cls(
            device_id=str(data.get("device_id") or ""),
            device_name=str(data.get("device_name") or ""),
            last_snapshot_id=data.get("last_snapshot_id"),
            last_change_at=data.get("last_change_at"),
            last_sync_at=data.get("last_sync_at"),
            last_result=data.get("last_result"),
        )


def database_path() -> Path:
    """The SQLite file behind the shared engine."""
    from ..database import engine

    url = engine.url
    if url.get_backend_name() != "sqlite":
        raise SyncError(
            "Sharing a library needs the SQLite file backend; a hosted database "
            "should use the server mode instead."
        )
    if not url.database or url.database == ":memory:":
        raise SyncError("The library is not stored in a file, so it cannot be shared.")
    return Path(url.database).expanduser().resolve()


def state_path(db_path: Path) -> Path:
    return db_path.with_name(STATE_NAME)


def load_state(db_path: Path) -> SyncState:
    state = SyncState.load(state_path(db_path))
    state.ensure_identity()
    return state


def save_state(db_path: Path, state: SyncState) -> None:
    path = state_path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state.as_dict(), indent=2, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def _sync_settings_path(db_path: Path) -> Path:
    return db_path.with_name(SYNC_SETTINGS_NAME)


def stored_sync_file(db_path: Path) -> str:
    """The folder saved from the web admin page, if any."""
    try:
        data = json.loads(_sync_settings_path(db_path).read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError):
        return ""
    return str(data.get("sync_file") or "")


def set_sync_file(db_path: Path, value: str) -> None:
    path = _sync_settings_path(db_path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(
        json.dumps({"sync_file": (value or "").strip()}, indent=2), encoding="utf-8"
    )
    os.replace(tmp, path)


def configured_sync_file(db_path: Path | None = None) -> str:
    """What the settings screens should show in the path box."""
    if settings.sync_file:
        return settings.sync_file
    data_path = Path(db_path) if db_path is not None else database_path()
    return stored_sync_file(data_path)


def resolve_target(value: str | Path | None = None, *, db_path: Path | None = None) -> Path:
    """Turn the setting into the snapshot file to use.

    A path ending in something else than ``.sqlite``/``.db`` is treated as the
    shared folder — the normal case, since the user picks their Drive folder.
    """
    if value is not None and str(value).strip():
        raw = str(value)
    else:
        data_path = Path(db_path) if db_path is not None else database_path()
        raw = settings.sync_file or stored_sync_file(data_path)
    if not raw:
        raise SyncError("No shared library file is configured yet.")
    path = Path(raw).expanduser()
    if path.suffix.lower() in (".sqlite", ".db"):
        target = path
    else:
        target = path / SNAPSHOT_NAME
    if not target.parent.is_dir():
        raise SyncError(f"The shared folder does not exist: {target.parent}")
    return target


# --------------------------------------------------------------------------- #
# Snapshot files
# --------------------------------------------------------------------------- #
@contextmanager
def _sync_lock(db_path: Path, timeout: float = 15.0):
    """Serialize syncs that share one local database.

    Two processes on the same machine (the web app and the desktop app, for
    example) can otherwise read the same snapshot and replace it in turn. A
    lock file next to the database is enough; cross-device races are handled by
    the compare-and-swap in :func:`export_snapshot`.
    """
    lock_path = db_path.with_name(db_path.name + ".synclock")
    deadline = time.monotonic() + timeout
    handle: int | None = None
    while handle is None:
        try:
            handle = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(handle, str(os.getpid()).encode("ascii", "ignore"))
        except FileExistsError:
            try:
                age = time.time() - lock_path.stat().st_mtime
            except OSError:
                age = 0.0
            if age > 300:
                # A crashed process left its lock behind; break it.
                try:
                    lock_path.unlink()
                except OSError:
                    pass
                continue
            if time.monotonic() >= deadline:
                raise SyncError(
                    "Another sync is already running. Wait for it to finish and try again."
                )
            time.sleep(0.1)
    try:
        yield
    finally:
        if handle is not None:
            os.close(handle)
        try:
            lock_path.unlink()
        except OSError:
            pass


def _open_live(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(str(path), isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 15000")
    return connection


def _open_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def _vacuum_into(source: Path, target: Path) -> None:
    """Write a consistent copy of ``source`` to ``target``.

    Checkpointing first folds the WAL back into the main file; ``VACUUM INTO``
    then produces a single self-contained file with no ``-wal``/``-shm``
    companions — exactly what a file-syncing service needs.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    quoted = str(target).replace("'", "''")
    connection = sqlite3.connect(str(source))
    try:
        connection.execute("PRAGMA busy_timeout = 15000")
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.execute(f"VACUUM INTO '{quoted}'")
    finally:
        connection.close()


def _row_counts(connection: sqlite3.Connection) -> dict[str, int]:
    counts: dict[str, int] = {}
    for table in REQUIRED_TABLES:
        counts[table] = int(connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
    counts["sync_tombstones"] = int(
        connection.execute("SELECT COUNT(*) FROM sync_tombstones").fetchone()[0]
    )
    return counts


def export_snapshot(
    db_path: Path,
    target: Path,
    *,
    state: SyncState,
    based_on: str | None = None,
) -> SnapshotMeta:
    """Build the snapshot for ``target`` and replace it atomically."""
    state.ensure_identity()
    previous = _read_meta_quiet(target)
    generation = (previous.generation + 1) if previous else 1
    snapshot_id = uuid.uuid4().hex
    exported_at = stamp_now()

    # A unique temporary name keeps two processes from writing the same file
    # while they are preparing their snapshots.
    tmp = target.with_name(f"{target.name}.{uuid.uuid4().hex}.tmp")
    _vacuum_into(db_path, tmp)
    try:
        connection = sqlite3.connect(str(tmp))
        connection.row_factory = sqlite3.Row
        try:
            # A snapshot is a plain file: no journal left beside it in the
            # shared folder while the metadata is written.
            connection.execute("PRAGMA journal_mode = DELETE")
            connection.execute("DROP TABLE IF EXISTS users")
            connection.execute("DROP TABLE IF EXISTS tokens")
            connection.execute("DROP TABLE IF EXISTS sync_meta")
            # Objectives are per-device/per-account metadata: they never travel
            # through a cross-device merge, so a snapshot must not carry them.
            connection.execute("DROP TABLE IF EXISTS reading_goals")
            connection.execute(
                "CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
            )
            counts = _row_counts(connection)
            meta = {
                "format": str(FORMAT),
                "schema_version": "1",
                "snapshot_id": snapshot_id,
                "generation": str(generation),
                "exported_at": exported_at,
                "device_id": state.device_id,
                "device_name": state.device_name,
                "based_on": based_on or "",
                "row_counts": json.dumps(counts, sort_keys=True),
            }
            connection.executemany(
                "INSERT INTO sync_meta (key, value) VALUES (?, ?)", list(meta.items())
            )
            connection.commit()
            check = connection.execute("PRAGMA integrity_check").fetchone()[0]
            if check != "ok":
                raise SyncError("The snapshot copy did not pass its integrity check.")
        finally:
            connection.close()
        # Compare-and-swap: refuse to replace a snapshot that moved on while we
        # were merging. Without this, two devices that started from the same
        # generation silently overwrite each other and the last writer wins.
        if based_on and target.exists():
            current = _read_meta_quiet(target)
            if current is not None and current.snapshot_id != based_on:
                raise SyncError(
                    "The shared library changed on another device while syncing. "
                    "Please try again."
                )
        os.replace(tmp, target)
    finally:
        if tmp.exists():
            tmp.unlink()

    return SnapshotMeta(
        format=FORMAT,
        schema_version=1,
        snapshot_id=snapshot_id,
        generation=generation,
        exported_at=exported_at,
        device_id=state.device_id,
        device_name=state.device_name,
        based_on=based_on,
        row_counts=counts,
    )


def read_snapshot_meta(path: Path) -> SnapshotMeta:
    """Open just the header of a snapshot, refusing anything unusable."""
    if not path.exists():
        raise SyncError(f"The shared library file is missing: {path}")
    try:
        connection = _open_read_only(path)
    except (sqlite3.DatabaseError, sqlite3.OperationalError) as exc:
        raise SyncError("The shared library file is not a readable SQLite database.") from exc
    try:
        try:
            check = connection.execute("PRAGMA integrity_check").fetchone()[0]
        except sqlite3.DatabaseError as exc:
            raise SyncError(
                "The shared library file is damaged or is not a SQLite database."
            ) from exc
        if check != "ok":
            raise SyncError(
                "The shared library file is damaged or was only partly copied. "
                "Wait for the folder to finish syncing and try again."
            )
        tables = {
            row[0]
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        missing = [table for table in REQUIRED_TABLES if table not in tables]
        if missing:
            raise SyncError("The shared file is not a BiblioJules library.")
        if "sync_meta" not in tables:
            raise SyncError(
                "This file is a plain library export, not a sync snapshot. "
                "Choose a shared folder from the app and export a fresh snapshot."
            )
        raw = {
            row["key"]: row["value"]
            for row in connection.execute("SELECT key, value FROM sync_meta")
        }
    finally:
        connection.close()

    try:
        row_counts = json.loads(raw.get("row_counts") or "{}")
        meta = SnapshotMeta(
            format=int(raw.get("format", "0")),
            schema_version=int(raw.get("schema_version", "0")),
            snapshot_id=str(raw["snapshot_id"]),
            generation=int(raw.get("generation", "1")),
            exported_at=str(raw.get("exported_at", "")),
            device_id=str(raw.get("device_id", "")),
            device_name=str(raw.get("device_name", "")),
            based_on=raw.get("based_on") or None,
            row_counts={key: int(value) for key, value in row_counts.items()},
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise SyncError("The snapshot header is incomplete or damaged.") from exc

    if meta.format != FORMAT:
        raise SyncError(
            "This snapshot was written by a different version of BiblioJules. "
            "Update every device to the same version, then try again."
        )
    return meta


def _read_meta_quiet(path: Path) -> SnapshotMeta | None:
    try:
        return read_snapshot_meta(path)
    except SyncError:
        return None


def backup_database(db_path: Path) -> Path:
    """A timestamped local copy taken just before a merge; keeps the last 10."""
    folder = db_path.parent / BACKUP_FOLDER
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    target = folder / f"library-{stamp}.db"
    _vacuum_into(db_path, target)
    backups = sorted(folder.glob("library-*.db"))
    for old in backups[:-KEEP_BACKUPS]:
        old.unlink(missing_ok=True)
    return target


def local_change_stamp(db_path: Path) -> str | None:
    """The newest change timestamp anywhere in the local library."""
    connection = sqlite3.connect(str(db_path))
    try:
        values: list[str] = []
        for table in SYNCED_TABLES:
            row = connection.execute(f'SELECT MAX(updated_at) FROM "{table}"').fetchone()
            if row and row[0]:
                values.append(str(row[0]))
        row = connection.execute("SELECT MAX(deleted_at) FROM sync_tombstones").fetchone()
        if row and row[0]:
            values.append(str(row[0]))
    finally:
        connection.close()
    if not values:
        return None
    return max(values, key=_stamp)


# --------------------------------------------------------------------------- #
# Merge helpers
# --------------------------------------------------------------------------- #
def _rows(connection: sqlite3.Connection, table: str) -> list[dict]:
    return [dict(row) for row in connection.execute(f'SELECT * FROM "{table}"')]


def _by(rows: list[dict], key: str) -> dict:
    return {row[key]: row for row in rows if row.get(key)}


def _insert(connection: sqlite3.Connection, table: str, row: dict) -> int:
    columns = [name for name in row if name != "id"]
    placeholders = ", ".join("?" for _ in columns)
    names = ", ".join(f'"{name}"' for name in columns)
    cursor = connection.execute(
        f'INSERT INTO "{table}" ({names}) VALUES ({placeholders})',
        [row[name] for name in columns],
    )
    return int(cursor.lastrowid)


def _update(connection: sqlite3.Connection, table: str, row_id: int, values: dict) -> None:
    if not values:
        return
    assignments = ", ".join(f'"{name}" = ?' for name in values)
    connection.execute(
        f'UPDATE "{table}" SET {assignments} WHERE "id" = ?',
        [*values.values(), row_id],
    )


def _newer(remote: dict, local: dict) -> bool:
    """Last write wins; identical instants are settled by ``sync_id``."""
    left, right = _stamp(remote.get("updated_at")), _stamp(local.get("updated_at"))
    if left != right:
        return left > right
    return (remote.get("sync_id") or "") > (local.get("sync_id") or "")


def _loan_newer(remote: dict, local: dict) -> bool:
    """Like :func:`_newer`, but a returned loan wins an exact timestamp tie."""
    left, right = _stamp(remote.get("updated_at")), _stamp(local.get("updated_at"))
    if left != right:
        return left > right
    remote_returned = remote.get("returned_at") is not None
    local_returned = local.get("returned_at") is not None
    if remote_returned != local_returned:
        return remote_returned
    return (remote.get("sync_id") or "") > (local.get("sync_id") or "")


def _conflict(since: str | None, remote: dict, local: dict) -> bool:
    """A heuristic: both sides changed this row since our last successful sync.

    Without keeping a base snapshot there is no way to be certain, but a local
    row edited after the last sync whose remote twin also moved is exactly the
    case worth telling the user about.
    """
    if not since:
        return False
    boundary = _stamp(since)
    return _stamp(local.get("updated_at")) > boundary and _stamp(remote.get("updated_at")) > boundary


def _blocked_by_local_tombstone(
    connection: sqlite3.Connection, table: str, sync_id: str, remote_updated) -> bool:
    """True when this device deleted the row and the incoming copy is older.

    A newer incoming copy wins (the user edited it elsewhere) and the local
    tombstone is dropped, which is how an edit resurrects a deleted row.
    """
    row = connection.execute(
        "SELECT deleted_at FROM sync_tombstones WHERE table_name = ? AND sync_id = ?",
        (table, sync_id),
    ).fetchone()
    if row is None:
        return False
    if _stamp(row["deleted_at"]) >= _stamp(remote_updated):
        return True
    connection.execute(
        "DELETE FROM sync_tombstones WHERE table_name = ? AND sync_id = ?",
        (table, sync_id),
    )
    return False


def _adopt_sync_id(
    connection: sqlite3.Connection,
    table: str,
    local: dict,
    sync_id: str,
    by_sync: dict,
) -> None:
    """Give a locally-created row the incoming identity of its natural twin.

    The first sync marries rows that were created independently on two devices
    (both seeded statuses, both entered the same author). Keeping the local id
    would leave each device believing the other lacks the row, so every sync
    would rewrite the snapshot. Adopting the incoming ``sync_id`` makes the two
    rows the same row from then on.
    """
    previous = local.get("sync_id")
    connection.execute(
        f'UPDATE "{table}" SET sync_id = ? WHERE id = ?', (sync_id, local["id"])
    )
    if previous:
        by_sync.pop(previous, None)
    local["sync_id"] = sync_id


def _replace_authors(
    connection: sqlite3.Connection,
    book_id: int,
    author_sync_ids: list[str],
    author_map: dict[str, int],
) -> None:
    connection.execute("DELETE FROM book_authors WHERE book_id = ?", (book_id,))
    seen: set[int] = set()
    for sync_id in author_sync_ids:
        author_id = author_map.get(sync_id)
        if author_id is None or author_id in seen:
            continue
        seen.add(author_id)
        connection.execute(
            "INSERT OR IGNORE INTO book_authors (book_id, author_id) VALUES (?, ?)",
            (book_id, author_id),
        )


def _location_depth(rows_by_id: dict, row: dict) -> int:
    depth = 0
    seen: set = set()
    parent = row.get("parent_id")
    while parent is not None and parent in rows_by_id and parent not in seen:
        seen.add(parent)
        depth += 1
        parent = rows_by_id[parent].get("parent_id")
    return depth


def _sort_locations(rows: list[dict]) -> list[dict]:
    """Parents before children, so a shelf can be inserted in one pass."""
    rows_by_id = {row["id"]: row for row in rows}
    return sorted(rows, key=lambda row: (_location_depth(rows_by_id, row), row["id"]))


def _remember_remote_tombstone(
    connection: sqlite3.Connection, table: str, tombstone: dict
) -> None:
    """Keep a remote deletion locally so it keeps travelling to other devices.

    Applying a deletion used to be a one-way operation: the row disappeared but
    no local tombstone was written, so the next export dropped the deletion
    marker and an offline device could push the row back.
    """
    existing = connection.execute(
        "SELECT deleted_at FROM sync_tombstones WHERE table_name = ? AND sync_id = ?",
        (table, tombstone["sync_id"]),
    ).fetchone()
    if existing is None:
        connection.execute(
            "INSERT INTO sync_tombstones (table_name, sync_id, deleted_at) VALUES (?, ?, ?)",
            (table, tombstone["sync_id"], tombstone["deleted_at"]),
        )
    elif _stamp(tombstone["deleted_at"]) > _stamp(existing["deleted_at"]):
        connection.execute(
            "UPDATE sync_tombstones SET deleted_at = ? WHERE table_name = ? AND sync_id = ?",
            (tombstone["deleted_at"], table, tombstone["sync_id"]),
        )


def _apply_remote_tombstones(
    connection: sqlite3.Connection, remote: sqlite3.Connection, summary: MergeSummary
) -> None:
    """Deletions made on the other device, applied only where they still win."""
    tombstones = _rows(remote, "sync_tombstones")
    if not tombstones:
        return
    by_table: dict[str, list[dict]] = {}
    for row in tombstones:
        by_table.setdefault(row["table_name"], []).append(row)

    for tombstone in by_table.get("statuses", []):
        local = connection.execute(
            "SELECT * FROM statuses WHERE sync_id = ?", (tombstone["sync_id"],)
        ).fetchone()
        if local is None or _stamp(tombstone["deleted_at"]) < _stamp(local["updated_at"]):
            continue
        fallback = connection.execute(
            "SELECT id FROM statuses WHERE slug = 'available'"
        ).fetchone()
        connection.execute(
            "UPDATE books SET status_id = ? WHERE status_id = ?",
            (fallback["id"] if fallback else None, local["id"]),
        )
        connection.execute("DELETE FROM statuses WHERE id = ?", (local["id"],))
        _remember_remote_tombstone(connection, "statuses", tombstone)
        summary.bump(summary.deleted, "statuses")

    for tombstone in by_table.get("books", []):
        local = connection.execute(
            "SELECT * FROM books WHERE sync_id = ?", (tombstone["sync_id"],)
        ).fetchone()
        if local is None or _stamp(tombstone["deleted_at"]) < _stamp(local["updated_at"]):
            continue
        connection.execute("DELETE FROM books WHERE id = ?", (local["id"],))
        _remember_remote_tombstone(connection, "books", tombstone)
        summary.bump(summary.deleted, "books")

    locations = by_table.get("locations", [])
    if locations:
        local_rows = _rows(connection, "locations")
        rows_by_id = {row["id"]: row for row in local_rows}
        local_by_sync = _by(local_rows, "sync_id")

        def depth_of(tombstone: dict) -> int:
            local = local_by_sync.get(tombstone["sync_id"])
            return _location_depth(rows_by_id, local) if local else -1

        # Children first: deleting a parent cascades, so a child that survived
        # on this device has to be moved out of the way before its shelf goes.
        for tombstone in sorted(locations, key=depth_of, reverse=True):
            local = local_by_sync.get(tombstone["sync_id"])
            if local is None or _stamp(tombstone["deleted_at"]) < _stamp(local["updated_at"]):
                continue
            connection.execute(
                "UPDATE locations SET parent_id = ? WHERE parent_id = ?",
                (local["parent_id"], local["id"]),
            )
            connection.execute("DELETE FROM locations WHERE id = ?", (local["id"],))
            _remember_remote_tombstone(connection, "locations", tombstone)
            summary.bump(summary.deleted, "locations")


def _merge_statuses(
    connection: sqlite3.Connection,
    remote_rows: list[dict],
    summary: MergeSummary,
    since: str | None,
) -> dict[str, int]:
    """Merge by ``sync_id``, then by slug/name so the seeded rows unify."""
    local_rows = _rows(connection, "statuses")
    by_sync = _by(local_rows, "sync_id")
    by_slug = {row["slug"]: row for row in local_rows if row.get("slug")}
    by_name = {(row["name"] or "").casefold(): row for row in local_rows if row.get("name")}
    mapping: dict[str, int] = {}

    for remote in remote_rows:
        sync_id = remote.get("sync_id")
        if not sync_id:
            continue
        if _blocked_by_local_tombstone(connection, "statuses", sync_id, remote.get("updated_at")):
            continue
        local = by_sync.get(sync_id) or by_slug.get(remote.get("slug"))
        if local is None:
            local = by_name.get((remote.get("name") or "").casefold())
        if local is None:
            values = {name: remote.get(name) for name in (*STATUS_FIELDS, "sync_id", "created_at", "updated_at")}
            new_id = _insert(connection, "statuses", values)
            inserted = dict(values, id=new_id)
            by_sync[sync_id] = inserted
            by_slug[inserted["slug"]] = inserted
            by_name[(inserted["name"] or "").casefold()] = inserted
            mapping[sync_id] = new_id
            summary.bump(summary.added, "statuses")
            continue

        mapping[sync_id] = local["id"]
        if local.get("sync_id") != sync_id:
            _adopt_sync_id(connection, "statuses", local, sync_id, by_sync)
        by_sync[sync_id] = local
        if _newer(remote, local):
            # Adopt the winner's timestamp too, so the next device to merge
            # sees one consistent version rather than two timestamps.
            values = {name: remote.get(name) for name in STATUS_FIELDS if remote.get(name) != local.get(name)}
            values["updated_at"] = remote.get("updated_at")
            _update(connection, "statuses", local["id"], values)
            if _conflict(since, remote, local):
                summary.conflicts.append(
                    f"status “{local['name']}”: kept the version from {summary.source_device}"
                )
            local.update(values)
            summary.bump(summary.updated, "statuses")
    return mapping


def _merge_locations(
    connection: sqlite3.Connection,
    remote_rows: list[dict],
    summary: MergeSummary,
    since: str | None,
) -> dict[str, int]:
    """Shelf trees merge by ``sync_id`` alone — two shelves may share a name."""
    local_rows = _rows(connection, "locations")
    by_sync = _by(local_rows, "sync_id")
    remote_sync_by_id = {row["id"]: row["sync_id"] for row in remote_rows}
    ordered = _sort_locations(remote_rows)
    mapping: dict[str, int] = {}
    remote_won: set[str] = set()

    for remote in ordered:
        sync_id = remote.get("sync_id")
        if not sync_id:
            continue
        if _blocked_by_local_tombstone(connection, "locations", sync_id, remote.get("updated_at")):
            continue
        local = by_sync.get(sync_id)
        if local is None:
            values = {name: remote.get(name) for name in (*LOCATION_FIELDS, "sync_id", "created_at", "updated_at")}
            values["parent_id"] = None
            new_id = _insert(connection, "locations", values)
            inserted = dict(values, id=new_id)
            by_sync[sync_id] = inserted
            mapping[sync_id] = new_id
            remote_won.add(sync_id)
            summary.bump(summary.added, "locations")
            continue

        mapping[sync_id] = local["id"]
        if _newer(remote, local):
            values = {name: remote.get(name) for name in LOCATION_FIELDS if remote.get(name) != local.get(name)}
            values["updated_at"] = remote.get("updated_at")
            _update(connection, "locations", local["id"], values)
            if _conflict(since, remote, local):
                summary.conflicts.append(
                    f"shelf “{local['name']}”: kept the version from {summary.source_device}"
                )
            local.update(values)
            summary.bump(summary.updated, "locations")
            remote_won.add(sync_id)

    # Parents in a second pass: every row now has a local id to point at.
    for remote in ordered:
        sync_id = remote.get("sync_id")
        if sync_id not in mapping or sync_id not in remote_won:
            continue
        parent_sync = remote_sync_by_id.get(remote.get("parent_id"))
        parent_id = mapping.get(parent_sync) if parent_sync else None
        if parent_id == mapping[sync_id]:
            parent_id = None
        connection.execute(
            "UPDATE locations SET parent_id = ? WHERE id = ?", (parent_id, mapping[sync_id])
        )
    return mapping


def _merge_names(
    connection: sqlite3.Connection,
    table: str,
    remote_rows: list[dict],
    summary: MergeSummary,
    since: str | None,
) -> dict[str, int]:
    """Authors and publishers, unified by name the first time they meet."""
    local_rows = _rows(connection, table)
    by_sync = _by(local_rows, "sync_id")
    by_name = {(row.get("name") or "").casefold(): row for row in local_rows if row.get("name")}
    mapping: dict[str, int] = {}

    for remote in remote_rows:
        sync_id = remote.get("sync_id")
        if not sync_id:
            continue
        if _blocked_by_local_tombstone(connection, table, sync_id, remote.get("updated_at")):
            continue
        name = remote.get("name") or ""
        local = by_sync.get(sync_id) or by_name.get(name.casefold())
        if local is None:
            values = {"name": name, "sync_id": sync_id, "updated_at": remote.get("updated_at") or stamp_now()}
            new_id = _insert(connection, table, values)
            inserted = dict(values, id=new_id)
            by_sync[sync_id] = inserted
            by_name[name.casefold()] = inserted
            mapping[sync_id] = new_id
            summary.bump(summary.added, table)
            continue

        mapping[sync_id] = local["id"]
        if local.get("sync_id") != sync_id:
            _adopt_sync_id(connection, table, local, sync_id, by_sync)
        by_sync[sync_id] = local
        if _newer(remote, local):
            values = {"updated_at": remote.get("updated_at")}
            if name and name.casefold() != (local.get("name") or "").casefold():
                values["name"] = name
            _update(connection, table, local["id"], values)
            local.update(values)
            summary.bump(summary.updated, table)
    return mapping


def _merge_books(
    connection: sqlite3.Connection,
    remote: sqlite3.Connection,
    remote_rows: list[dict],
    maps: tuple[dict[str, int], dict[str, int], dict[str, int], dict[str, int]],
    summary: MergeSummary,
    since: str | None,
) -> dict[str, int]:
    status_map, location_map, publisher_map, author_map = maps
    publisher_sync = {row["id"]: row["sync_id"] for row in _rows(remote, "publishers")}
    location_sync = {row["id"]: row["sync_id"] for row in _rows(remote, "locations")}
    status_sync = {row["id"]: row["sync_id"] for row in _rows(remote, "statuses")}
    author_sync = {row["id"]: row["sync_id"] for row in _rows(remote, "authors")}
    authors_by_book: dict[int, list[str]] = {}
    for link in _rows(remote, "book_authors"):
        sync_id = author_sync.get(link["author_id"])
        if sync_id:
            authors_by_book.setdefault(link["book_id"], []).append(sync_id)

    local_rows = _rows(connection, "books")
    by_sync = _by(local_rows, "sync_id")
    by_isbn = {row["isbn"]: row for row in local_rows if row.get("isbn")}
    mapping: dict[str, int] = {}

    for remote_row in remote_rows:
        sync_id = remote_row.get("sync_id")
        if not sync_id:
            continue
        if _blocked_by_local_tombstone(connection, "books", sync_id, remote_row.get("updated_at")):
            continue

        matched_by_isbn = False
        local = by_sync.get(sync_id)
        if local is None and remote_row.get("isbn"):
            local = by_isbn.get(remote_row["isbn"])
            matched_by_isbn = local is not None

        values = {name: remote_row.get(name) for name in BOOK_FIELDS}
        values["publisher_id"] = publisher_map.get(publisher_sync.get(remote_row.get("publisher_id")))
        values["location_id"] = location_map.get(location_sync.get(remote_row.get("location_id")))
        values["status_id"] = status_map.get(status_sync.get(remote_row.get("status_id")))
        values["updated_at"] = remote_row.get("updated_at") or stamp_now()

        if local is None:
            values["sync_id"] = sync_id
            values["created_at"] = remote_row.get("created_at")
            try:
                new_id = _insert(connection, "books", values)
            except sqlite3.IntegrityError as exc:
                # A duplicate ISBN must not abort the whole merge. Import the
                # book without the ISBN and report the clash instead.
                if values.get("isbn") and "books.isbn" in str(exc):
                    summary.conflicts.append(
                        f"book “{values.get('title')}”: ISBN {values['isbn']} "
                        "is already used by another book"
                    )
                    values["isbn"] = None
                    new_id = _insert(connection, "books", values)
                else:
                    raise
            inserted = dict(values, id=new_id)
            by_sync[sync_id] = inserted
            if inserted.get("isbn"):
                by_isbn[inserted["isbn"]] = inserted
            mapping[sync_id] = new_id
            _replace_authors(connection, new_id, authors_by_book.get(remote_row["id"], []), author_map)
            summary.bump(summary.added, "books")
            continue

        mapping[sync_id] = local["id"]
        if local.get("sync_id") != sync_id:
            _adopt_sync_id(connection, "books", local, sync_id, by_sync)
            if matched_by_isbn:
                summary.conflicts.append(
                    f"book “{local.get('title')}”: the same ISBN exists on both devices"
                )
        by_sync[sync_id] = local
        if _newer(remote_row, local):
            changed = {name: value for name, value in values.items() if value != local.get(name)}
            if "isbn" in changed and changed["isbn"]:
                owner = by_isbn.get(changed["isbn"])
                if owner is not None and owner["id"] != local["id"]:
                    # The incoming ISBN belongs to a different local book.
                    # Keep the old ISBN instead of aborting the merge on the
                    # unique index, and tell the user about the clash.
                    changed.pop("isbn")
                    summary.conflicts.append(
                        f"book “{local.get('title')}”: ISBN {values['isbn']} "
                        "is already used by another book"
                    )
            if changed:
                previous_isbn = local.get("isbn")
                _update(connection, "books", local["id"], changed)
                if _conflict(since, remote_row, local):
                    summary.conflicts.append(
                        f"book “{local.get('title')}”: kept the version from {summary.source_device}"
                    )
                local.update(changed)
                # Keep the ISBN lookup in step with the row, otherwise a later
                # remote row carrying the old ISBN matches the wrong book.
                if "isbn" in changed:
                    if previous_isbn:
                        by_isbn.pop(previous_isbn, None)
                    if changed["isbn"]:
                        by_isbn[changed["isbn"]] = local
                summary.bump(summary.updated, "books")
            # The author set travels with the winning book row.
            _replace_authors(connection, local["id"], authors_by_book.get(remote_row["id"], []), author_map)
    return mapping


def _merge_loans(
    connection: sqlite3.Connection,
    remote: sqlite3.Connection,
    remote_rows: list[dict],
    book_map: dict[str, int],
    summary: MergeSummary,
) -> None:
    book_sync = {row["id"]: row["sync_id"] for row in _rows(remote, "books")}
    local_rows = _rows(connection, "loans")
    by_sync = _by(local_rows, "sync_id")

    for remote_row in remote_rows:
        sync_id = remote_row.get("sync_id")
        if not sync_id:
            continue
        remote_book_sync = book_sync.get(remote_row.get("book_id"))
        book_id = book_map.get(remote_book_sync) if remote_book_sync else None
        if book_id is None:
            # The book was deleted on this device; the loan goes with it.
            continue

        values = {name: remote_row.get(name) for name in LOAN_FIELDS}
        values["book_id"] = book_id
        values["updated_at"] = remote_row.get("updated_at") or stamp_now()
        local = by_sync.get(sync_id)
        if local is None:
            values["sync_id"] = sync_id
            values["created_at"] = remote_row.get("created_at")
            new_id = _insert(connection, "loans", values)
            by_sync[sync_id] = dict(values, id=new_id)
            summary.bump(summary.added, "loans")
            continue
        if _loan_newer(remote_row, local):
            changed = {name: value for name, value in values.items() if value != local.get(name)}
            if changed:
                _update(connection, "loans", local["id"], changed)
                local.update(changed)
                summary.bump(summary.updated, "loans")


def _merge_all(
    connection: sqlite3.Connection,
    remote: sqlite3.Connection,
    summary: MergeSummary,
    since: str | None,
) -> None:
    _apply_remote_tombstones(connection, remote, summary)
    status_map = _merge_statuses(connection, _rows(remote, "statuses"), summary, since)
    location_map = _merge_locations(connection, _rows(remote, "locations"), summary, since)
    publisher_map = _merge_names(connection, "publishers", _rows(remote, "publishers"), summary, since)
    author_map = _merge_names(connection, "authors", _rows(remote, "authors"), summary, since)
    book_map = _merge_books(
        connection,
        remote,
        _rows(remote, "books"),
        (status_map, location_map, publisher_map, author_map),
        summary,
        since,
    )
    _merge_loans(connection, remote, _rows(remote, "loans"), book_map, summary)
    pruned = _prune_orphans(connection)
    # A snapshot can carry a name whose only book was deleted on the other
    # device. Recording it as "added" and then dropping it again would make the
    # summary lie, so take those rows back out of the tally.
    for table, removed in pruned.items():
        for bucket in (summary.added, summary.updated):
            if bucket.get(table):
                bucket[table] = max(0, bucket[table] - removed)
                if not bucket[table]:
                    del bucket[table]


def _prune_orphans(connection: sqlite3.Connection) -> dict[str, int]:
    """Drop authors/publishers whose last book disappeared in this merge.

    Unlike a user delete this needs no tombstone: an author that comes back in
    a later snapshot is simply inserted again, and deleting the rows here keeps
    the dashboard counts and filter lists honest.
    """
    removed: dict[str, int] = {}
    for table, sql in (
        ("authors", "DELETE FROM authors WHERE id NOT IN (SELECT author_id FROM book_authors)"),
        (
            "publishers",
            "DELETE FROM publishers WHERE id NOT IN "
            "(SELECT publisher_id FROM books WHERE publisher_id IS NOT NULL)",
        ),
    ):
        before = connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        connection.execute(sql)
        after = connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        removed[table] = int(before - after)
    return removed


def merge_snapshot(db_path: Path, snapshot_path: Path, *, since: str | None = None) -> MergeSummary:
    """Merge one snapshot into the live library, all-or-nothing."""
    meta = read_snapshot_meta(snapshot_path)
    summary = MergeSummary(source_device=meta.device_name, source_generation=meta.generation)
    live = _open_live(db_path)
    remote = _open_read_only(snapshot_path)
    try:
        try:
            live.execute("BEGIN IMMEDIATE")
        except sqlite3.OperationalError as exc:
            if "locked" in str(exc).lower() or "busy" in str(exc).lower():
                raise SyncError(
                    "The library is busy (another app is saving changes). "
                    "Wait a moment and sync again."
                ) from exc
            raise
        try:
            _merge_all(live, remote, summary, since)
            problems = live.execute("PRAGMA foreign_key_check").fetchall()
            if problems:
                raise SyncError(
                    "The merged library failed its consistency check, so nothing was changed."
                )
            live.execute("COMMIT")
        except BaseException:
            try:
                live.execute("ROLLBACK")
            except sqlite3.Error:
                pass
            raise
    finally:
        remote.close()
        live.close()
    return summary


# --------------------------------------------------------------------------- #
# Putting it together
# --------------------------------------------------------------------------- #
MAX_MERGE_ATTEMPTS = 3


def _sync_ids_with_stamps(connection: sqlite3.Connection) -> dict[str, dict[str, str]]:
    table: dict[str, dict[str, str]] = {}
    for name in SYNCED_TABLES:
        rows = connection.execute(
            f'SELECT sync_id, updated_at FROM "{name}" WHERE sync_id IS NOT NULL'
        ).fetchall()
        table[name] = {row["sync_id"]: str(row["updated_at"] or "") for row in rows}
    rows = connection.execute(
        "SELECT table_name, sync_id, deleted_at FROM sync_tombstones"
    ).fetchall()
    table["tombstones"] = {f'{row["table_name"]}/{row["sync_id"]}': str(row["deleted_at"] or "") for row in rows}
    return table


def needs_push(db_path: Path, snapshot_path: Path) -> bool:
    """True when the snapshot does not already contain everything we have.

    This is the check that stops two devices from bouncing an unchanged
    snapshot back and forth: after a merge we only write the file again when
    some local row is absent from (or newer than) its copy in the snapshot.
    """
    live = sqlite3.connect(str(db_path))
    live.row_factory = sqlite3.Row
    remote = _open_read_only(snapshot_path)
    try:
        local_rows = _sync_ids_with_stamps(live)
        remote_rows = _sync_ids_with_stamps(remote)
    finally:
        live.close()
        remote.close()

    for table, rows in local_rows.items():
        remote_table = remote_rows.get(table, {})
        for sync_id, stamp in rows.items():
            other = remote_table.get(sync_id)
            if other is None or _stamp(stamp) > _stamp(other):
                return True
    return False


def _combine(summary: MergeSummary | None, part: MergeSummary) -> MergeSummary:
    if summary is None:
        return part
    for bucket in ("added", "updated", "deleted"):
        into = getattr(summary, bucket)
        for table, count in getattr(part, bucket).items():
            summary.bump(into, table, count)
    summary.conflicts.extend(part.conflicts)
    summary.source_device = part.source_device or summary.source_device
    summary.source_generation = part.source_generation or summary.source_generation
    return summary


def _sync_now_impl(
    target: str | Path | None = None,
    *,
    db_path: Path | None = None,
    device_name: str | None = None,
    force: bool = False,
) -> SyncResult:
    """Merge the shared snapshot into this library, then publish the result."""
    db_path = Path(db_path) if db_path is not None else database_path()
    path = resolve_target(target, db_path=db_path)
    state = load_state(db_path)
    if device_name:
        state.device_name = device_name

    if not path.exists():
        meta = export_snapshot(db_path, path, state=state)
        state.last_snapshot_id = meta.snapshot_id
        state.last_change_at = local_change_stamp(db_path)
        state.last_sync_at = stamp_now()
        state.last_result = SyncResult(meta, None, pushed=True).as_dict()
        save_state(db_path, state)
        return SyncResult(snapshot=meta, pushed=True)

    summary: MergeSummary | None = None
    merged_snapshot = False
    merged_ids: set[str] = set()
    attempts = 0
    while attempts < MAX_MERGE_ATTEMPTS:
        remote = read_snapshot_meta(path)
        if remote.snapshot_id == state.last_snapshot_id or remote.snapshot_id in merged_ids:
            break
        backup_database(db_path)
        part = merge_snapshot(db_path, path, since=state.last_sync_at)
        summary = _combine(summary, part)
        merged_ids.add(remote.snapshot_id)
        state.last_snapshot_id = remote.snapshot_id
        state.last_sync_at = stamp_now()
        merged_snapshot = True
        attempts += 1
        try:
            latest = read_snapshot_meta(path)
        except SyncError:
            break
        if latest.snapshot_id == remote.snapshot_id:
            # The folder settled: no need to go around again.
            break

    # If the folder moved on after our last merge, we never saw the newest
    # snapshot. Publishing now would overwrite changes we did not merge, so
    # stop and ask the user to retry instead.
    try:
        latest_meta = read_snapshot_meta(path)
    except SyncError:
        latest_meta = None
    if latest_meta is not None and latest_meta.snapshot_id != state.last_snapshot_id:
        raise SyncError("The shared library kept changing while syncing. Please try again.")

    # Only write the file again when the snapshot lacks something we have;
    # otherwise two devices would bounce an unchanged snapshot back and forth.
    pushed = force or needs_push(db_path, path)

    if pushed:
        meta = export_snapshot(db_path, path, state=state, based_on=state.last_snapshot_id)
        state.last_snapshot_id = meta.snapshot_id
    else:
        meta = read_snapshot_meta(path)

    state.last_change_at = local_change_stamp(db_path)
    state.last_sync_at = stamp_now()
    state.last_result = SyncResult(meta, summary, pushed, merged_snapshot).as_dict()
    save_state(db_path, state)
    return SyncResult(snapshot=meta, merge=summary, pushed=pushed, merged_snapshot=merged_snapshot)


def sync_now(
    target: str | Path | None = None,
    *,
    db_path: Path | None = None,
    device_name: str | None = None,
    force: bool = False,
) -> SyncResult:
    """Merge the shared snapshot into this library, then publish the result.

    The local lock keeps the web app and the desktop app from merging the same
    snapshot at the same time; the compare-and-swap in ``export_snapshot``
    handles the same race between devices.
    """
    resolved = Path(db_path) if db_path is not None else database_path()
    with _sync_lock(resolved):
        return _sync_now_impl(
            target,
            db_path=resolved,
            device_name=device_name,
            force=force,
        )


def sync_status(target: str | Path | None = None, *, db_path: Path | None = None) -> dict:
    """What the settings screens show without touching anything."""
    db_path = Path(db_path) if db_path is not None else database_path()
    try:
        path = resolve_target(target, db_path=db_path)
    except SyncError as exc:
        return {"configured": False, "error": str(exc)}
    state = load_state(db_path)
    status: dict = {
        "configured": True,
        "file": str(path),
        "exists": path.exists(),
        "device_id": state.device_id,
        "device_name": state.device_name,
        "last_snapshot_id": state.last_snapshot_id,
        "last_sync_at": state.last_sync_at,
        "last_result": state.last_result,
    }
    if path.exists():
        try:
            meta = read_snapshot_meta(path)
            status["snapshot"] = meta.as_dict()
        except SyncError as exc:
            status["error"] = str(exc)
    return status
