"""Database engine, session factory and declarative base.

The whole app talks to the database through SQLAlchemy, so moving from the
local SQLite file to PostgreSQL or MariaDB later is a one-line change of
``DATABASE_URL`` plus installing the relevant driver. Nothing else in the
codebase knows which database is in use.
"""

from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import MetaData, create_engine, event, inspect, text
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


# --------------------------------------------------------------------------- #
# Lightweight schema sync
# --------------------------------------------------------------------------- #
def ensure_schema() -> None:
    """Add columns that the models define but an existing table lacks.

    ``Base.metadata.create_all`` only creates missing *tables*; it never alters
    an existing one. The bundled SQLite databases are created that way (without
    an Alembic version table), so a model that gains a column would otherwise
    leave older databases behind. This adds each missing column in place — a
    cheap, idempotent ``ALTER TABLE ADD COLUMN`` that is safe to run at startup.
    """
    inspector = inspect(engine)
    existing_tables = set(inspector.get_table_names())
    with engine.begin() as connection:
        for table in Base.metadata.sorted_tables:
            if table.name not in existing_tables:
                continue
            present = {column["name"] for column in inspector.get_columns(table.name)}
            for column in table.columns:
                if column.name in present:
                    continue
                connection.execute(text(_add_column_statement(connection, table.name, column)))


def _add_column_statement(connection, table_name: str, column) -> str:
    type_sql = column.type.compile(dialect=connection.dialect)
    statement = f'ALTER TABLE "{table_name}" ADD COLUMN "{column.name}" {type_sql}'
    if not column.nullable:
        server_default = getattr(column, "server_default", None)
        if server_default is None:
            raise RuntimeError(
                f"Cannot add required column {table_name}.{column.name} to an existing "
                "database without a server default; use an Alembic migration instead."
            )
        statement += f" DEFAULT {server_default.arg}"
    return statement
