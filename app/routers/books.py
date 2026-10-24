"""Book CRUD, loans, scanning and editing (form + HTMX endpoints)."""

from __future__ import annotations

from datetime import date, datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..services import library
from ..services.covers import (
    MAX_COVER_BYTES,
    covers_dir,
    delete_cover,
    new_cover_name,
    sniff_image,
)
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


def _fragment_error(request: Request, message: str, status_code: int = 400):
    """A small HTML error for HTMX, a normal HTTP error otherwise."""
    if request.headers.get("HX-Request"):
        return templates.TemplateResponse(
            request, "_fragment_error.html", {"message": message}, status_code=status_code
        )
    raise HTTPException(status_code=status_code, detail=message)


def _sniff_image(content: bytes) -> str | None:
    """Return a safe extension based on the file's own bytes, not its name."""
    return sniff_image(content)


def _covers_dir():
    return covers_dir()


def _delete_cover(cover_url: str | None) -> None:
    delete_cover(cover_url)


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
        "sagas": library.list_sagas(db),
        **extra,
    }


def _book_form_error(
    request: Request, db: Session, data: dict, message: str, *, editing: bool = False
):
    return templates.TemplateResponse(
        request,
        "books/_form.html",
        form_context(db, data, error=message, editing=editing),
        status_code=400,
    )


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


# Fields an online lookup may fill in on a book that is already in the library.
# Only blank ones are touched, so the user's own data always wins.
_LOOKUP_FIELDS = (
    "title",
    "subtitle",
    "authors",
    "publisher",
    "published_date",
    "page_count",
    "language",
    "description",
    "cover_url",
)

# Translated labels used to tell the user which fields a lookup filled in.
_LOOKUP_LABELS = {
    "title": "Title",
    "subtitle": "Subtitle",
    "authors": "Authors",
    "publisher": "Publisher",
    "published_date": "Published",
    "page_count": "Pages",
    "language": "Language",
    "description": "Description",
    "cover_url": "Cover",
}


def _is_blank(value) -> bool:
    """True for values that mean 'nothing here' on the book form."""
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, (list, tuple, dict, set)):
        return not value
    if isinstance(value, (int, float)):
        return value == 0
    return False


def _merge_lookup(current: dict, fresh: dict) -> tuple[dict, list[str]]:
    """Fill the blank fields of ``current`` with values from ``fresh``.

    Returns the merged form data and the keys that were filled, so the caller
    can report what changed. Values the user already has are never replaced.
    """
    merged = dict(current)
    filled: list[str] = []
    for key in _LOOKUP_FIELDS:
        if not _is_blank(merged.get(key)):
            continue
        value = fresh.get(key)
        if _is_blank(value):
            continue
        merged[key] = value
        filled.append(key)
    return merged, filled


# Fields the edit form always submits; when re-rendering it after a lookup we
# take these from the request so unsaved typing is not thrown away.
_FORM_TEXT_FIELDS = (
    "isbn",
    "title",
    "subtitle",
    "authors",
    "publisher",
    "published_date",
    "page_count",
    "language",
    "description",
    "notes",
    "saga",
    "saga_number",
    "cover_url",
    "cover_type",
    "read_status",
    "source",
    "score",
    "keep_open",
)
_FORM_ID_FIELDS = ("location_id", "status_id")


