"""Deletions that travel in a snapshot must not dangle foreign keys.

``_apply_remote_tombstones`` applies remote deletions with raw SQLite DELETEs,
bypassing SQLAlchemy's FK cascades: a deleted book leaves its loans and author
links behind, and a deleted location leaves the books shelved on it. The
dangling rows then make the ``PRAGMA foreign_key_check`` at the end of
:func:`app.services.sync.merge_snapshot` raise and roll the whole merge back,
poisoning every later sync on that device.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app import models
from app.database import Base
from app.services.seed import seed_defaults
from app.services.sync import (
    SNAPSHOT_NAME,
    SyncError,
    SyncState,
    export_snapshot,
    merge_snapshot,
)

#: Sync ids shaped like the ones the apps mint (32 hex digits).
AUTHOR_ID = "00000000000000000000000000000001"
ROOM_ID = "00000000000000000000000000000002"
CASE_ID = "00000000000000000000000000000005"
BOOK_ONE = "00000000000000000000000000000003"
LOAN_ONE = "00000000000000000000000000000004"
BOOK_TWO = "00000000000000000000000000000006"

#: Old timestamps so a tombstone written "now" always wins the race.
OLD = datetime(2025, 1, 1, tzinfo=timezone.utc)


def _new_library(tmp_path, name: str):
    """A device's own SQLite library, with the full application schema."""
    path = tmp_path / name
    engine = create_engine(f"sqlite:///{path}")
    Base.metadata.create_all(bind=engine)
    session = sessionmaker(bind=engine, expire_on_commit=False)()
    return session, path


def _populate(session) -> None:
    """The same catalogue on both devices: a book with a loan and an author,
    a second book shelved on a bookcase under a room.
    """
    seed_defaults(session)
    session.commit()
    available = session.query(models.Status).filter(
        models.Status.slug == "available"
    ).one()

    author = models.Author(name="Ursula K. Le Guin", sync_id=AUTHOR_ID, updated_at=OLD)
    room = models.Location(
        name="Living room", kind="room", sync_id=ROOM_ID, updated_at=OLD
    )
    session.add(author)
    session.add(room)
    session.commit()

    bookcase = models.Location(
        name="South bookcase",
        kind="bookcase",
        parent_id=room.id,
        sync_id=CASE_ID,
        updated_at=OLD,
    )
    session.add(bookcase)
    session.commit()

    book = models.Book(
        title="A Wizard of Earthsea",
        isbn="9780595554784",
        sync_id=BOOK_ONE,
        updated_at=OLD,
        status_id=available.id,
        location_id=room.id,
        authors=[author],
    )
    other = models.Book(
        title="The Left Hand of Darkness",
        isbn="9780306406157",
        sync_id=BOOK_TWO,
        updated_at=OLD,
        status_id=available.id,
        location_id=bookcase.id,
    )
    session.add(book)
    session.add(other)
    session.commit()

    loan = models.Loan(
        book_id=book.id,
        borrower_name="Neighbour",
        sync_id=LOAN_ONE,
        updated_at=OLD,
    )
    session.add(loan)
    session.commit()


def _delete_on_device_a(path):
    """Simulate what the app does when a user deletes a book and a shelf.

    The device's own rows go away together with their local dependents (the
    SQLAlchemy cascades), and a tombstone is recorded for each user-facing
    delete so the deletion can travel to the other device.
    """
    deleted_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    connection = sqlite3.connect(str(path))
    try:
        book_id = connection.execute(
            "SELECT id FROM books WHERE sync_id = ?", (BOOK_ONE,)
        ).fetchone()[0]
        location_id = connection.execute(
            "SELECT id FROM locations WHERE sync_id = ?", (CASE_ID,)
        ).fetchone()[0]
        connection.execute("DELETE FROM loans WHERE book_id = ?", (book_id,))
        connection.execute("DELETE FROM book_authors WHERE book_id = ?", (book_id,))
        connection.execute("DELETE FROM books WHERE id = ?", (book_id,))
        connection.execute(
            "UPDATE books SET location_id = NULL WHERE location_id = ?", (location_id,)
        )
        connection.execute("DELETE FROM locations WHERE id = ?", (location_id,))
        for table, sync_id in (("books", BOOK_ONE), ("locations", CASE_ID)):
            connection.execute(
                "INSERT INTO sync_tombstones (table_name, sync_id, deleted_at)"
                " VALUES (?, ?, ?)",
                (table, sync_id, deleted_at),
            )
        connection.commit()
    finally:
        connection.close()


def test_deletions_survive_the_merge(tmp_path):
    """A snapshot carrying deletions must merge cleanly, not abort."""
    session_a, path_a = _new_library(tmp_path, "a.sqlite")
    session_b, path_b = _new_library(tmp_path, "b.sqlite")
    _populate(session_a)
    _populate(session_b)
    session_a.close()
    session_b.close()

    _delete_on_device_a(path_a)

    shared = tmp_path / "shared"
    shared.mkdir()
    snapshot = shared / SNAPSHOT_NAME
    export_snapshot(
        path_a,
        snapshot,
        state=SyncState(device_id="device-a", device_name="Device A"),
    )

    try:
        merge_snapshot(path_b, snapshot)
    except SyncError as exc:
        # The bug this test guards against: the tombstone DELETE left loans,
        # author links or shelved books dangling, and the final foreign-key
        # check aborted the whole merge.
        pytest.fail(f"merge aborted (dangling foreign keys): {exc}")

    live = sqlite3.connect(str(path_b))
    try:
        assert (
            live.execute(
                "SELECT COUNT(*) FROM books WHERE sync_id = ?", (BOOK_ONE,)
            ).fetchone()[0]
            == 0
        )
        assert (
            live.execute(
                "SELECT COUNT(*) FROM books WHERE sync_id = ?", (BOOK_TWO,)
            ).fetchone()[0]
            == 1
        )
        shelved = live.execute(
            "SELECT COUNT(*) FROM books WHERE sync_id = ? AND location_id IS NOT NULL",
            (BOOK_TWO,),
        ).fetchone()
        assert shelved[0] == 0
        assert (
            live.execute("SELECT COUNT(*) FROM loans").fetchone()[0] == 0
        )
        assert (
            live.execute("SELECT COUNT(*) FROM book_authors").fetchone()[0] == 0
        )
        assert (
            live.execute(
                "SELECT COUNT(*) FROM locations WHERE sync_id = ?", (CASE_ID,)
            ).fetchone()[0]
            == 0
        )
        # The deletions must keep travelling: applying the book tombstone
        # also remembers the loan's deletion locally, so a third device
        # without the book loses its loan history too.
        for table, sync_id in (
            ("books", BOOK_ONE),
            ("locations", CASE_ID),
            ("loans", LOAN_ONE),
        ):
            assert (
                live.execute(
                    "SELECT COUNT(*) FROM sync_tombstones"
                    " WHERE table_name = ? AND sync_id = ?",
                    (table, sync_id),
                ).fetchone()[0]
                == 1
            )
    finally:
        live.close()
