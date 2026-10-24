"""Reading objectives (goals), kept per account (or per device, offline).

Unlike the shared catalogue, these never travel through a cross-device sync
merge: each device or account keeps its own objectives. They *do* live in the
database rather than a side JSON file, so the single-file ``.sqlite`` export
carries them and a reinstalled app gets its objectives back.

``user_id`` is nullable on purpose: ``NULL`` is the local device's single owner
(there is no login in local mode), while a hosted server scopes rows by the
signed-in account's id. It is deliberately *not* a foreign key — objectives are
local metadata, not part of the shared-library graph, and the phone's copy of
the schema has no ``users`` table to point at.
"""

from __future__ import annotations

from sqlalchemy import Integer
from sqlalchemy.orm import Mapped, mapped_column

from ..database import Base


class ReadingGoal(Base):
    __tablename__ = "reading_goals"

    id: Mapped[int] = mapped_column(primary_key=True)

    # ``NULL`` = the local device's single owner; a server scopes by account id.
    user_id: Mapped[int | None] = mapped_column(Integer, index=True)

    # ``NULL`` year means "any year": such an objective counts a mark-read too.
    year: Mapped[int | None] = mapped_column(Integer, index=True)

    target_books: Mapped[int] = mapped_column(Integer, default=0)
    target_pages: Mapped[int] = mapped_column(Integer, default=0)

    # Progress is tracked per objective, incremented whenever a book is marked
    # read in this objective's year — never the all-time count of read books.
    books_done: Mapped[int] = mapped_column(Integer, default=0)
    pages_done: Mapped[int] = mapped_column(Integer, default=0)
