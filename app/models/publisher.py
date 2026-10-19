"""Publisher model."""

from __future__ import annotations

from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base
from .common import SyncIdMixin, UpdatedAtMixin


class Publisher(SyncIdMixin, UpdatedAtMixin, Base):
    __tablename__ = "publishers"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255), unique=True, index=True)

    books: Mapped[list["Book"]] = relationship(back_populates="publisher")  # noqa: F821

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Publisher {self.name!r}>"
