"""Desktop database helpers.

Both front-ends share the same ``SessionLocal`` factory and ``engine`` defined
in :mod:`app.database`, so the desktop app reads and writes the exact same
SQLite file as the web app (as long as ``DATABASE_URL`` resolves the same way).
"""

from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator

from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from ..bootstrap import prepare_database
from ..database import SessionLocal
from ..i18n import _


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
    except ValueError as exc:
        # Service-layer validation (bad reference, duplicate loan, …) already
        # carries a user-facing message. Give the desktop the same error type
        # as the remote backend so every view handles it uniformly.
        from .repo import RepoError

        raise RepoError(str(exc)) from exc
    except SQLAlchemyError as exc:
        from .repo import RepoError

        detail = str(exc).lower()
        if "database is locked" in detail or "database table is locked" in detail:
            raise RepoError(
                _(
                    "The library database is busy (another window or the web app "
                    "is saving changes). Wait a moment and try again."
                )
            ) from exc
        raise RepoError(
            _("Could not read or write the library database: %s") % exc
        ) from exc
    finally:
        db.close()


def initialize_database() -> None:
    """Create tables if needed and seed the built-in statuses.

    Mirrors the FastAPI ``lifespan`` startup hook so the desktop app can be
    launched first and still produce a usable, seeded catalog.
    """
    prepare_database()
