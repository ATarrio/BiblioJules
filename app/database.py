"""Database engine, session factory and declarative base.

The whole app talks to the database through SQLAlchemy, so moving from the
local SQLite file to PostgreSQL or MariaDB later is a one-line change of
``DATABASE_URL`` plus installing the relevant driver. Nothing else in the
codebase knows which database is in use.
"""

from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import MetaData, create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import settings

# A consistent naming scheme for constraints. This keeps auto-generated index
# and constraint names predictable, which makes a future migration to another
# database (via Alembic) far less painful.
NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """Declarative base for every model."""

    metadata = MetaData(naming_convention=NAMING_CONVENTION)


def _create_engine():
    url = settings.database_url

    # SQLite needs a couple of tweaks. Other databases ignore this branch.
    connect_args: dict = {}
    if url.startswith("sqlite"):
        connect_args = {"check_same_thread": False}

    engine = create_engine(
        url,
        echo=settings.sql_echo,
        future=True,
        connect_args=connect_args,
        pool_pre_ping=True,
    )

    if url.startswith("sqlite"):

        @event.listens_for(engine, "connect")
        def _set_sqlite_pragmas(dbapi_connection, _connection_record):
            cursor = dbapi_connection.cursor()
            # Enforce foreign keys (off by default in SQLite).
            cursor.execute("PRAGMA foreign_keys=ON")
            # Better concurrency for a local, single-user app.
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.close()

    return engine


engine = _create_engine()
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, expire_on_commit=False)


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency that yields a database session per request."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
