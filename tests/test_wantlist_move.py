"""Moving a want-to-read entry into the catalog."""

from __future__ import annotations

from types import SimpleNamespace

from app.models import Book
from app.routers import api
from app.services import stats


def test_move_wantlist_entry_creates_a_book_and_removes_the_entry(
    db, tmp_path, monkeypatch
):
    monkeypatch.setattr(stats, "WANT_LIST_FILE", tmp_path / "want_list.json")
    entry = {
        "id": "want-1",
        "isbn": "9780306406157",
        "title": "A wanted book",
        "authors": "Someone",
    }
    stats.add_want_entry(entry, user_id=1)

    request = SimpleNamespace(state=SimpleNamespace(user=SimpleNamespace(id=1)))
    result = api.move_wantlist_to_catalog("want-1", request, db)

    book = db.get(Book, result["book_id"])
    assert book is not None
    assert book.title == "A wanted book"
    assert book.read_status == "to_read"
    assert stats.load_want_list(user_id=1) == []
