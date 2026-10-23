"""JSON API.

The HTML UI never calls these directly, but they exist so the catalogue can be
scripted, backed up, or fronted by the desktop and mobile clients without
touching the service layer. Everything here is a thin wrapper around
``services``.

Authentication: every route in this router requires a valid ``api`` bearer
token (see ``app.dependencies``) except the login routes, which live in
``app.routers.auth``.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, UploadFile
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .. import i18n
from ..i18n import _
from ..book_fields import (
    COVER_TYPES,
    MAX_SCORE,
    MIN_SCORE,
    READ_STATUSES,
    SCORE_STEP,
    cover_type_label,
    read_status_label,
)
from ..config import settings
from ..database import get_db
from ..models import Location, Status
from ..models.user import ROLES
from ..schemas import BookIn, LoanIn, LocationIn, ReturnIn, StatusIn
from ..services import library
from ..services.covers import (
    MAX_COVER_BYTES,
    covers_dir,
    delete_cover,
    new_cover_name,
    sniff_image,
)
from ..services.isbn_lookup import lookup_isbn, search_books
from ..services.serializers import (
    book_to_dict,
    loan_to_dict,
    location_to_dict,
    status_to_dict,
)
from .pages import SORT_FIELDS

router = APIRouter(prefix="/api", tags=["api"])


def _int_or_none(value):
    try:
        return int(value) if value not in (None, "", "all") else None
    except (TypeError, ValueError):
        return None


def _descending(direction: str | None) -> bool | None:
    if direction is None:
        return None
    return direction.strip().lower() == "desc"


def _user_id(request: Request) -> int | None:
    user = getattr(request.state, "user", None)
    return getattr(user, "id", None)


# --------------------------------------------------------------------------- #
# Books
# --------------------------------------------------------------------------- #
@router.get("/books")
def list_books(
    search: str | None = None,
    status: str | None = None,
    location: str | None = None,
    author: str | None = None,
    publisher: str | None = None,
    loaned: str | None = None,
    saga: str | None = None,
    read_status: str | None = None,
    sort: str = "recent",
    dir: str | None = None,
    limit: int = Query(500, ge=1, le=500),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    books = library.query_books(
        db,
        search=search,
        status_id=_int_or_none(status),
        location_id=_int_or_none(location),
        author_id=_int_or_none(author),
        publisher_id=_int_or_none(publisher),
        loaned=loaned,
        saga=saga,
        read_status=read_status,
        sort=sort,
        descending=_descending(dir),
    )
    total = len(books)
    page = books[offset : offset + limit]
    return {
        "count": total,
        "limit": limit,
        "offset": offset,
        "items": [book_to_dict(b) for b in page],
    }


@router.get("/books/by-isbn/{isbn}")
def get_book_by_isbn(isbn: str, db: Session = Depends(get_db)):
    """Look up a single book by ISBN (used by clients to spot duplicates)."""
    book = library.find_by_isbn(db, isbn)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    return book_to_dict(book)


@router.get("/books/{book_id}")
def get_book(book_id: int, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    return book_to_dict(book)


@router.post("/books/{book_id}/cover")
async def upload_cover(
    book_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    """Replace a book's cover with an uploaded image.

    The browser form posts to the HTML endpoint; the JSON clients (desktop in
    remote mode, Android) use this one and get the updated book back.
    """
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))

    content = await file.read(MAX_COVER_BYTES + 1)
    if not content:
        raise HTTPException(status_code=400, detail=_("That file is empty."))
    if len(content) > MAX_COVER_BYTES:
        raise HTTPException(
            status_code=413,
            detail=_("That image is too large (the limit is 10 MB)."),
        )
    suffix = sniff_image(content)
    if suffix is None:
        raise HTTPException(
            status_code=400, detail=_("That file is not a supported image.")
        )

    safe_name = new_cover_name(book, suffix)
    old_url = book.cover_url
    try:
        (covers_dir() / safe_name).write_bytes(content)
    except OSError as exc:
        raise HTTPException(
            status_code=500, detail=_("The cover could not be saved.")
        ) from exc
    book.cover_url = f"/covers/{safe_name}"
    try:
        db.commit()
    except Exception as exc:  # noqa: BLE001 - roll back the row and remove the file
        db.rollback()
        (covers_dir() / safe_name).unlink(missing_ok=True)
        raise HTTPException(
            status_code=500, detail=_("The cover could not be saved.")
        ) from exc
    delete_cover(old_url)
    return book_to_dict(library.get_book(db, book.id))


@router.get("/books/{book_id}/loans")
def book_loans(book_id: int, db: Session = Depends(get_db)):
    """Every loan a book has had, newest first (active or returned)."""
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    return [loan_to_dict(loan) for loan in book.loans]


@router.post("/books", status_code=201)
def create_book(payload: BookIn, db: Session = Depends(get_db)):
    try:
        book = library.create_book(db, payload.model_dump(exclude_unset=True))
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(
            status_code=409, detail="A book with that ISBN already exists."
        ) from exc
    return book_to_dict(library.get_book(db, book.id))


@router.put("/books/{book_id}")
def update_book(book_id: int, payload: BookIn, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    # ``exclude_unset`` (not ``exclude_none``) keeps fields the client sent as
    # ``null``, which is how form-style clients clear a value (e.g. remove a
    # book from its shelf) without overwriting the ones they left out.
    try:
        library.update_book(db, book, payload.model_dump(exclude_unset=True))
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(
            status_code=409, detail="A book with that ISBN already exists."
        ) from exc
    return book_to_dict(library.get_book(db, book.id))


@router.delete("/books/{book_id}", status_code=204)
def delete_book(book_id: int, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    cover_url = book.cover_url
    library.delete_book(db, book)
    # Local uploaded covers are files, not database rows; remove them too.
    delete_cover(cover_url)


@router.post("/books/{book_id}/lend", status_code=201)
def lend_book(book_id: int, payload: LoanIn, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    try:
        loan = library.lend_book(
            db,
            book,
            borrower_name=payload.borrower_name,
            borrower_contact=payload.borrower_contact,
            lent_at=payload.lent_at,
            due_at=payload.due_at,
            notes=payload.notes,
            mark_status=payload.mark_status,
        )
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return loan_to_dict(loan)


@router.post("/books/{book_id}/return")
def return_book(
    book_id: int, payload: ReturnIn | None = None, db: Session = Depends(get_db)
):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    payload = payload or ReturnIn()
    library.return_loan(
        db,
        book,
        returned_at=payload.returned_at,
        restore_status=payload.restore_status,
    )
    return {"ok": True}


# --------------------------------------------------------------------------- #
# Locations & statuses
# --------------------------------------------------------------------------- #
@router.get("/locations")
def list_locations(db: Session = Depends(get_db)):
    return [location_to_dict(loc) for loc, _depth in library.flatten_locations(db)]


@router.get("/locations/{location_id}")
def get_location(location_id: int, db: Session = Depends(get_db)):
    location = db.get(Location, location_id)
    if location is None:
        raise HTTPException(status_code=404, detail="Location not found")
    return location_to_dict(location)


@router.post("/locations", status_code=201)
def create_location(payload: LocationIn, db: Session = Depends(get_db)):
    try:
        location = library.create_location(db, **payload.model_dump())
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return location_to_dict(location)


@router.put("/locations/{location_id}")
def update_location(location_id: int, payload: LocationIn, db: Session = Depends(get_db)):
    location = db.get(Location, location_id)
    if location is None:
        raise HTTPException(status_code=404, detail="Location not found")
    try:
        library.update_location(
            db,
            location,
            name=payload.name,
            parent_id=payload.parent_id,
            kind=payload.kind,
            description=payload.description,
        )
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return location_to_dict(location)


@router.post("/locations/{location_id}/delete", status_code=204)
def delete_location(location_id: int, db: Session = Depends(get_db)):
    location = db.get(Location, location_id)
    if location is None:
        raise HTTPException(status_code=404, detail="Location not found")
    library.delete_location(db, location)


@router.get("/statuses")
def list_statuses(db: Session = Depends(get_db)):
    return [status_to_dict(s) for s in library.list_statuses(db)]


@router.get("/statuses/{status_id}")
def get_status(status_id: int, db: Session = Depends(get_db)):
    status = db.get(Status, status_id)
    if status is None:
        raise HTTPException(status_code=404, detail="Status not found")
    return status_to_dict(status)


@router.post("/statuses", status_code=201)
def create_status(payload: StatusIn, db: Session = Depends(get_db)):
    try:
        status = library.create_status(db, **payload.model_dump())
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return status_to_dict(status)


@router.put("/statuses/{status_id}")
def update_status(status_id: int, payload: StatusIn, db: Session = Depends(get_db)):
    status = db.get(Status, status_id)
    if status is None:
        raise HTTPException(status_code=404, detail="Status not found")
    try:
        library.update_status(
            db,
            status,
            name=payload.name,
            color=payload.color,
            icon=payload.icon,
            description=payload.description,
        )
    except ValueError as exc:
        db.rollback()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return status_to_dict(status)


@router.post("/statuses/{status_id}/delete", status_code=204)
def delete_status(status_id: int, db: Session = Depends(get_db)):
    status = db.get(Status, status_id)
    if status is None:
        raise HTTPException(status_code=404, detail="Status not found")
    try:
        library.delete_status(db, status)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


# --------------------------------------------------------------------------- #
# Reference data (filter dropdowns)
# --------------------------------------------------------------------------- #
@router.get("/authors")
def list_authors(db: Session = Depends(get_db)):
    return [{"id": a.id, "name": a.name} for a in library.list_authors(db)]


@router.get("/publishers")
def list_publishers(db: Session = Depends(get_db)):
    return [{"id": p.id, "name": p.name} for p in library.list_publishers(db)]


@router.get("/sagas")
def list_sagas(db: Session = Depends(get_db)):
    return library.list_sagas(db)


# --------------------------------------------------------------------------- #
# Dashboard aggregate
# --------------------------------------------------------------------------- #
@router.get("/dashboard")
def dashboard(db: Session = Depends(get_db)):
    recent = library.query_books(db, sort="recent")[:6]
    loans = [
        loan
        for book in library.query_books(db, loaned="loaned")
        for loan in [book.active_loan]
        if loan
    ]
    return {
        "stats": library.get_stats(db),
        "status_counts": [
            {"status": status_to_dict(status), "count": count}
            for status, count in library.status_counts(db)
        ],
        "recent": [book_to_dict(book) for book in recent],
        "active_loans": [
            {
                **loan_to_dict(loan),
                "book": {
                    "id": loan.book_id,
                    "title": loan.book.title if loan.book else None,
                },
            }
            for loan in loans
        ],
    }


# --------------------------------------------------------------------------- #
# Client metadata & translations
# --------------------------------------------------------------------------- #
@router.get("/meta")
def meta():
    """Fixed vocabularies and options, so clients need not hardcode them."""
    return {
        "app_name": settings.app_name,
        "version": "0.1.0",
        "cover_types": [
            {"slug": slug, "label": cover_type_label(slug)} for slug, _ in COVER_TYPES
        ],
        "read_statuses": [
            {"slug": slug, "label": read_status_label(slug)} for slug, _ in READ_STATUSES
        ],
        "score": {"min": MIN_SCORE, "max": MAX_SCORE, "step": SCORE_STEP},
        "sorts": [
            {"key": key, "label": i18n.gettext(label),
             "default_dir": "desc" if default_desc else "asc"}
            for key, label, default_desc in SORT_FIELDS
        ]
        + [{"key": "recent", "label": i18n.gettext("Recently added"), "default_dir": "desc"}],
        "roles": list(ROLES),
        "languages": i18n.SUPPORTED_LANGUAGES,
        "default_language": i18n.DEFAULT_LANGUAGE,
    }


@router.get("/i18n/{lang}")
def translations(lang: str):
    """The string catalogue for a language (used by clients for localisation)."""
    code = i18n.normalize_language(lang)
    return {"language": code, "strings": i18n.load_catalog(code)}


# --------------------------------------------------------------------------- #
# Online lookup
# --------------------------------------------------------------------------- #
@router.get("/lookup/isbn/{isbn}")
async def lookup(isbn: str):
    data = await lookup_isbn(isbn)
    if data is None:
        raise HTTPException(status_code=404, detail="No catalogue entry found")
    return data


@router.get("/search")
async def search(q: str = Query(..., min_length=1), limit: int = 12):
    results = await search_books(q, limit=limit)
    for result in results:
        authors = result.get("authors") or []
        result["authors_str"] = ", ".join(authors) if isinstance(authors, list) else authors
    return results


# --------------------------------------------------------------------------- #
# Stats
# --------------------------------------------------------------------------- #
@router.get("/stats")
def stats(db: Session = Depends(get_db)):
    return library.get_stats(db)


# --------------------------------------------------------------------------- #
# Personal stats & goals (local-only, per-device storage)
# --------------------------------------------------------------------------- #
@router.get("/personal-stats")
def personal_stats(db: Session = Depends(get_db)):
    """Reading stats computed from the shared library DB."""
    from ..services.stats import compute_stats

    return compute_stats(db)


@router.get("/goals")
def reading_goals(request: Request):
    """Read the signed-in account's reading goals."""
    from ..services.stats import load_goals

    return load_goals(user_id=_user_id(request))


@router.post("/goals")
def save_reading_goals(payload: dict, request: Request):
    """Save reading goals (target books / pages for a given year)."""
    from ..services.stats import save_goals

    save_goals(payload, user_id=_user_id(request))
    return {"ok": True}


# --------------------------------------------------------------------------- #
# Want-to-read list (local-only)
# --------------------------------------------------------------------------- #
@router.get("/wantlist")
def wantlist(request: Request):
    """Read the signed-in account's want-to-read list."""
    from ..services.stats import load_want_list

    return load_want_list(user_id=_user_id(request))


@router.post("/wantlist")
def add_wantlist_entry(payload: dict, request: Request):
    """Append an entry to the want-to-read list."""
    from ..services.stats import add_want_entry

    add_want_entry(payload, user_id=_user_id(request))
    return {"ok": True}


@router.delete("/wantlist/{entry_id}")
def delete_wantlist_entry(entry_id: str, request: Request):
    """Remove an entry from the want-to-read list."""
    from ..services.stats import remove_want_entry

    remove_want_entry(entry_id=entry_id, user_id=_user_id(request))
    return {"ok": True}
