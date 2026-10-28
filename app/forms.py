"""Shaping helpers for the book form.

The add/edit form is rendered by more than one router (the catalog itself and
the online-discovery prefill), so the code that turns a book row into form
fields — and the vocabulary the form needs — lives here.
"""

from __future__ import annotations

from sqlalchemy.orm import Session

from .services import library


def book_to_form(book) -> dict:
    """Shape a Book (model object or plain dict) into template form fields."""
    if isinstance(book, dict):
        data = dict(book)
        authors = data.get("authors") or []
        if isinstance(authors, list):
            data["authors"] = ", ".join(authors)
        return data
    return {
        "id": book.id,
        "isbn": book.isbn,
        "title": book.title,
        "subtitle": book.subtitle,
        "authors": ", ".join(book.author_names),
        "publisher": book.publisher.name if book.publisher else "",
        "published_date": book.published_date
        or (str(book.published_year) if book.published_year else ""),
        "page_count": book.page_count,
        "language": book.language,
        "cover_url": book.cover_url,
        "cover_type": book.cover_type,
        "read_status": book.read_status,
        "score": book.score,
        "saga": book.saga,
        "saga_number": book.saga_number,
        "description": book.description,
        "notes": book.notes,
        "collaborators": book.collaborators,
        "translators": book.translators,
        "illustrators": book.illustrators,
        "source": book.source,
        "location_id": book.location_id,
        "status_id": book.status_id,
    }


def form_context(db: Session, form: dict, **extra) -> dict:
    """Template context shared by every render of ``books/_form.html``."""
    return {
        "form": form,
        "statuses": library.list_statuses(db),
        "locations": library.flatten_locations(db),
        "default_status": library.get_default_status(db),
        "sagas": library.list_sagas(db),
        **extra,
    }
