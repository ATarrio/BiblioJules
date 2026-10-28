"""Reading statistics must count shelves and read status separately."""

from __future__ import annotations

from app.models import Book
from app.services.library import get_status_by_slug
from app.services.stats import compute_stats


def _book(**values) -> Book:
    return Book(title=values.pop("title", "Book"), **values)


def test_compute_stats_counts_read_statuses_and_shelves(db):
    lost = get_status_by_slug(db, "lost")
    donated = get_status_by_slug(db, "donated")
    assert lost is not None and donated is not None

    db.add_all(
        [
            _book(title="Finished", read_status="read", page_count=120, score=4.5),
            _book(title="In progress", read_status="currently_reading"),
            # "Lost"/"donated" are shelves; their read status is independent.
            _book(title="Lost", read_status="unread", status_id=lost.id),
            _book(title="Donated", read_status="unread", status_id=donated.id),
        ]
    )
    db.commit()

    stats = compute_stats(db)

    assert stats["total_books"] == 4
    assert stats["books_read"] == 1
    assert stats["pages_read"] == 120
    assert stats["avg_rating"] == 4.5
    assert stats["currently_reading"] == 1
    assert stats["status_breakdown"]["read"] == 1
    assert stats["status_breakdown"]["currently_reading"] == 1
    assert stats["status_breakdown"]["lost"] == 1
    assert stats["status_breakdown"]["donated"] == 1
    assert stats["status_breakdown"]["unread"] == 2
