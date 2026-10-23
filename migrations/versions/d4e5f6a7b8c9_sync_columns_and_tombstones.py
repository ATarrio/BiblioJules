"""Shared-library columns, tombstones and the fields the models gained later.

The runtime ``ensure_sync_schema()`` keeps old databases usable, but a database
managed by Alembic must reach the same shape through a migration. Everything
here is conditional so it also succeeds against a database that was created
from the current models (and therefore already has some of the columns).

Revision ID: d4e5f6a7b8c9
Revises: c1a7f3e9d2b4
Create Date: 2026-10-23
"""

from __future__ import annotations

from typing import Union

import sqlalchemy as sa
from alembic import op

revision: str = "d4e5f6a7b8c9"
down_revision: Union[str, None] = "c1a7f3e9d2b4"
branch_labels: Union[str, None] = None
depends_on: Union[str, None] = None

#: Columns that were added to models after the initial schema.
_EXTRA_COLUMNS = {
    "books": (
        ("cover_type", sa.String(length=20)),
        ("read_status", sa.String(length=20)),
        ("score", sa.Float()),
        ("saga", sa.String(length=255)),
        ("saga_number", sa.Integer()),
    ),
}

_SYNCED_TABLES = ("books", "authors", "publishers", "locations", "statuses", "loans")


def _inspector():
    return sa.inspect(op.get_bind())


def _columns(table: str) -> set[str]:
    inspector = _inspector()
    if table not in inspector.get_table_names():
        return set()
    return {column["name"] for column in inspector.get_columns(table)}


def _index_names(table: str) -> set[str]:
    inspector = _inspector()
    if table not in inspector.get_table_names():
        return set()
    return {index["name"] for index in inspector.get_indexes(table)}


def upgrade() -> None:
    inspector = _inspector()
    tables = set(inspector.get_table_names())

    for table, columns in _EXTRA_COLUMNS.items():
        if table not in tables:
            continue
        present = _columns(table)
        for name, kind in columns:
            if name not in present:
                op.add_column(table, sa.Column(name, kind, nullable=True))

    for table in _SYNCED_TABLES:
        if table not in tables:
            continue
        present = _columns(table)
        with op.batch_alter_table(table) as batch:
            if "sync_id" not in present:
                batch.add_column(sa.Column("sync_id", sa.String(length=32), nullable=True))
            if table != "books" and "updated_at" not in present:
                batch.add_column(
                    sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True)
                )
        if f"ix_{table}_sync_id" not in _index_names(table):
            op.create_index(f"ix_{table}_sync_id", table, ["sync_id"], unique=True)

    if "sync_tombstones" not in tables:
        op.create_table(
            "sync_tombstones",
            sa.Column("table_name", sa.String(length=40), nullable=False),
            sa.Column("sync_id", sa.String(length=32), nullable=False),
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.PrimaryKeyConstraint("table_name", "sync_id"),
        )


def downgrade() -> None:
    # These columns are part of the shared-library format; removing them would
    # discard sync state. Keep the downgrade conservative and only drop the
    # tombstone table added by this migration.
    if "sync_tombstones" in _inspector().get_table_names():
        op.drop_table("sync_tombstones")
