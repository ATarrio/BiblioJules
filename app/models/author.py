"""Author model."""

from __future__ import annotations

from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base
from .common import SyncIdMixin, UpdatedAtMixin


class Author(SyncIdMixin, UpdatedAtMixin, Base):
    __tablename__ = "authors"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255), unique=True, index=True)

    books: Mapped[list["Book"]] = relationship(  # noqa: F821
        secondary="book_authors",
        back_populates="authors",
    )

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Author {self.name!r}>"
