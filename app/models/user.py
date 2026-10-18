"""User accounts.

The library itself is shared: every user sees and edits the same books,
locations and statuses. Accounts exist so the app can be hosted somewhere and
reached over the internet without leaving the whole catalogue open. An
administrator decides who gets in (see the admin panel and ``app/cli.py``).
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..database import Base

ROLE_ADMIN = "admin"
ROLE_MEMBER = "member"
ROLES: tuple[str, ...] = (ROLE_ADMIN, ROLE_MEMBER)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)

    # Stored as typed but compared case-insensitively by the service layer.
    username: Mapped[str] = mapped_column(String(80), unique=True, index=True)
    display_name: Mapped[str | None] = mapped_column(String(120))
    password_hash: Mapped[str] = mapped_column(String(255))

    role: Mapped[str] = mapped_column(String(20), default=ROLE_MEMBER)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    tokens: Mapped[list["Token"]] = relationship(  # noqa: F821
        back_populates="user",
        cascade="all, delete-orphan",
    )

    # --- convenience --------------------------------------------------------
    @property
    def is_admin(self) -> bool:
        return self.role == ROLE_ADMIN

    @property
    def label(self) -> str:
        """Name to show in the UI (falls back to the username)."""
        return self.display_name or self.username

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<User {self.username!r} ({self.role})>"
