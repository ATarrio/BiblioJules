"""HTML page routes (server-rendered with Jinja2)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy.orm import Session

from .. import i18n
from ..database import get_db
from ..i18n import _
from ..services import library
from ..templating import templates

router = APIRouter()

# How long a language choice sticks (a year).
_LANGUAGE_COOKIE_MAX_AGE = 60 * 60 * 24 * 365


def _opt_int(value):
    try:
        return int(value) if value not in (None, "", "all") else None
    except (TypeError, ValueError):
        return None


def parse_filters(request: Request) -> dict:
    qp = request.query_params
    return {
        "search": (qp.get("search") or "").strip() or None,
        "status_id": _opt_int(qp.get("status")),
        "location_id": _opt_int(qp.get("location")),
        "author_id": _opt_int(qp.get("author")),
        "publisher_id": _opt_int(qp.get("publisher")),
        "loaned": qp.get("loaned") or None,
        "sort": qp.get("sort") or "recent",
    }


def catalog_context(db: Session, filters: dict) -> dict:
    books = library.query_books(db, **filters)
    return {
        "books": books,
        "filters": filters,
        "statuses": library.list_statuses(db),
        "locations": library.flatten_locations(db),
        "authors": library.list_authors(db),
        "publishers": library.list_publishers(db),
        "book_count": len(books),
    }


@router.get("/language")
def switch_language(request: Request):
    """Remember the chosen language in a cookie and go back where we came from."""
    code = i18n.normalize_language(request.query_params.get("lang"))
    target = request.query_params.get("next") or request.headers.get("referer") or "/"
    # Only ever redirect back into this site (no open redirects).
    if not target.startswith("/") or target.startswith("//"):
        target = "/"
    response = RedirectResponse(target, status_code=303)
    response.set_cookie(
        "lang", code, max_age=_LANGUAGE_COOKIE_MAX_AGE, samesite="lax", path="/"
    )
    return response


@router.get("/", response_class=HTMLResponse)
def dashboard(request: Request, db: Session = Depends(get_db)):
    recent = library.query_books(db, sort="recent")[:6]
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "stats": library.get_stats(db),
            "status_counts": library.status_counts(db),
            "recent": recent,
            "active_loans": [
                loan
                for book in library.query_books(db, loaned="loaned")
                for loan in [book.active_loan]
                if loan
            ],
        },
    )


@router.get("/books", response_class=HTMLResponse)
def books_page(request: Request, db: Session = Depends(get_db)):
    filters = parse_filters(request)
    context = catalog_context(db, filters)
    # When HTMX asks for just the results (e.g. a filter changed), return the
    # grid partial; otherwise render the whole page. The URL stays /books, so
    # filters are shareable and the browser back button behaves.
    if request.headers.get("HX-Request") == "true":
        return templates.TemplateResponse(request, "books/_grid.html", context)
    return templates.TemplateResponse(request, "books/list.html", context)


@router.get("/books/grid", response_class=HTMLResponse)
def books_grid(request: Request, db: Session = Depends(get_db)):
    """HTMX partial: just the results grid, used when filters change."""
    filters = parse_filters(request)
    return templates.TemplateResponse(
        request, "books/_grid.html", catalog_context(db, filters)
    )


@router.get("/books/{book_id}", response_class=HTMLResponse)
def book_detail(book_id: int, request: Request, db: Session = Depends(get_db)):
    book = library.get_book(db, book_id)
    if book is None:
        return templates.TemplateResponse(
            request, "404.html", {"message": _("That book is not in the library.")}, status_code=404
        )
    return templates.TemplateResponse(
        request,
        "books/detail.html",
        {
            "book": book,
            "statuses": library.list_statuses(db),
            "locations": library.flatten_locations(db),
        },
    )


@router.get("/locations", response_class=HTMLResponse)
def locations_page(request: Request, db: Session = Depends(get_db)):
    return templates.TemplateResponse(
        request,
        "locations/list.html",
        {"locations": library.flatten_locations(db)},
    )


@router.get("/statuses", response_class=HTMLResponse)
def statuses_page(request: Request, db: Session = Depends(get_db)):
    return templates.TemplateResponse(
        request,
        "statuses/list.html",
        {"statuses": library.list_statuses(db), "counts": dict(library.status_counts(db))},
    )


@router.get("/discover", response_class=HTMLResponse)
def discover_page(request: Request, db: Session = Depends(get_db)):
    """Search the online catalogues to add wishlist items without an ISBN."""
    return templates.TemplateResponse(
        request,
        "discover.html",
        {
            "statuses": library.list_statuses(db),
            "locations": library.flatten_locations(db),
            "wishlist": library.get_status_by_slug(db, "wishlist"),
        },
    )
