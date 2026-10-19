"""Columns shared by the rows that travel between devices.

The sync feature (see ``app/services/sync.py``) merges whole libraries, so every
row needs two things the rest of the app does not care about:

* a ``sync_id`` that identifies the *same* book/author/location on every device —
  the integer primary key is local and differs everywhere;
* an ``updated_at`` so a merge can tell which side of a conflict is newer.

Both are nullable on purpose. Existing databases are upgraded in place by
``app.database.ensure_sync_schema``, which adds the columns and backfills them;
making them ``NOT NULL`` would make that upgrade impossible without a table
rebuild.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column


def new_sync_id() -> str:
    """A fresh row identifier (32 hex characters, no dashes)."""
    return uuid.uuid4().hex


def utc_now() -> datetime:
    """The timestamp a row being written right now should carry."""
    return datetime.now(timezone.utc)


class SyncIdMixin:
    """A stable identifier that survives being merged into another database."""

    sync_id: Mapped[str | None] = mapped_column(
        String(32), unique=True, index=True, default=new_sync_id
    )


class UpdatedAtMixin:
    """When this row last changed — the tie-breaker a merge reads.

    Nullable for the same reason as :class:`SyncIdMixin`: SQLite cannot add a
    NOT NULL column to an existing table, so ``ensure_sync_schema`` adds it
    empty and backfills every row. Normal inserts always fill it in.
    """

    updated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )
