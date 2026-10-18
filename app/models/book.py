"""The central Book model."""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base


class Book(Base):
    __tablename__ = "books"

    id: Mapped[int] = mapped_column(primary_key=True)

    # ISBN stored normalised (digits and a trailing X only). Unique when present
    # but nullable, so hand-added books without an ISBN are still welcome.
    isbn: Mapped[str | None] = mapped_column(String(20), unique=True, index=True)

    title: Mapped[str] = mapped_column(String(500), index=True)
    subtitle: Mapped[str | None] = mapped_column(String(500))

    publisher_id: Mapped[int | None] = mapped_column(
        ForeignKey("publishers.id", ondelete="SET NULL"), index=True
    )
    publisher: Mapped["Publisher | None"] = relationship(back_populates="books")  # noqa: F821

    published_date: Mapped[str | None] = mapped_column(String(60))
    # Cached projection of ``published_date`` (the field the user edits), kept
    # so the catalog's Year sort stays a simple indexed column.
    published_year: Mapped[int | None] = mapped_column(Integer, index=True)

    description: Mapped[str | None] = mapped_column(Text)
    page_count: Mapped[int | None] = mapped_column(Integer)
    language: Mapped[str | None] = mapped_column(String(60))

    cover_url: Mapped[str | None] = mapped_column(String(1000))

    # Physical format and reading progress (slugs; see app/book_fields.py).
    cover_type: Mapped[str | None] = mapped_column(String(20))
    read_status: Mapped[str | None] = mapped_column(String(20))
    # 0.5–5.0 stars in half-star steps; null means unrated.
    score: Mapped[float | None] = mapped_column(Float)
    # A book's place in a series, e.g. "The Expanse" #2.
    saga: Mapped[str | None] = mapped_column(String(255))
    saga_number: Mapped[int | None] = mapped_column(Integer)

    location_id: Mapped[int | None] = mapped_column(
        ForeignKey("locations.id", ondelete="SET NULL"), index=True
    )
    location: Mapped["Location | None"] = relationship(back_populates="books")  # noqa: F821

    status_id: Mapped[int | None] = mapped_column(
        ForeignKey("statuses.id", ondelete="SET NULL"), index=True
    )
    status: Mapped["Status | None"] = relationship(back_populates="books")  # noqa: F821

    # Which online source the metadata originally came from (openlibrary,
    # googlebooks, manual, ...). Purely informational.
    source: Mapped[str | None] = mapped_column(String(40))

    notes: Mapped[str | None] = mapped_column(Text)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )

    authors: Mapped[list["Author"]] = relationship(  # noqa: F821
        secondary="book_authors",
        back_populates="books",
        order_by="Author.name",
    )
    loans: Mapped[list["Loan"]] = relationship(  # noqa: F821
        back_populates="book",
        cascade="all, delete-orphan",
        order_by="Loan.lent_at.desc()",
    )

    # --- convenience --------------------------------------------------------
    @property
    def author_names(self) -> list[str]:
        return [a.name for a in self.authors]

    @property
    def author_display(self) -> str:
        names = self.author_names
        return ", ".join(names) if names else "Unknown author"

    @property
    def active_loan(self) -> "Loan | None":  # noqa: F821
        for loan in self.loans:
            if loan.is_active:
                return loan
        return None

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Book #{self.id} {self.title!r}>"
