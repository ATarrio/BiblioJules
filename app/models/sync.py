"""Deletions, remembered long enough to reach the other devices.

A merge cannot tell "this row was deleted here" from "this row has not arrived
yet" by looking at the data alone, so every user-facing delete also records a
tombstone. Tombstones travel in the snapshot; a row is only skipped if the
tombstone is newer than the row's own ``updated_at`` (newest change wins, as
chosen), and a tombstone is dropped when a newer edit resurrects the row.

Writers live in ``app/services/tombstones.py``. Deletion through
``prune_orphans`` deliberately does *not* record one: it is garbage collection,
and an author may legitimately come back if another device's living book still
references it.

``deleted_at`` is all a merge needs — ties are broken by ``sync_id`` — so no
device identifier is stored here.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column

from ..database import Base
from .common import utc_now

#: The tables whose deletions are recorded. ``book_authors`` is absent on
#: purpose: a book's author set is carried by the book row itself.
TOMBSTONE_TABLES = ("books", "statuses", "locations")


class SyncTombstone(Base):
    __tablename__ = "sync_tombstones"

    table_name: Mapped[str] = mapped_column(String(40), primary_key=True)
    sync_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    deleted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now
    )

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<SyncTombstone {self.table_name}/{self.sync_id}>"
