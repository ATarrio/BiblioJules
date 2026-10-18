"""Book CRUD, loans, scanning and editing (form + HTMX endpoints)."""

from __future__ import annotations

from datetime import date, datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..services import library
from ..services.isbn_lookup import is_valid_isbn, lookup_isbn, normalize_isbn
from ..templating import templates

router = APIRouter()


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _parse_date(value) -> date | None:
    if not value:
        return None
    if isinstance(value, date):
        return value
    try:
        return datetime.strptime(str(value), "%Y-%m-%d").date()
    except ValueError:
        return None


def _redirect(request: Request, url: str) -> Response:
    """Redirect, transparently supporting HTMX requests."""
    if request.headers.get("HX-Request"):
        return Response(status_code=204, headers={"HX-Redirect": url})
    return Response(status_code=303, headers={"Location": url})


async def _form_dict(request: Request) -> dict:
    form = await request.form()
    return {key: value for key, value in form.items()}


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
        "source": book.source,
        "location_id": book.location_id,
        "status_id": book.status_id,
    }


def form_context(db: Session, form: dict, **extra) -> dict:
    return {
        "form": form,
        "statuses": library.list_statuses(db),
        "locations": library.flatten_locations(db),
        "default_status": library.get_default_status(db),
        **extra,
    }


# Fields a bulk-add carries from one book to the next (everything else on the
# form comes from the ISBN lookup and is cleared): where it lives, its status,
# any shared note, and whether the form should stay open.
_STICKY_FIELDS = ("location_id", "status_id", "notes", "keep_open")


def _sticky_fields(data: dict) -> dict:
    sticky: dict = {}
    for key in _STICKY_FIELDS:
        value = data.get(key)
        if value in (None, ""):
            continue
        if key.endswith("_id"):
            try:
                value = int(value)
            except (TypeError, ValueError):
                continue
        sticky[key] = value
    return sticky


# --------------------------------------------------------------------------- #
# Scanning / creating
# --------------------------------------------------------------------------- #
@router.post("/scan", response_class=HTMLResponse)
async def scan(request: Request, db: Session = Depends(get_db)):
    """Receive a scanned/typed ISBN, look it up, return a prefilled form."""
    form = await _form_dict(request)
    raw = normalize_isbn(form.get("isbn", ""))
    # Preserve the "sticky" choices when this lookup came from an open add form
    # (the in-form Look up button includes them), so bulk-adding keeps working.
    sticky = _sticky_fields(form)

    if not raw:
        return templates.TemplateResponse(
            request,
            "books/_form.html",
            form_context(db, {"isbn": "", **sticky}, error=_("Please scan or type an ISBN.")),
        )

    existing = library.find_by_isbn(db, raw)
    if existing:
        # An ISBN already in the library opens as an edit form; keep its own
        # location/status/notes rather than the bulk form's sticky choices.
        return templates.TemplateResponse(
            request,
            "books/_form.html",
            form_context(
                db,
                book_to_form(existing),
                existing=existing,
                info=_("This ISBN is already in your library: “%s”.") % existing.title,
            ),
        )

    if not is_valid_isbn(raw):
        return templates.TemplateResponse(
            request,
            "books/_form.html",
            form_context(
                db,
                {"isbn": raw, **sticky},
                warning=_("“%s” is not a valid ISBN. You can still fill it in by hand.") % raw,
            ),
        )

    data = await lookup_isbn(raw)
    if not data:
        return templates.TemplateResponse(
            request,
            "books/_form.html",
            form_context(
                db,
                {"isbn": raw, "source": "manual", **sticky},
                warning=_("No catalogue found that ISBN online. Enter the details by hand."),
            ),
        )

    return templates.TemplateResponse(
        request,
        "books/_form.html",
        form_context(db, {**book_to_form(data), **sticky}, looked_up=True),
    )


@router.get("/scan/manual", response_class=HTMLResponse)
def scan_manual(request: Request, db: Session = Depends(get_db)):
    """Empty form for adding a book entirely by hand."""
    return templates.TemplateResponse(
        request,
        "books/_form.html",
        form_context(db, {"source": "manual"}),
    )


@router.post("/books", response_class=HTMLResponse)
async def create_book(request: Request, db: Session = Depends(get_db)):
    data = await _form_dict(request)
    book = library.create_book(db, data)

    # Bulk mode: keep the modal open with a cleared form so the next book can be
    # scanned straight away, carrying over the shelf, status and notes.
    if data.get("keep_open"):
        cleared = {"source": "manual", **_sticky_fields(data)}
        return templates.TemplateResponse(
            request,
            "books/_form.html",
            form_context(db, cleared, added=_("Added “%s”.") % book.title),
            headers={"HX-Trigger": "bookAdded"},
        )

    return _redirect(request, f"/books/{book.id}")


# --------------------------------------------------------------------------- #
# Read-only details (rendered into the modal)
# --------------------------------------------------------------------------- #
@router.get("/books/{book_id}/details", response_class=HTMLResponse)
def book_details(book_id: int, request: Request, db: Session = Depends(get_db)):
    """A compact card for the modal shown when a book is clicked."""
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    return templates.TemplateResponse(request, "books/_details.html", {"book": book})


# --------------------------------------------------------------------------- #
# Editing / deleting
# --------------------------------------------------------------------------- #
@router.get("/books/{book_id}/edit", response_class=HTMLResponse)
def edit_form(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    return templates.TemplateResponse(
        request,
        "books/_form.html",
        form_context(db, book_to_form(book), editing=True),
    )


@router.post("/books/{book_id}", response_class=HTMLResponse)
async def update_book(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    data = await _form_dict(request)
    library.update_book(db, book, data)
    return _redirect(request, f"/books/{book.id}")


@router.post("/books/{book_id}/delete")
def delete_book(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    library.delete_book(db, book)
    return _redirect(request, "/books")


# --------------------------------------------------------------------------- #
# Loans
# --------------------------------------------------------------------------- #
@router.post("/books/{book_id}/lend", response_class=HTMLResponse)
async def lend(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    form = await _form_dict(request)
    if not (form.get("borrower_name") or "").strip():
        raise HTTPException(status_code=400, detail=_("A borrower name is required"))
    library.lend_book(
        db,
        book,
        borrower_name=form["borrower_name"],
        borrower_contact=form.get("borrower_contact"),
        lent_at=_parse_date(form.get("lent_at")),
        due_at=_parse_date(form.get("due_at")),
        notes=form.get("notes"),
        mark_status=form.get("mark_status") == "on",
    )
    return _redirect(request, f"/books/{book.id}")


@router.post("/books/{book_id}/return", response_class=HTMLResponse)
async def return_book(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    form = await _form_dict(request)
    library.return_loan(
        db,
        book,
        returned_at=_parse_date(form.get("returned_at")),
        restore_status=form.get("restore_status", "on") == "on",
    )
    return _redirect(request, f"/books/{book.id}")
