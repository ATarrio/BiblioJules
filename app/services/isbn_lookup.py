"""Online book metadata lookup.

Free, key-less services are used:

* `Open Library <https://openlibrary.org/developers/api>`_ — primary source.
* `Google Books <https://developers.google.com/books>`_ — fallback / enricher.

The public entry points return a normalised dictionary:

    {
        "isbn": "9780140328721",
        "title": "...",
        "subtitle": "...",
        "authors": ["..."],
        "publisher": "...",
        "published_date": "2007",
        "published_year": 2007,
        "description": "...",
        "page_count": 240,
        "language": "eng",
        "cover_url": "https://...",
        "source": "openlibrary",
    }

The service layer is deliberately independent of the database and of the web
framework so it can be reused, tested, or swapped out easily.
"""

from __future__ import annotations

import logging
import re
from typing import Any

import httpx

from ..config import settings

logger = logging.getLogger(__name__)

OPEN_LIBRARY_BOOKS = "https://openlibrary.org/api/books"
OPEN_LIBRARY_SEARCH = "https://openlibrary.org/search.json"
GOOGLE_BOOKS = "https://www.googleapis.com/books/v1/volumes"
COVERS_BASE = "https://covers.openlibrary.org/b/id"


# --------------------------------------------------------------------------- #
# ISBN helpers
# --------------------------------------------------------------------------- #
def normalize_isbn(raw: str) -> str:
    """Strip formatting from a scanned or typed ISBN, keeping digits and X."""
    if not raw:
        return ""
    cleaned = re.sub(r"[^0-9Xx]", "", raw).upper()
    return cleaned


def is_valid_isbn(isbn: str) -> bool:
    """Validate an ISBN-10 or ISBN-13 check digit."""
    isbn = normalize_isbn(isbn)
    if len(isbn) == 10:
        if not re.fullmatch(r"\d{9}[\dX]", isbn):
            return False
        total = sum((10 - i) * (10 if c == "X" else int(c)) for i, c in enumerate(isbn))
        return total % 11 == 0
    if len(isbn) == 13:
        if not isbn.isdigit():
            return False
        total = sum((1 if i % 2 == 0 else 3) * int(c) for i, c in enumerate(isbn))
        return total % 10 == 0
    return False


def extract_year(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    match = re.search(r"(1[5-9]\d\d|20\d\d)", str(value))
    return int(match.group(1)) if match else None


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=settings.isbn_lookup_timeout,
        headers={"User-Agent": settings.user_agent},
        follow_redirects=True,
    )


# --------------------------------------------------------------------------- #
# Providers
# --------------------------------------------------------------------------- #
async def _open_library_by_isbn(client: httpx.AsyncClient, isbn: str) -> dict | None:
    params = {
        "bibkeys": f"ISBN:{isbn}",
        "format": "json",
        "jscmd": "data",
    }
    response = await client.get(OPEN_LIBRARY_BOOKS, params=params)
    response.raise_for_status()
    payload = response.json()
    entry = payload.get(f"ISBN:{isbn}")
    if not entry:
        return None

    cover = entry.get("cover") or {}
    cover_url = cover.get("large") or cover.get("medium") or cover.get("small")

    return {
        "isbn": isbn,
        "title": entry.get("title"),
        "subtitle": entry.get("subtitle"),
        "authors": [a.get("name") for a in entry.get("authors", []) if a.get("name")],
        "publisher": next(
            (p.get("name") for p in entry.get("publishers", []) if p.get("name")),
            None,
        ),
        "published_date": entry.get("publish_date"),
        "published_year": extract_year(entry.get("publish_date")),
        "description": None,
        "page_count": entry.get("number_of_pages"),
        "language": None,
        "cover_url": cover_url,
        "source": "openlibrary",
    }


async def _google_books_by_isbn(client: httpx.AsyncClient, isbn: str) -> dict | None:
    response = await client.get(GOOGLE_BOOKS, params={"q": f"isbn:{isbn}"})
    response.raise_for_status()
    payload = response.json()
    items = payload.get("items") or []
    if not items:
        return None

    info = items[0].get("volumeInfo", {})
    image_links = info.get("imageLinks", {}) or {}
    cover_url = (
        image_links.get("large")
        or image_links.get("medium")
        or image_links.get("thumbnail")
    )
    if cover_url:
        cover_url = cover_url.replace("http://", "https://")

    authors = info.get("authors") or []
    return {
        "isbn": isbn,
        "title": info.get("title"),
        "subtitle": info.get("subtitle"),
        "authors": authors,
        "publisher": info.get("publisher"),
        "published_date": info.get("publishedDate"),
        "published_year": extract_year(info.get("publishedDate")),
        "description": info.get("description"),
        "page_count": info.get("pageCount"),
        "language": info.get("language"),
        "cover_url": cover_url,
        "source": "googlebooks",
    }


