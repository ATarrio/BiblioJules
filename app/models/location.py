"""Location model.

Locations are hierarchical so you can model your home however you like:

    Living room            (kind="room")
      └─ Bookshelf A       (kind="shelf")
           └─ Top shelf    (kind="shelf")

A book points at a single, most-specific location. Filtering by any node in
the tree also matches everything stored underneath it.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base


class Location(Base):
    __tablename__ = "locations"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(150), index=True)
    # Free-form label such as "room", "shelf", "box", "nightstand".
    kind: Mapped[str | None] = mapped_column(String(50))
    description: Mapped[str | None] = mapped_column(Text)

    parent_id: Mapped[int | None] = mapped_column(
        ForeignKey("locations.id", ondelete="CASCADE"), index=True
    )
    parent: Mapped["Location | None"] = relationship(
        remote_side=[id], back_populates="children"
    )
    children: Mapped[list["Location"]] = relationship(
        back_populates="parent",
        cascade="all, delete-orphan",
        order_by="Location.name",
    )

    books: Mapped[list["Book"]] = relationship(back_populates="location")  # noqa: F821

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )

    # --- convenience --------------------------------------------------------
    @property
    def full_path(self) -> str:
        """Human readable path, e.g. ``Living room / Bookshelf A / Top shelf``."""
        parts: list[str] = []
        node: Location | None = self
        guard = 0
        while node is not None and guard < 100:
            parts.append(node.name)
            node = node.parent
            guard += 1
        return " / ".join(reversed(parts))

    def descendant_ids(self) -> list[int]:
        """Return this location's id plus every descendant's id."""
        ids = [self.id]
        stack = list(self.children)
        while stack:
            node = stack.pop()
            ids.append(node.id)
            stack.extend(node.children)
        return ids

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Location {self.full_path!r}>"
