"""Online discovery: free-text search to add wishlist items.

When a book is not in your hands you rarely have its ISBN, so this lets you
search the online catalogues by title/author and prefill the normal add form.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from ..database import get_db
from ..services import library
from ..services.isbn_lookup import search_books
from ..templating import templates
from .books import form_context

router = APIRouter()


@router.post("/discover/search", response_class=HTMLResponse)
async def discover_search(request: Request, db: Session = Depends(get_db)):
    form = await request.form()
    query = (form.get("q") or "").strip()
    results = await search_books(query) if query else []

    # Present authors as a comma-joined string for the hidden form fields.
    for result in results:
        authors = result.get("authors") or []
        result["authors_str"] = ", ".join(authors) if isinstance(authors, list) else authors

    wishlist = library.get_status_by_slug(db, "wishlist")
    return templates.TemplateResponse(
        request,
        "discover_results.html",
        {"results": results, "query": query, "wishlist": wishlist},
    )


@router.post("/discover/prefill", response_class=HTMLResponse)
async def discover_prefill(request: Request, db: Session = Depends(get_db)):
    """Turn a chosen search result back into the standard add form."""
    form = await request.form()
    data = {key: value for key, value in form.items()}
    wishlist = library.get_status_by_slug(db, "wishlist")
    # Default new discovery entries to the wishlist.
    if wishlist:
        data.setdefault("status_id", wishlist.id)
    return templates.TemplateResponse(
        request, "books/_form.html", form_context(db, data, from_discovery=True)
    )
