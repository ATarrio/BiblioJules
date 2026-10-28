"""The catalog query supports paging without changing its filters."""

from __future__ import annotations

from app.models import Book
from app.services.library import count_books, query_books


def _fill(db, count: int) -> None:
    db.add_all([Book(title=f"Book {index:03d}") for index in range(count)])
    db.commit()


def test_count_and_page_through_every_book(db):
    _fill(db, 75)

    assert count_books(db) == 75
    assert len(query_books(db, limit=10)) == 10
    assert len(query_books(db, limit=10, offset=70)) == 5
    assert query_books(db, limit=10, offset=75) == []

    # Every page is disjoint and covers the whole catalog.
    seen: set[int] = set()
    for offset in range(0, 75, 10):
        seen.update(book.id for book in query_books(db, limit=10, offset=offset))
    assert len(seen) == 75


def test_count_uses_the_same_filters(db):
    _fill(db, 12)
    db.add(Book(title="A very different title"))
    db.commit()

    assert count_books(db, search="different") == 1
    assert len(query_books(db, search="different")) == 1
    assert count_books(db, search="nothing-matches-this") == 0