def _with_unsaved_edits(current: dict, form: dict) -> dict:
    """Overlay the values currently in the open edit form onto ``current``."""
    merged = dict(current)
    for key in _FORM_TEXT_FIELDS:
        if key in form:
            merged[key] = form.get(key)
    for key in _FORM_ID_FIELDS:
        if key not in form:
            continue
        value = form.get(key)
        if value in (None, ""):
            merged[key] = None
            continue
        try:
            merged[key] = int(value)
        except (TypeError, ValueError):
            continue
    return merged


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
        # Online details the record is still missing are filled in so the user
        # can review and save them — existing values are never overwritten.
        current = book_to_form(existing)
        # When the lookup comes from this book's own edit form, keep whatever
        # the user has typed so far; from the add form, the stored book wins.
        if str(form.get("id") or "") == str(existing.id):
            current = _with_unsaved_edits(current, form)
        data = await lookup_isbn(raw)
        if not data:
            return templates.TemplateResponse(
                request,
                "books/_form.html",
                form_context(
                    db,
                    current,
                    existing=existing,
                    warning=_(
                        "This ISBN is already in your library: “%s”. "
                        "No extra details were found online."
                    )
                    % existing.title,
                ),
            )
        merged, filled = _merge_lookup(current, book_to_form(data))
        if filled:
            labels = ", ".join(_(_LOOKUP_LABELS[key]) for key in filled)
            message = _(
                "This ISBN is already in your library: “%s”. "
                "Filled in %s from the online catalogue — review and save to keep it."
            ) % (existing.title, labels)
        else:
            message = _(
                "This ISBN is already in your library: “%s”. "
                "It already had everything the online catalogue knows."
            ) % existing.title
        return templates.TemplateResponse(
            request,
            "books/_form.html",
            form_context(db, merged, existing=existing, info=message),
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
    try:
        book = library.create_book(db, data)
    except ValueError as exc:
        db.rollback()
        return _book_form_error(request, db, data, str(exc))
    except IntegrityError:
        db.rollback()
        return _book_form_error(
            request,
            db,
            data,
            _("A book with that ISBN is already in the library."),
        )

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
    try:
        library.update_book(db, book, data)
    except ValueError as exc:
        db.rollback()
        return _book_form_error(request, db, data, str(exc), editing=True)
    except IntegrityError:
        db.rollback()
        return _book_form_error(
            request,
            db,
            data,
            _("A book with that ISBN is already in the library."),
            editing=True,
        )
    return _redirect(request, f"/books/{book.id}")


@router.post("/books/{book_id}/delete")
def delete_book(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    cover_url = book.cover_url
    library.delete_book(db, book)
    _delete_cover(cover_url)
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
        return _fragment_error(request, _("A borrower name is required"))
    try:
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
    except ValueError as exc:
        db.rollback()
        return _fragment_error(request, str(exc))
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
        restore_status=form.get("restore_status") == "on",
    )
    return _redirect(request, f"/books/{book.id}")


# --------------------------------------------------------------------------- #
# Cover upload
# --------------------------------------------------------------------------- #
@router.post("/books/{book_id}/cover", response_class=HTMLResponse)
async def upload_cover(book_id: int, request: Request, db: Session = Depends(get_db)):
    """Save an uploaded cover image for a book."""
    try:
        length = int(request.headers.get("content-length") or 0)
    except ValueError:
        length = 0
    if length and length > MAX_COVER_BYTES + 64 * 1024:
        return _fragment_error(request, _("That image is too large (the limit is 10 MB)."), 413)

    book = library.get_book(db, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    form = await _form_dict(request)
    file = form.get("cover")
    if not file or not getattr(file, "filename", ""):
        return _fragment_error(request, _("Please choose an image first."))

    content = await file.read(MAX_COVER_BYTES + 1)
    if not content:
        return _fragment_error(request, _("That file is empty."))
    if len(content) > MAX_COVER_BYTES:
        return _fragment_error(request, _("That image is too large (the limit is 10 MB)."), 413)

    suffix = _sniff_image(content)
    if suffix is None:
        return _fragment_error(request, _("That file is not a supported image."))

    # Random names stop one user from enumerating (or guessing) another's
    # covers. The sync id keeps two devices from overwriting each other's file.
    safe_name = new_cover_name(book, suffix)
    old_url = book.cover_url
    try:
        (_covers_dir() / safe_name).write_bytes(content)
    except OSError:
        return _fragment_error(request, _("The cover could not be saved."), 500)
    book.cover_url = f"/covers/{safe_name}"
    try:
        db.commit()
    except Exception:
        db.rollback()
        (_covers_dir() / safe_name).unlink(missing_ok=True)
        return _fragment_error(request, _("The cover could not be saved."))
    _delete_cover(old_url)
    return _redirect(request, f"/books/{book.id}")


# --------------------------------------------------------------------------- #
# Want-to-read list (local-only)
# --------------------------------------------------------------------------- #
@router.post("/wantlist/add", response_class=HTMLResponse)
async def add_to_wantlist(request: Request, db: Session = Depends(get_db)):
    """Add a book from the library to the local want-to-read list."""
    from ..services.stats import add_want_entry

    form = await _form_dict(request)
    book_id = form.get("book_id") or request.query_params.get("book_id")
    try:
        identifier = int(book_id)
    except (TypeError, ValueError):
        return _fragment_error(request, _("No book selected."))
    book = library.get_book(db, identifier)
    if book is None:
        raise HTTPException(status_code=404, detail=_("Book not found"))
    entry = {
        "id": f"want-{book.id}",
        "isbn": book.isbn,
        "title": book.title,
        "authors": ", ".join(book.author_names),
        "publisher": book.publisher.name if book.publisher else None,
        "notes": "",
        "added_at": None,
    }
    user = getattr(request.state, "user", None)
    add_want_entry(entry, user_id=getattr(user, "id", None))
    return _redirect(request, f"/books/{book.id}")
