"""Recording deletions so they can reach the other devices.

A merge sees two databases; a row missing from one could have been deleted there
or simply never created. The only way to tell is to keep a note when a
user-facing delete happens, and let that note travel in the snapshot. See
``app/models/sync.py`` for how the merge reads them.

Only the tables with a delete button record tombstones. Loans disappear with
their book (the book's tombstone is enough), and ``prune_orphans`` is garbage
collection rather than a user delete, so it stays silent.
"""

from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from ..models import SyncTombstone


def record(
    db: Session,
    table_name: str,
    sync_id: str | None,
    *,
    deleted_at: datetime | None = None,
) -> None:
    """Remember that the row ``table_name``/``sync_id`` was deleted here."""
    if not sync_id:
        # A row from before sync ids were backfilled: nothing can match it
        # across devices anyway, so a tombstone would be meaningless.
        return
    stamp = deleted_at or datetime.now(timezone.utc)
    existing = db.get(SyncTombstone, (table_name, sync_id))
    if existing is None:
        db.add(SyncTombstone(table_name=table_name, sync_id=sync_id, deleted_at=stamp))
    else:
        existing.deleted_at = stamp


def record_many(
    db: Session,
    table_name: str,
    sync_ids: Iterable[str | None],
    *,
    deleted_at: datetime | None = None,
) -> None:
    """Remember a batch of deletions — a location and its whole subtree."""
    for sync_id in sync_ids:
        record(db, table_name, sync_id, deleted_at=deleted_at)
