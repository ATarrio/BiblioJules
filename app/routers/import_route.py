"""CSV import endpoints (Goodreads / StoryGraph)."""

from __future__ import annotations

import json
import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..services import import_service
from ..services.isbn_lookup import normalize_isbn
from ..services.library import create_book, find_by_isbn
from ..services.stats import add_want_entry, load_want_list
from ..templating import templates

router = APIRouter(prefix="/import", tags=["import"])
logger = logging.getLogger(__name__)

#: A CSV export from Goodreads is a few hundred kilobytes; 20 MB is generous
#: and keeps one request from filling the disk or exhausting memory.
MAX_CSV_BYTES = 20 * 1024 * 1024
MAX_IMPORT_ROWS = 5000


def _user_id(request: Request) -> int | None:
    user = getattr(request.state, "user", None)
    return getattr(user, "id", None)


def _too_large(request: Request) -> HTMLResponse | None:
    try:
        length = int(request.headers.get("content-length") or 0)
    except ValueError:
        length = 0
    if length and length > MAX_CSV_BYTES + 64 * 1024:
        return templates.TemplateResponse(
            request,
            "_fragment_error.html",
            {"message": _("That file is too large (the limit is 20 MB).")},
            status_code=413,
        )
    return None


def _error(request: Request, message: str, status_code: int = 400):
    if request.headers.get("HX-Request"):
        return templates.TemplateResponse(
            request, "_fragment_error.html", {"message": message}, status_code=status_code
        )
    raise HTTPException(status_code=status_code, detail=message)


async def _form_dict(request: Request) -> dict:
    form = await request.form()
    return {key: value for key, value in form.items()}


@router.get("", response_class=HTMLResponse)
def import_page(request: Request):
    """The import page: upload a CSV and choose what to do with it."""
    return templates.TemplateResponse(request, "import.html", {})


@router.post("/csv", response_class=HTMLResponse)
async def import_csv(request: Request, db: Session = Depends(get_db)):
    """Receive a CSV upload and return a preview of what will be imported."""
    if (too_large := _too_large(request)) is not None:
        return too_large
    form = await _form_dict(request)
    upload = form.get("file")
    if not upload or not getattr(upload, "filename", ""):
        return _error(request, _("Please choose a CSV file first."))

    content = await upload.read(MAX_CSV_BYTES + 1)
    if len(content) > MAX_CSV_BYTES:
        return _error(request, _("That file is too large (the limit is 20 MB)."), 413)
    text = content.decode("utf-8-sig", errors="replace")
    rows = import_service.parse_import_csv(text)
    if not rows:
        return _error(request, _("No rows found in that CSV."))
    if len(rows) > MAX_IMPORT_ROWS:
        return _error(
            request,
            _("That CSV has too many rows (the limit is %(count)s).")
            % {"count": MAX_IMPORT_ROWS},
            413,
        )

    # Enrich rows with online metadata where possible.
    rows = await import_service.enrich_import_rows(rows, db=db)

    # Flag duplicates already in the library.
    for row in rows:
        row["already_in_library"] = bool(
            row.get("isbn") and find_by_isbn(db, row["isbn"])
        )

    return templates.TemplateResponse(
        request,
        "import_preview.html",
        {"rows": rows, "total": len(rows)},
    )


@router.post("/confirm", response_class=HTMLResponse)
async def confirm_import(request: Request, db: Session = Depends(get_db)):
    """Actually import the selected rows into the library."""
    if (too_large := _too_large(request)) is not None:
        return too_large
    form = await _form_dict(request)
    rows_json = form.get("rows_json") or "[]"
    try:
        rows = json.loads(rows_json)
    except (TypeError, json.JSONDecodeError):
        return _error(request, _("Invalid data."))
    if not isinstance(rows, list):
        return _error(request, _("Invalid data."))
    if len(rows) > MAX_IMPORT_ROWS:
        return _error(
            request,
            _("That import has too many rows (the limit is %(count)s).")
            % {"count": MAX_IMPORT_ROWS},
            413,
        )

    user_id = _user_id(request)
    existing_want = {
        (i.get("title") or "").strip().lower()
        for i in load_want_list(user_id=user_id)
        if isinstance(i, dict)
    }
    imported = 0
    skipped = 0
    added_to_wantlist = 0
    want_entries: list[dict] = []

    try:
        for row in rows:
            if not isinstance(row, dict) or not row.get("selected"):
                continue

            title = str(row.get("title") or "").strip() or "Untitled"
            authors = str(row.get("authors") or "")
            isbn = normalize_isbn(row.get("isbn") or "") or None

            # A CSV row with no ISBN cannot be matched against the library, so it
            # belongs on the want-to-read list instead.
            if not isbn:
                if title.lower() in existing_want:
                    skipped += 1
                    continue
                want_entries.append(
                    {
                        "id": f"want-{uuid.uuid4().hex}",
                        "isbn": None,
                        "title": title,
                        "authors": authors,
                        "publisher": row.get("publisher"),
                        "notes": "",
                        "added_at": None,
                    }
                )
                existing_want.add(title.lower())
                added_to_wantlist += 1
                continue

            if find_by_isbn(db, isbn):
                skipped += 1
                continue

            create_book(
                db,
                {
                    "isbn": isbn,
                    "title": title,
                    "authors": authors,
                    "publisher": row.get("publisher"),
                    "published_date": str(row.get("published_year") or "") or None,
                    "page_count": row.get("page_count"),
                    "language": row.get("language"),
                    "cover_url": row.get("cover_url"),
                    "description": row.get("description"),
                    "score": row.get("score"),
                    "read_status": row.get("read_status"),
                    "source": "csv_import",
                },
                commit=False,
            )
            imported += 1
        # One transaction for the whole batch: a bad row rolls back every book
        # rather than leaving a half-finished import behind.
        db.commit()
    except Exception:  # noqa: BLE001 - turn any bad row into a usable message
        db.rollback()
        logger.exception("CSV import failed")
        return _error(
            request,
            _("The import could not be completed. Nothing was added; please check the file."),
        )

    for entry in want_entries:
        add_want_entry(entry, user_id=user_id)

    return templates.TemplateResponse(
        request,
        "import_result.html",
        {"imported": imported, "skipped": skipped, "added_to_wantlist": added_to_wantlist},
    )