def _merge(*records: dict | None) -> dict | None:
    """Merge provider records, earlier records win, later ones fill gaps."""
    records = [r for r in records if r]
    if not records:
        return None
    merged: dict = dict(records[0])
    for record in records[1:]:
        for key, value in record.items():
            if key == "source":
                continue
            if merged.get(key) in (None, "", []):
                merged[key] = value
    return merged


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #
async def lookup_isbn(raw_isbn: str) -> dict | None:
    """Look up a single ISBN across all providers. Returns ``None`` if unknown."""
    isbn = normalize_isbn(raw_isbn)
    if not isbn:
        return None

    async with _client() as client:
        results: list[dict | None] = []
        for provider in (_open_library_by_isbn, _google_books_by_isbn):
            try:
                results.append(await provider(client, isbn))
            except Exception as exc:  # noqa: BLE001 - never let one API break a scan
                logger.warning("ISBN lookup provider %s failed: %s", provider.__name__, exc)
                results.append(None)

    merged = _merge(*results)
    if merged:
        merged["isbn"] = isbn
    return merged


async def _open_library_search(client: httpx.AsyncClient, query: str, limit: int) -> list[dict]:
    params = {
        "q": query,
        "limit": limit,
        "fields": "key,title,subtitle,author_name,first_publish_year,isbn,publisher,cover_i,language,number_of_pages_median",
    }
    response = await client.get(OPEN_LIBRARY_SEARCH, params=params)
    response.raise_for_status()
    docs = response.json().get("docs", [])

    results: list[dict] = []
    for doc in docs:
        cover_url = (
            f"{COVERS_BASE}/{doc['cover_i']}-M.jpg" if doc.get("cover_i") else None
        )
        isbns = doc.get("isbn") or []
        # Prefer an ISBN-13 if one is present.
        isbn = next((i for i in isbns if len(i) == 13), None) or (isbns[0] if isbns else None)
        results.append(
            {
                "isbn": isbn,
                "title": doc.get("title"),
                "subtitle": doc.get("subtitle"),
                "authors": doc.get("author_name") or [],
                "publisher": (doc.get("publisher") or [None])[0],
                "published_date": None,
                "published_year": doc.get("first_publish_year"),
                "description": None,
                "page_count": doc.get("number_of_pages_median"),
                "language": (doc.get("language") or [None])[0],
                "cover_url": cover_url,
                "source": "openlibrary",
            }
        )
    return results


async def _google_search(client: httpx.AsyncClient, query: str, limit: int) -> list[dict]:
    response = await client.get(GOOGLE_BOOKS, params={"q": query, "maxResults": limit})
    response.raise_for_status()
    items = response.json().get("items", [])

    results: list[dict] = []
    for item in items:
        info = item.get("volumeInfo", {})
        identifiers = info.get("industryIdentifiers", []) or []
        isbn = None
        for ident in identifiers:
            if ident.get("type") == "ISBN_13":
                isbn = ident.get("identifier")
                break
        if not isbn:
            isbn = next((i.get("identifier") for i in identifiers), None)

        image_links = info.get("imageLinks", {}) or {}
        cover_url = image_links.get("thumbnail") or image_links.get("smallThumbnail")
        if cover_url:
            cover_url = cover_url.replace("http://", "https://")

        results.append(
            {
                "isbn": isbn,
                "title": info.get("title"),
                "subtitle": info.get("subtitle"),
                "authors": info.get("authors") or [],
                "publisher": info.get("publisher"),
                "published_date": info.get("publishedDate"),
                "published_year": extract_year(info.get("publishedDate")),
                "description": info.get("description"),
                "page_count": info.get("pageCount"),
                "language": info.get("language"),
                "cover_url": cover_url,
                "source": "googlebooks",
            }
        )
    return results


async def search_books(query: str, limit: int = 12) -> list[dict]:
    """Free-text search (used to add wishlist items without an ISBN in hand)."""
    query = (query or "").strip()
    if not query:
        return []

    async with _client() as client:
        results: list[dict] = []
        try:
            results = await _open_library_search(client, query, limit)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Open Library search failed: %s", exc)

        if len(results) < 3:
            try:
                google = await _google_search(client, query, limit)
                seen = {(r.get("title") or "").lower() for r in results}
                results.extend(r for r in google if (r.get("title") or "").lower() not in seen)
            except Exception as exc:  # noqa: BLE001
                logger.warning("Google Books search failed: %s", exc)

    return results[:limit]
