"""Many-to-many association tables."""

from __future__ import annotations

from sqlalchemy import Column, ForeignKey, Table

from ..database import Base

# A book can have several authors, and an author can write several books.
book_authors = Table(
    "book_authors",
    Base.metadata,
    Column("book_id", ForeignKey("books.id", ondelete="CASCADE"), primary_key=True),
    Column("author_id", ForeignKey("authors.id", ondelete="CASCADE"), primary_key=True),
)
