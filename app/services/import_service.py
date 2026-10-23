"""Bulk import from Goodreads / StoryGraph CSV exports.

Reads a CSV file (usually exported from Goodreads or StoryGraph) and either:
* creates books in the library (if the user selects them), or
* adds them to the local want-to-read list.

Expected CSV headers (case-insensitive):
  ISBN, Title, Author, Author(s), Publisher, Publication Year,
  Read Status, Read Count, Rating, Review Date, Date Added, Exclusive Shelf,
  Description, Pages, Language, Cover URL, etc.

Only ISBN / Title + Author are required; everything else is optional.
"""

from __future__ import annotations

import csv
import io
from datetime import date
from typing import Any

from .isbn_lookup import http_client, lookup_isbn, normalize_isbn


def parse_import_csv(text: str, delimiter: str = ",") -> list[dict]:
    """Parse CSV text and return a list of row dicts with standardised keys."""
    f = io.StringIO(text, newline="")
    reader = csv.DictReader(f, delimiter=delimiter)
    rows: list[dict] = []
    for raw in reader:
        if not raw:
            continue
        # Normalise header names to lowercase with underscores.
        row = {k.lower().strip().replace(" ", "_").replace("(", "").replace(")", ""): v for k, v in raw.items() if k}
        # Standardise common Goodreads / StoryGraph headers.
        for alias in ("author", "author_s", "author_name", "authors"):
            if alias in row and row[alias]:
                row["authors"] = row[alias]
                break
        # Pick title from common headers.
        for alias in ("title", "book_title", "name"):
            if alias in row and row[alias]:
                row["title"] = row[alias]
                break
        # ISBN from common headers.
        for alias in ("isbn", "isbn_10", "isbn_13", "isbn13"):
            if alias in row and row[alias]:
                row["isbn"] = normalize_isbn(row[alias])
                break
        # Year.
        for alias in ("publication_year", "published_year", "year_published", "year", "publish_year"):
            if alias in row and row[alias]:
                row["published_year"] = str(row[alias]).strip()
                break
        # Rating / score.
        for alias in ("rating", "my_rating", "rating_2", "rating_5"):
            if alias in row and row[alias]:
                try:
                    val = float(str(row[alias]).replace(",", ".").strip())
                    if 0 <= val <= 5:
                        row["score"] = val
                except ValueError:
                    pass
                break
        # Pages.
        for alias in ("number_of_pages", "pages", "page_count", "pages_", ):
            if alias in row and row[alias]:
                try:
                    row["page_count"] = int(str(row[alias]).strip())
                except ValueError:
                    pass
                break
        # Read status mapping. Normalise separators first and match whole
        # values: a substring check made "currently reading" contain "read"
        # and imported in-progress books as finished.
        status_raw = str(row.get("read_status") or row.get("exclusive_shelf") or "").strip().lower()
        status_key = status_raw.replace("-", "_").replace(" ", "_")
        status_map = {
            "read": "read",
            "to_read": "to_read",
            "want_to_read": "to_read",
            "currently_reading": "currently_reading",
            "reading": "currently_reading",
            "unread": "unread",
            "not_read": "unread",
            "dnf": "dnf",
            "did_not_finish": "dnf",
        }
        mapped_status = status_map.get(status_key)
        if mapped_status:
            row["read_status"] = mapped_status
        elif "read_status" in row:
            # An unknown shelf name must not reach the library as a status.
            row.pop("read_status", None)
        # Date added.
        for alias in ("date_added", "date_added_", "date_added_2"):
            if alias in row and row[alias]:
                row["date_added"] = str(row[alias]).strip()
                break
        # Description.
        if "description" in row and row["description"]:
            row["description"] = str(row["description"]).strip()
        # Cover URL.
        if "cover_url" in row and row["cover_url"]:
            row["cover_url"] = str(row["cover_url"]).strip()
        # Publisher.
        if "publisher" in row and row["publisher"]:
            row["publisher"] = str(row["publisher"]).strip()
        # Language.
        if "language" in row and row["language"]:
            row["language"] = str(row["language"]).strip()
        rows.append(row)
    return rows


async def _enrich_with(rows: list[dict], client, db=None) -> list[dict]:
    """The per-row work, sharing one HTTP client for the whole batch."""
    enriched = []
    for row in rows:
        if row.get("isbn") and (not row.get("title") or not row.get("authors")):
            lookup = await lookup_isbn(row["isbn"], client=client)
            if lookup:
                if not row.get("title") and lookup.get("title"):
                    row["title"] = lookup.get("title")
                if not row.get("authors") and lookup.get("authors"):
                    row["authors"] = lookup.get("authors") if isinstance(lookup.get("authors"), str) else ", ".join(lookup.get("authors") or [])
                if lookup.get("publisher") and not row.get("publisher"):
                    row["publisher"] = lookup.get("publisher")
                if lookup.get("published_date") and not row.get("published_year"):
                    row["published_year"] = str(lookup.get("published_year") or lookup.get("published_date"))
                if lookup.get("description") and not row.get("description"):
                    row["description"] = lookup.get("description")
                if lookup.get("cover_url") and not row.get("cover_url"):
                    row["cover_url"] = lookup.get("cover_url")
                if lookup.get("page_count") and not row.get("page_count"):
                    row["page_count"] = lookup.get("page_count")
                if lookup.get("language") and not row.get("language"):
                    row["language"] = lookup.get("language")
        enriched.append(row)
    return enriched


async def enrich_import_rows(rows: list[dict], db=None) -> list[dict]:
    """Look up missing metadata by ISBN for rows without a title or author."""
    # One pool for the whole batch: a 200-row import used to open 200 clients.
    async with http_client() as client:
        return await _enrich_with(rows, client, db)
