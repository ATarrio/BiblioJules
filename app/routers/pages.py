"""HTML page routes (server-rendered with Jinja2)."""

from __future__ import annotations

from datetime import date
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..services import library
from ..templating import templates

router = APIRouter()


def _opt_int(value):
    try:
        return int(value) if value not in (None, "", "all") else None
    except (TypeError, ValueError):
        return None


def parse_filters(request: Request) -> dict:
    qp = request.query_params
    direction = (qp.get("dir") or "").lower()
    return {
        "search": (qp.get("search") or "").strip() or None,
        "status_id": _opt_int(qp.get("status")),
        "location_id": _opt_int(qp.get("location")),
        "author_id": _opt_int(qp.get("author")),
        "publisher_id": _opt_int(qp.get("publisher")),
        "loaned": qp.get("loaned") or None,
        "saga": (qp.get("saga") or "").strip() or None,
        "read_status": (qp.get("read_status") or "").strip() or None,
        "sort": qp.get("sort") or "recent",
        "dir": direction if direction in ("asc", "desc") else None,
        "page": max(1, _opt_int(qp.get("page")) or 1),
    }


# Columns the catalog can be ordered by, with the direction used on first
# click (Year naturally reads newest-first). Shared with the JSON API's
# ``/api/meta`` so clients discover sort options from one place.
SORT_FIELDS = [
    ("title", "Title", False),
    ("author", "Author", False),
    ("saga", "Saga", False),
    ("year", "Year", True),
]

# filter dict key -> query-string name used by the catalog form.
_SORT_FILTER_PARAMS = [
    ("search", "search"),
    ("status", "status_id"),
    ("location", "location_id"),
    ("author", "author_id"),
    ("publisher", "publisher_id"),
    ("loaned", "loaned"),
    ("saga", "saga"),
    ("read_status", "read_status"),
]


def _sort_links(filters: dict) -> list[dict]:
    """Clickable header links that toggle each column's sort direction."""
    base = {
        param: filters[key]
        for param, key in _SORT_FILTER_PARAMS
        if filters.get(key) not in (None, "")
    }

    def url(params: dict) -> str:
        return "/books?" + urlencode(params) if params else "/books"

    links = [
        {
            "key": "recent",
            "label": _("Recently added"),
            "url": url(base),
            "active": filters.get("sort") in (None, "", "recent"),
            "arrow": "",
        }
    ]
    for key, label, default_desc in SORT_FIELDS:
        active = filters.get("sort") == key
        current = filters.get("dir") or ("desc" if default_desc else "asc")
        if active:
            next_dir = "asc" if current == "desc" else "desc"
            arrow = "▼" if current == "desc" else "▲"
        else:
            next_dir = "desc" if default_desc else "asc"
            arrow = ""
        links.append(
            {
                "key": key,
                "label": _(label),
                "url": url({**base, "sort": key, "dir": next_dir}),
                "active": active,
                "arrow": arrow,
            }
        )
    return links


def _page_url(filters: dict, page: int) -> str:
    """A catalog URL for one page, keeping every active filter and sort."""
    params = {
        param: filters[key]
        for param, key in _SORT_FILTER_PARAMS
        if filters.get(key) not in (None, "")
    }
    params["sort"] = filters.get("sort") or "recent"
    if filters.get("dir"):
        params["dir"] = filters["dir"]
    if page > 1:
        params["page"] = page
    return "/books?" + urlencode(params)


PER_PAGE = 60


def catalog_context(db: Session, filters: dict) -> dict:
    query = {
        key: value
        for key, value in filters.items()
        if key not in ("dir", "page")
    }
    direction = filters.get("dir")
    if direction is not None:
        query["descending"] = direction == "desc"

    total = library.count_books(db, **query)
    pages = max(1, (total + PER_PAGE - 1) // PER_PAGE)
    page = min(max(1, int(filters.get("page") or 1)), pages)
    books = library.query_books(
        db, limit=PER_PAGE, offset=(page - 1) * PER_PAGE, **query
    )
    return {
        "books": books,
        "filters": filters,
        "sort_links": _sort_links(filters),
        "statuses": library.list_statuses(db),
        "locations": library.flatten_locations(db),
        "authors": library.list_authors(db),
        "publishers": library.list_publishers(db),
        "sagas": library.list_sagas(db),
        "book_count": total,
        "page": page,
        "pages": pages,
        "prev_url": _page_url(filters, page - 1) if page > 1 else None,
        "next_url": _page_url(filters, page + 1) if page < pages else None,
    }


@router.get("/", response_class=HTMLResponse)
def dashboard(request: Request, db: Session = Depends(get_db)):
    recent = library.query_books(db, sort="recent", limit=6)
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "stats": library.get_stats(db),
            "status_counts": library.status_counts(db),
            "recent": recent,
            "active_loans": library.list_active_loans(db),
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
        {
            "locations": library.flatten_locations(db),
            "error": request.query_params.get("error"),
        },
    )


@router.get("/statuses", response_class=HTMLResponse)
def statuses_page(request: Request, db: Session = Depends(get_db)):
    return templates.TemplateResponse(
        request,
        "statuses/list.html",
        {
            "statuses": library.list_statuses(db),
            "counts": dict(library.status_counts(db)),
            "error": request.query_params.get("error"),
        },
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


@router.get("/settings", response_class=HTMLResponse)
def settings_page(request: Request):
    """The browser's configuration: accent colour, language and light/dark.

    All three are per browser (a cookie, a cookie, and ``localStorage``), so the
    page renders no data of its own — the templates read the current values.
    """
    return templates.TemplateResponse(request, "settings.html", {})


@router.get("/reading", response_class=HTMLResponse)
def reading_page(request: Request):
    """Personal reading stats dashboard page (per-device, local only)."""
    return templates.TemplateResponse(
        request, "reading.html", {"current_year": date.today().year}
    )


@router.get("/reading-goals", response_class=HTMLResponse)
def reading_goals_page(request: Request):
    """Goals live on the reading page; keep the old URL working."""
    return RedirectResponse("/reading#reading-goals-host", status_code=303)


@router.get("/wantlist", response_class=HTMLResponse)
def wantlist_page(request: Request):
    """Personal want-to-read list (per-device, local only)."""
    return templates.TemplateResponse(request, "wantlist.html", {})


