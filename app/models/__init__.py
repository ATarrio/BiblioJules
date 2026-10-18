"""Model package.

Importing this package registers every model on the shared ``Base`` metadata
so that ``Base.metadata.create_all()`` (and Alembic) can see them all.
"""

from __future__ import annotations

from .associations import book_authors
from .author import Author
from .book import Book
from .loan import Loan
from .location import Location
from .publisher import Publisher
from .status import Status
from .token import Token
from .user import User

__all__ = [
    "Author",
    "Book",
    "Loan",
    "Location",
    "Publisher",
    "Status",
    "Token",
    "User",
    "book_authors",
]
