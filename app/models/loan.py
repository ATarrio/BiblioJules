"""Loan model.

A loan records that a book left the house: to whom, when, and when it should
come back. An *active* loan is one without a ``returned_at`` date. Books that
are simply being read at home are better represented by a status (e.g.
"Reading") rather than a loan.
"""

from __future__ import annotations

from datetime import date, datetime, timezone

from sqlalchemy import Date, DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base


class Loan(Base):
    __tablename__ = "loans"

    id: Mapped[int] = mapped_column(primary_key=True)

    book_id: Mapped[int] = mapped_column(
        ForeignKey("books.id", ondelete="CASCADE"), index=True
    )
    book: Mapped["Book"] = relationship(back_populates="loans")  # noqa: F821

    borrower_name: Mapped[str] = mapped_column(String(150))
    borrower_contact: Mapped[str | None] = mapped_column(String(255))

    lent_at: Mapped[date] = mapped_column(Date, default=date.today)
    due_at: Mapped[date | None] = mapped_column(Date)
    returned_at: Mapped[date | None] = mapped_column(Date)

    notes: Mapped[str | None] = mapped_column(Text)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )

    @property
    def is_active(self) -> bool:
        return self.returned_at is None

    @property
    def is_overdue(self) -> bool:
        return self.is_active and self.due_at is not None and self.due_at < date.today()

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        state = "active" if self.is_active else "returned"
        return f"<Loan #{self.id} {self.borrower_name!r} ({state})>"
