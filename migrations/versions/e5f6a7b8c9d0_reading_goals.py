"""reading_goals: per-account reading objectives live in the database.

Objectives used to be a side JSON file, which meant the single-file ``.sqlite``
export dropped them and a reinstalled app lost its goals. Moving them into a
table lets the export carry them. The table is conditional so this also
succeeds against a database already created from the current models.

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-10-23
"""

from __future__ import annotations

from typing import Union

import sqlalchemy as sa
from alembic import op

revision: str = "e5f6a7b8c9d0"
down_revision: Union[str, None] = "d4e5f6a7b8c9"
branch_labels: Union[str, None] = None
depends_on: Union[str, None] = None


def _table_names() -> set[str]:
    return set(sa.inspect(op.get_bind()).get_table_names())


def upgrade() -> None:
    if "reading_goals" in _table_names():
        return
    op.create_table(
        "reading_goals",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=True),
        sa.Column("year", sa.Integer(), nullable=True),
        sa.Column("target_books", sa.Integer(), nullable=True, default=0),
        sa.Column("target_pages", sa.Integer(), nullable=True, default=0),
        sa.Column("books_done", sa.Integer(), nullable=True, default=0),
        sa.Column("pages_done", sa.Integer(), nullable=True, default=0),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_reading_goals")),
    )
    with op.batch_alter_table("reading_goals", schema=None) as batch_op:
        batch_op.create_index(batch_op.f("ix_reading_goals_user_id"), ["user_id"], unique=False)
        batch_op.create_index(batch_op.f("ix_reading_goals_year"), ["year"], unique=False)


def downgrade() -> None:
    if "reading_goals" in _table_names():
        op.drop_table("reading_goals")
