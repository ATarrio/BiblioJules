"""book: add collaborators, translators and illustrators.

Free-text fields for the people who helped bring a book into being beyond the
listed authors (e.g. contributing illustrators, translators, editors).
Stored as comma-separated names, mirroring the form's free-text fields.

Revision ID: f7a8b9c0d1e2
Revises: e5f6a7b8c9d0
Create Date: 2026-10-26
"""

from __future__ import annotations

from typing import Union

import sqlalchemy as sa
from alembic import op

revision: str = "f7a8b9c0d1e2"
down_revision: Union[str, None] = "e5f6a7b8c9d0"
branch_labels: Union[str, None] = None
depends_on: Union[str, None] = None


def upgrade() -> None:
    with op.batch_alter_table("books", schema=None) as batch_op:
        batch_op.add_column(sa.Column("collaborators", sa.Text(), nullable=True))
        batch_op.add_column(sa.Column("translators", sa.Text(), nullable=True))
        batch_op.add_column(sa.Column("illustrators", sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("books", schema=None) as batch_op:
        batch_op.drop_column("illustrators")
        batch_op.drop_column("translators")
        batch_op.drop_column("collaborators")
