"""Plain-dict serializers.

Used by the JSON API (``/api/...``) and anywhere else that needs a
framework-agnostic representation of a model. Keeping this separate from the
HTML templates means a future SPA can reuse the same JSON shapes.
"""

from __future__ import annotations

from ..models import Book, Loan, Location, Status


def loan_to_dict(loan: Loan) -> dict:
    return {
        "id": loan.id,
        "book_id": loan.book_id,
        "borrower_name": loan.borrower_name,
        "borrower_contact": loan.borrower_contact,
        "lent_at": loan.lent_at.isoformat() if loan.lent_at else None,
        "due_at": loan.due_at.isoformat() if loan.due_at else None,
        "returned_at": loan.returned_at.isoformat() if loan.returned_at else None,
        "is_active": loan.is_active,
        "is_overdue": loan.is_overdue,
        "notes": loan.notes,
    }


def book_to_dict(book: Book) -> dict:
    active = book.active_loan
    return {
        "id": book.id,
        "isbn": book.isbn,
        "title": book.title,
        "subtitle": book.subtitle,
        "authors": book.author_names,
        "publisher": book.publisher.name if book.publisher else None,
        "published_date": book.published_date,
        "published_year": book.published_year,
        "description": book.description,
        "page_count": book.page_count,
        "language": book.language,
        "cover_url": book.cover_url,
        "source": book.source,
        "notes": book.notes,
        "location": location_to_dict(book.location) if book.location else None,
        "status": status_to_dict(book.status) if book.status else None,
        "active_loan": loan_to_dict(active) if active else None,
        "created_at": book.created_at.isoformat() if book.created_at else None,
        "updated_at": book.updated_at.isoformat() if book.updated_at else None,
    }


def location_to_dict(location: Location) -> dict:
    return {
        "id": location.id,
        "name": location.name,
        "kind": location.kind,
        "description": location.description,
        "parent_id": location.parent_id,
        "full_path": location.full_path,
    }


def status_to_dict(status: Status) -> dict:
    return {
        "id": status.id,
        "name": status.name,
        "slug": status.slug,
        "color": status.color,
        "icon": status.icon,
        "description": status.description,
        "sort_order": status.sort_order,
        "is_system": status.is_system,
        "is_default": status.is_default,
    }
