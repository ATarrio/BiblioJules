"""First-run seeding.

Creates the handful of system statuses the app relies on (wishlist, lent,
reading, ...). They are ordinary rows you can rename or recolour later; only
their ``slug`` is meaningful to the code.
"""

from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..models import Status

DEFAULT_STATUSES = [
    {"slug": "available", "name": "In library", "color": "#16a34a", "icon": "📚", "sort_order": 10, "is_default": True},
    {"slug": "reading", "name": "Reading", "color": "#2563eb", "icon": "📖", "sort_order": 20},
    {"slug": "lent", "name": "Lent out", "color": "#d97706", "icon": "🤝", "sort_order": 30},
    {"slug": "wishlist", "name": "Wishlist", "color": "#7c3aed", "icon": "⭐", "sort_order": 40},
    {"slug": "lost", "name": "Lost", "color": "#dc2626", "icon": "🕳️", "sort_order": 50},
    {"slug": "donated", "name": "Donated", "color": "#64748b", "icon": "🎁", "sort_order": 60},
]


def seed_defaults(db: Session) -> None:
    """Insert the system statuses if the table is still empty."""
    existing = db.scalar(select(func.count(Status.id))) or 0
    if existing:
        return

    for spec in DEFAULT_STATUSES:
        db.add(
            Status(
                name=spec["name"],
                slug=spec["slug"],
                color=spec["color"],
                icon=spec.get("icon"),
                sort_order=spec["sort_order"],
                is_system=True,
                is_default=spec.get("is_default", False),
            )
        )
    db.commit()
