"""Status model.

Statuses describe where a book *is* in its life: on the shelf, being read,
lent to a friend, wishlisted, lost... They are user-editable so you can bend
them to your needs. A few system statuses are seeded on first run.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base
from .common import SyncIdMixin, UpdatedAtMixin


class Status(SyncIdMixin, UpdatedAtMixin, Base):
    __tablename__ = "statuses"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    slug: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    color: Mapped[str] = mapped_column(String(20), default="#64748b")  # hex colour
    icon: Mapped[str | None] = mapped_column(String(16))  # emoji, optional
    description: Mapped[str | None] = mapped_column(Text)

    sort_order: Mapped[int] = mapped_column(Integer, default=0)
    # System statuses power features such as the wishlist; they can be renamed
    # and recoloured but not deleted.
    is_system: Mapped[bool] = mapped_column(Boolean, default=False)
    is_default: Mapped[bool] = mapped_column(Boolean, default=False)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )

    books: Mapped[list["Book"]] = relationship(back_populates="status")  # noqa: F821

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Status {self.name!r}>"
