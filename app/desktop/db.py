"""Desktop database helpers.

Both front-ends share the same ``SessionLocal`` factory and ``engine`` defined
in :mod:`app.database`, so the desktop app reads and writes the exact same
SQLite file as the web app (as long as ``DATABASE_URL`` resolves the same way).
"""

from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator

from sqlalchemy.orm import Session

from ..database import Base, SessionLocal, engine
from ..services.library import prune_orphans
from ..services.seed import seed_defaults


@contextmanager
def session_scope() -> Iterator[Session]:
    """Open a short-lived session and always close it.

    The service layer commits internally, so callers only need to read/write
    within the block. Using a fresh session per operation keeps the UI free of
    stale objects and matches how the web request cycle works.
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def initialize_database() -> None:
    """Create tables if needed and seed the built-in statuses.

    Mirrors the FastAPI ``lifespan`` startup hook so the desktop app can be
    launched first and still produce a usable, seeded catalog.
    """
    Base.metadata.create_all(bind=engine)
    with session_scope() as db:
        seed_defaults(db)
        # Clear out authors/publishers left behind by earlier book deletions.
        prune_orphans(db)
