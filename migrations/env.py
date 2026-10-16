"""Alembic environment.

Reads the database URL from the application settings so migrations and the app
always agree on which database they are talking to.
"""

from __future__ import annotations

from logging.config import fileConfig

from alembic import context

from app.config import settings
from app.database import Base

# Importing the models package registers every table on Base.metadata.
import app.models  # noqa: F401,E402

config = context.config
config.set_main_option("sqlalchemy.url", settings.database_url.replace("%", "%%"))

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=settings.database_url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    from app.database import engine

    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
            # SQLite needs batch mode for ALTERs; harmless for other databases.
            render_as_batch=settings.database_url.startswith("sqlite"),
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
