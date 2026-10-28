"""Start-up work shared by the web, desktop and command-line front-ends.

Every front-end needs the same database before it can do anything: create the
tables, bring an older schema up to date, seed the built-in statuses and tidy
legacy rows. Keeping the sequence here means a desktop launch and a web launch
can never drift apart.
"""

from __future__ import annotations

import logging

from .database import Base, SessionLocal, engine, ensure_sync_schema
from .services.library import prune_orphans, sync_published_years
from .services.seed import seed_defaults


def prepare_database() -> None:
    """Create/upgrade the database and seed it on first run."""
    Base.metadata.create_all(bind=engine)
    # New columns, sync ids and the indexes a merge relies on.
    ensure_sync_schema()

    db = SessionLocal()
    try:
        seed_defaults(db)
        # Fold legacy year-only rows into the single "Published" field.
        sync_published_years(db)
        # Clear out authors/publishers left behind by earlier book deletions.
        prune_orphans(db)
    finally:
        db.close()


def sync_on_start() -> None:
    """Merge the shared snapshot once, never letting a failure stop start-up."""
    from .services import sync as sync_service

    try:
        sync_service.sync_now()
    except sync_service.SyncError as exc:
        logging.warning("Shared library not synced: %s", exc)
    except Exception:  # pragma: no cover - unexpected filesystem trouble
        logging.exception("Shared library sync failed")
