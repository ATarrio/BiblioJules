"""JSON API.

The HTML UI never calls these directly, but they exist so that the catalog can
be scripted, backed up, or fronted by a single-page app later without touching
the service layer. Everything here is a thin wrapper around ``services``.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import Location, Status
from ..schemas import BookIn, LoanIn, LocationIn, StatusIn
from ..services import library
from ..services.isbn_lookup import lookup_isbn, search_books
from ..services.serializers import (
    book_to_dict,
    loan_to_dict,
    location_to_dict,
    status_to_dict,
)

router = APIRouter(prefix="/api", tags=["api"])


def _int_or_none(value):
    try:
        return int(value) if value not in (None, "", "all") else None
    except (TypeError, ValueError):
        return None


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
    sort: str = "recent",
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
        sort=sort,
    )
    return {"count": len(books), "items": [book_to_dict(b) for b in books]}


@router.get("/books/{book_id}")
def get_book(book_id: int, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    return book_to_dict(book)


@router.post("/books", status_code=201)
def create_book(payload: BookIn, db: Session = Depends(get_db)):
    book = library.create_book(db, payload.model_dump(exclude_none=True))
    return book_to_dict(library.get_book(db, book.id))


@router.put("/books/{book_id}")
def update_book(book_id: int, payload: BookIn, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    library.update_book(db, book, payload.model_dump(exclude_none=True))
    return book_to_dict(library.get_book(db, book.id))


@router.delete("/books/{book_id}", status_code=204)
def delete_book(book_id: int, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    library.delete_book(db, book)


@router.post("/books/{book_id}/lend", status_code=201)
def lend_book(book_id: int, payload: LoanIn, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    loan = library.lend_book(
        db,
        book,
        borrower_name=payload.borrower_name,
        borrower_contact=payload.borrower_contact,
        lent_at=payload.lent_at,
        due_at=payload.due_at,
        notes=payload.notes,
    )
    return loan_to_dict(loan)


@router.post("/books/{book_id}/return")
def return_book(book_id: int, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="Book not found")
    library.return_loan(db, book)
    return {"ok": True}


# --------------------------------------------------------------------------- #
# Locations & statuses
# --------------------------------------------------------------------------- #
@router.get("/locations")
def list_locations(db: Session = Depends(get_db)):
    return [location_to_dict(loc) for loc, _depth in library.flatten_locations(db)]


@router.post("/locations", status_code=201)
def create_location(payload: LocationIn, db: Session = Depends(get_db)):
    location = library.create_location(db, **payload.model_dump())
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


@router.post("/statuses", status_code=201)
def create_status(payload: StatusIn, db: Session = Depends(get_db)):
    status = library.create_status(db, **payload.model_dump())
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
    return await search_books(q, limit=limit)


# --------------------------------------------------------------------------- #
# Stats
# --------------------------------------------------------------------------- #
@router.get("/stats")
def stats(db: Session = Depends(get_db)):
    return library.get_stats(db)
