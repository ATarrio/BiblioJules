"""Session / API tokens.

Both the web UI and the desktop/mobile clients authenticate with an *opaque*
random token. Only its SHA-256 hash is stored, so a leaked database cannot be
turned back into a working credential. Web sessions and API tokens share this
table, distinguished by ``kind``:

* ``web``  — sent by the browser in an httpOnly cookie (``bj_session``).
* ``api``  — sent by native clients in an ``Authorization: Bearer …`` header.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import DateTime, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base

KIND_WEB = "web"
KIND_API = "api"


class Token(Base):
    __tablename__ = "tokens"

    id: Mapped[int] = mapped_column(primary_key=True)

    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    user: Mapped["User"] = relationship(back_populates="tokens")  # noqa: F821

    # SHA-256 (hex) of the raw token handed to the client.
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    kind: Mapped[str] = mapped_column(String(10), default=KIND_WEB)

    # Free-form note so a user can tell their devices apart ("Pixel 8", …).
    label: Mapped[str | None] = mapped_column(String(120))

    # Browser-only: the value forms must echo back (defence against CSRF).
    csrf_token: Mapped[str | None] = mapped_column(String(64))

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        state = "revoked" if self.revoked_at else "active"
        return f"<Token #{self.id} {self.kind} user={self.user_id} ({state})>"
