"""Library business logic.

All database manipulation lives behind these functions so the web layer stays
thin and the rules (how a book is created, what "lent out" means, how filters
combine) live in exactly one place.
"""

from __future__ import annotations

import re
from datetime import date

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.orm import Session, selectinload

from ..book_fields import COVER_TYPE_SLUGS, MAX_SCORE, MIN_SCORE, READ_STATUS_SLUGS, SCORE_STEP
from ..i18n import _
from ..models import Author, Book, Loan, Location, Publisher, Status
from ..models.common import utc_now
from . import tombstones
from .isbn_lookup import extract_year, is_valid_isbn, normalize_isbn

# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
BOOK_LOAD_OPTIONS = (
    selectinload(Book.authors),
    selectinload(Book.publisher),
    selectinload(Book.location),
    selectinload(Book.status),
    selectinload(Book.loans),
)


def slugify(value: str) -> str:
    import re

    value = re.sub(r"[^\w\s-]", "", (value or "").lower()).strip()
    return re.sub(r"[\s_-]+", "-", value) or "status"


def get_or_create_author(db: Session, name: str) -> Author | None:
    name = (name or "").strip()
    if not name:
        return None
    author = db.scalar(select(Author).where(func.lower(Author.name) == name.lower()))
    if author is None:
        author = Author(name=name)
        db.add(author)
        db.flush()
    return author


def get_or_create_publisher(db: Session, name: str | None) -> Publisher | None:
    name = (name or "").strip()
    if not name:
        return None
    publisher = db.scalar(select(Publisher).where(func.lower(Publisher.name) == name.lower()))
    if publisher is None:
        publisher = Publisher(name=name)
        db.add(publisher)
        db.flush()
    return publisher


def _split_names(value) -> list[str]:
    if not value:
        return []
    if isinstance(value, str):
        return [part.strip() for part in value.split(",") if part.strip()]
    return [str(part).strip() for part in value if str(part).strip()]


def _to_int(value) -> int | None:
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _to_score(value) -> float | None:
    """Parse a 0.5–5.0 star score (blank/0 becomes None), snapped to half stars."""
    if value in (None, ""):
        return None
    try:
        score = float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None
    if score <= 0:
        return None
    score = round(score / SCORE_STEP) * SCORE_STEP
    return max(MIN_SCORE, min(MAX_SCORE, score))


_HEX_COLOUR = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")


def normalize_color(value: str | None, default: str = "#64748b") -> str:
    """Return a safe ``#rgb``/``#rrggbb`` colour for inline CSS.

    Status colours are written straight into a ``style`` attribute, so a value
    from an API client must never be able to smuggle arbitrary CSS in there.
    """
    candidate = (value or "").strip()
    if not candidate:
        return default
    return candidate if _HEX_COLOUR.match(candidate) else default


def _check_reference(db: Session, model, value, message: str) -> int | None:
    """Validate an optional foreign key coming from a form or API payload."""
    if value in (None, "", "none", "null"):
        return None
    try:
        identifier = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(message) from exc
    if db.get(model, identifier) is None:
        raise ValueError(message)
    return identifier



# --------------------------------------------------------------------------- #
# Books
# --------------------------------------------------------------------------- #
def apply_book_data(db: Session, book: Book, data: dict) -> Book:
    """Populate a book from a plain dict (form data or lookup result)."""
    if "isbn" in data:
        isbn = normalize_isbn(data.get("isbn") or "")
        book.isbn = isbn or None

    if "title" in data:
        book.title = (data.get("title") or "").strip() or "Untitled"

    for field in ("subtitle", "description", "language",
                  "cover_url", "notes", "source"):
        if field in data:
            value = data.get(field)
            setattr(book, field, value.strip() if isinstance(value, str) else value)

    # ``published_date`` is the one field the user edits. ``published_year`` is
    # a cached projection of it, kept only so sorting stays a simple indexed
    # column; it is always recomputed here.
    if "published_date" in data:
        value = data.get("published_date")
        book.published_date = value.strip() if isinstance(value, str) and value.strip() else None
    if "published_year" in data:
        year = _to_int(data.get("published_year"))
        if not book.published_date and year:
            # Year-only input (e.g. an online lookup) still fills the single
            # date field, so it shows up in the form and can be edited.
            book.published_date = str(year)
    if "published_date" in data or "published_year" in data:
        year = extract_year(book.published_date)
        if year is None and "published_year" in data:
            # The date has no parseable year (e.g. "MMV"); keep the supplied one.
            year = _to_int(data.get("published_year"))
        book.published_year = year
    if "page_count" in data:
        book.page_count = _to_int(data.get("page_count"))
    if "cover_type" in data:
        value = (data.get("cover_type") or "").strip()
        book.cover_type = value if value in COVER_TYPE_SLUGS else None
    if "read_status" in data:
        value = (data.get("read_status") or "").strip()
        book.read_status = value if value in READ_STATUS_SLUGS else None
    if "score" in data:
        book.score = _to_score(data.get("score"))
    if "saga" in data:
        book.saga = (data.get("saga") or "").strip() or None
    if "saga_number" in data:
        book.saga_number = _to_int(data.get("saga_number"))
    if "location_id" in data:
        book.location_id = _check_reference(
            db, Location, data.get("location_id"), _("That location is not valid.")
        )
    if "status_id" in data:
        book.status_id = _check_reference(
            db, Status, data.get("status_id"), _("That status is not valid.")
        )

    if "authors" in data:
        names = _split_names(data.get("authors"))
        book.authors = [a for a in (get_or_create_author(db, n) for n in names) if a]
    if "publisher" in data:
        publisher = get_or_create_publisher(db, data.get("publisher"))
        book.publisher = publisher

    # Relationship-only edits (the author list, the publisher) do not touch
    # a column on the book row, so SQLAlchemy's ``onupdate`` would miss them.
    # The merge resolves a book's whole author set by this timestamp, so it
    # has to move on every edit.
    book.updated_at = utc_now()
    return book


def create_book(db: Session, data: dict, *, commit: bool = True) -> Book:
    book = Book(title="Untitled")
    # Add to the session before wiring up relationships so the author/publisher
    # back-references are tracked correctly.
    db.add(book)
    if not data.get("status_id"):
        default = get_default_status(db)
        if default:
            data = {**data, "status_id": default.id}
    apply_book_data(db, book, data)
    if commit:
        db.commit()
        db.refresh(book)
    else:
        # The caller owns the transaction (used by the CSV importer, which must
        # commit the whole batch or none of it).
        db.flush()
    return book


def update_book(db: Session, book: Book, data: dict) -> Book:
    apply_book_data(db, book, data)
    db.commit()
    # Editing a book's authors/publisher can strand the previous ones.
    prune_orphans(db)
    db.refresh(book)
    return book


def get_book(db: Session, book_id: int) -> Book | None:
    return db.scalar(select(Book).where(Book.id == book_id).options(*BOOK_LOAD_OPTIONS))


def delete_book(db: Session, book: Book) -> None:
    tombstones.record(db, "books", book.sync_id)
    db.delete(book)
    # Flush so the book's author links are gone before we look for orphans.
    db.flush()
    prune_orphans(db)


def prune_orphans(db: Session) -> None:
    """Delete authors and publishers no longer linked to any book.

    They are created on the fly from book metadata, so once their last book is
    gone they are just clutter — left behind they inflate the dashboard counts
    and linger in the filter dropdowns.
    """
    for author in db.scalars(select(Author).where(~Author.books.any())).all():
        db.delete(author)
    for publisher in db.scalars(select(Publisher).where(~Publisher.books.any())).all():
        db.delete(publisher)
    db.commit()


def sync_published_years(db: Session) -> None:
    """Repair older rows so the cached year matches the single date field.

    Books entered before the date/year fields were unified may only have a
    year; fold it into ``published_date`` so the edit form shows one value, then
    recompute the cached ``published_year`` used by the catalog's Year sort.
    """
    for book in db.scalars(select(Book)).all():
        if not book.published_date and book.published_year:
            book.published_date = str(book.published_year)
        year = extract_year(book.published_date)
        if year is not None:
            book.published_year = year
    db.commit()


def find_by_isbn(db: Session, isbn: str) -> Book | None:
    isbn = normalize_isbn(isbn)
    if not isbn:
        return None
    return db.scalar(select(Book).where(Book.isbn == isbn).options(*BOOK_LOAD_OPTIONS))


def query_books(
    db: Session,
    *,
    search: str | None = None,
    status_id: int | None = None,
    location_id: int | None = None,
    author_id: int | None = None,
    publisher_id: int | None = None,
    loaned: str | None = None,  # "loaned" | "available" | None
    saga: str | None = None,
    read_status: str | None = None,
    sort: str = "recent",
    descending: bool | None = None,  # None keeps each sort's natural direction
) -> list[Book]:
    stmt = select(Book).options(*BOOK_LOAD_OPTIONS)

    if search:
        term = f"%{search.strip()}%"
        stmt = stmt.outerjoin(Book.authors).outerjoin(Book.publisher)
        stmt = stmt.where(
            or_(
                Book.title.ilike(term),
                Book.subtitle.ilike(term),
                Book.isbn.ilike(term),
                Author.name.ilike(term),
                Publisher.name.ilike(term),
            )
        ).distinct()

    if status_id:
        stmt = stmt.where(Book.status_id == status_id)
    if publisher_id:
        stmt = stmt.where(Book.publisher_id == publisher_id)
    if author_id:
        stmt = stmt.join(Book.authors).where(Author.id == author_id).distinct()
    if location_id:
        location = db.get(Location, location_id)
        if location:
            stmt = stmt.where(Book.location_id.in_(location.descendant_ids()))
    if saga:
        stmt = stmt.where(func.lower(Book.saga) == saga.strip().lower())
    if read_status:
        value = read_status.strip()
        if value in READ_STATUS_SLUGS:
            stmt = stmt.where(Book.read_status == value)

    if loaned == "loaned":
        stmt = stmt.join(Book.loans).where(Loan.returned_at.is_(None)).distinct()
    elif loaned == "available":
        stmt = stmt.where(~Book.loans.any(Loan.returned_at.is_(None)))

    if sort == "title":
        order = func.lower(Book.title)
        stmt = stmt.order_by(order.desc() if descending else order.asc())
    elif sort == "year":
        # Newest first by default; the caller may flip the direction.
        newest_first = True if descending is None else descending
        column = Book.published_year
        stmt = stmt.order_by(
            column.desc().nullslast() if newest_first else column.asc().nullslast()
        )
    elif sort == "author":
        # Author names live on the other side of a many-to-many join, so sort
        # the loaded rows in Python (cheap for a personal library).
        pass
    elif sort == "saga":
        # Group a saga's books together, in reading order, then by title.
        order = func.lower(Book.saga)
        stmt = stmt.order_by(
            (order.desc() if descending else order.asc()).nullslast(),
            Book.saga_number.asc(),
            func.lower(Book.title),
        )
    else:  # recent
        newest_first = True if descending is None else descending
        stmt = stmt.order_by(
            Book.created_at.desc() if newest_first else Book.created_at.asc(),
            Book.id.desc() if newest_first else Book.id.asc(),
        )

    books = list(db.scalars(stmt).unique().all())
    if sort == "author":
        def by_author(book: Book) -> tuple[str, str]:
            names = [author.name.casefold() for author in book.authors if author.name]
            return (min(names) if names else "", (book.title or "").casefold())

        books.sort(key=by_author, reverse=bool(descending))
    return books


# --------------------------------------------------------------------------- #
# Loans
# --------------------------------------------------------------------------- #
def lend_book(
    db: Session,
    book: Book,
    *,
    borrower_name: str,
    borrower_contact: str | None = None,
    lent_at: date | None = None,
    due_at: date | None = None,
    notes: str | None = None,
    mark_status: bool = True,
) -> Loan:
    borrower_name = (borrower_name or "").strip()
    if not borrower_name:
        raise ValueError(_("A borrower name is required."))
    # A book can only be in one place at a time. Without this check a double
    # click (or two clients) creates two active loans and returning closes only
    # the one the UI happened to see.
    active = db.scalar(
        select(Loan).where(Loan.book_id == book.id, Loan.returned_at.is_(None))
    )
    if active is not None:
        raise ValueError(_("This book is already lent out."))
    loan = Loan(
        book_id=book.id,
        borrower_name=borrower_name,
        borrower_contact=(borrower_contact or "").strip() or None,
        lent_at=lent_at or date.today(),
        due_at=due_at,
        notes=(notes or "").strip() or None,
    )
    db.add(loan)
    if mark_status:
        lent_status = get_status_by_slug(db, "lent")
        if lent_status:
            book.status_id = lent_status.id
    db.commit()
    db.refresh(loan)
    return loan


def return_loan(
    db: Session,
    book: Book,
    *,
    returned_at: date | None = None,
    restore_status: bool = True,
) -> bool:
    """Mark every active loan for ``book`` returned.

    Returns ``False`` when the book was not actually lent out — in that case the
    status is deliberately left alone (returning a book that never left the
    shelf must not silently flip it to "available").
    """
    active = [loan for loan in book.loans if loan.returned_at is None]
    if not active:
        return False
    when = returned_at or date.today()
    for loan in active:
        loan.returned_at = when
    if restore_status:
        available = get_status_by_slug(db, "available")
        if available:
            book.status_id = available.id
    db.commit()
    return True


# --------------------------------------------------------------------------- #
# Statuses
# --------------------------------------------------------------------------- #
def get_default_status(db: Session) -> Status | None:
    return (
        db.scalar(select(Status).where(Status.is_default.is_(True)))
        or get_status_by_slug(db, "available")
        or db.scalar(select(Status).order_by(Status.sort_order))
    )


def get_status_by_slug(db: Session, slug: str) -> Status | None:
    return db.scalar(select(Status).where(Status.slug == slug))


def create_status(db: Session, *, name: str, color: str, icon=None, description=None,
                  slug=None, sort_order=None) -> Status:
    name = (name or "").strip()
    if not name:
        raise ValueError(_("A status name is required."))
    if _status_name_exists(db, name):
        raise ValueError(_("A status named “%s” already exists.") % name)
    if sort_order is None:
        sort_order = (db.scalar(select(func.max(Status.sort_order))) or 0) + 10
    status = Status(
        name=name,
        slug=_unique_status_slug(db, slug or slugify(name)),
        color=normalize_color(color),
        icon=icon or None,
        description=(description or "").strip() or None,
        sort_order=sort_order,
    )
    db.add(status)
    db.commit()
    db.refresh(status)
    return status


def _status_name_exists(db: Session, name: str, exclude_id: int | None = None) -> bool:
    stmt = select(Status).where(func.lower(Status.name) == name.lower())
    if exclude_id is not None:
        stmt = stmt.where(Status.id != exclude_id)
    return db.scalar(stmt) is not None


def _unique_status_slug(db: Session, base: str, exclude_id: int | None = None) -> str:
    """Return ``base``, or ``base-2``/``base-3``… if that slug is taken."""
    base = base or "status"
    candidate, counter = base, 1
    while True:
        stmt = select(Status).where(Status.slug == candidate)
        if exclude_id is not None:
            stmt = stmt.where(Status.id != exclude_id)
        if db.scalar(stmt) is None:
            return candidate
        counter += 1
        candidate = f"{base}-{counter}"


def delete_status(db: Session, status: Status) -> None:
    if status.is_system:
        raise ValueError(_("System statuses cannot be deleted."))
    fallback = get_status_by_slug(db, "available")
    fallback_id = fallback.id if fallback else None
    tombstones.record(db, "statuses", status.sync_id)
    # Bulk statements on purpose: deleting a Status through the ORM also
    # nullifies every row in its loaded ``books`` collection, which would undo
    # the repoint. A plain UPDATE also bumps each book's ``updated_at``, so the
    # new status travels to the other devices on the next sync.
    db.execute(
        update(Book).where(Book.status_id == status.id).values(status_id=fallback_id)
    )
    db.execute(delete(Status).where(Status.id == status.id))
    db.commit()
    db.expunge(status)


def update_status(db: Session, status: Status, *, name=None, color=None, icon=None,
                  description=None) -> Status:
    if name is not None and name.strip():
        new_name = name.strip()
        if new_name.lower() != status.name.lower() and _status_name_exists(
            db, new_name, exclude_id=status.id
        ):
            raise ValueError(_("A status named “%s” already exists.") % new_name)
        status.name = new_name
        if not status.is_system:
            status.slug = _unique_status_slug(db, slugify(status.name), exclude_id=status.id)
    if color is not None and color.strip():
        status.color = normalize_color(color, default=status.color)
    if icon is not None:
        status.icon = icon.strip() or None
    if description is not None:
        status.description = description.strip() or None
    db.commit()
    db.refresh(status)
    return status


# --------------------------------------------------------------------------- #
# Locations
# --------------------------------------------------------------------------- #
def flatten_locations(db: Session) -> list[tuple[Location, int]]:
    """Return ``[(location, depth), ...]`` in tree order for indented selects."""
    roots = list(
        db.scalars(select(Location).where(Location.parent_id.is_(None)).order_by(Location.name))
    )
    flat: list[tuple[Location, int]] = []

    def walk(node: Location, depth: int) -> None:
        flat.append((node, depth))
        for child in sorted(node.children, key=lambda c: c.name.lower()):
            walk(child, depth + 1)

    for root in roots:
        walk(root, 0)
    return flat


def create_location(db: Session, *, name: str, parent_id=None, kind=None, description=None) -> Location:
    location = Location(
        name=name.strip(),
        parent_id=_check_reference(
            db, Location, parent_id, _("The parent location is not valid.")
        ),
        kind=(kind or "").strip() or None,
        description=(description or "").strip() or None,
    )
    db.add(location)
    db.commit()
    db.refresh(location)
    return location


def delete_location(db: Session, location: Location) -> None:
    # The cascade takes the children with it, so remember each of them.
    subtree = location.descendant_ids()
    sync_ids = db.scalars(
        select(Location.sync_id).where(
            Location.id.in_(subtree), Location.sync_id.is_not(None)
        )
    ).all()
    tombstones.record_many(db, "locations", sync_ids)
    db.delete(location)
    db.commit()


def update_location(db: Session, location: Location, *, name=None, parent_id=..., kind=None,
                    description=None) -> Location:
    if name is not None:
        location.name = name.strip() or location.name
    if parent_id is not ...:
        new_parent = _check_reference(
            db, Location, parent_id, _("The parent location is not valid.")
        )
        # Never allow a location to become its own ancestor.
        if new_parent is not None and new_parent in location.descendant_ids():
            raise ValueError(_("A location cannot be moved inside itself."))
        location.parent_id = new_parent
    if kind is not None:
        location.kind = kind.strip() or None
    if description is not None:
        location.description = description.strip() or None
    db.commit()
    db.refresh(location)
    return location


def list_statuses(db: Session) -> list[Status]:
    return list(db.scalars(select(Status).order_by(Status.sort_order, Status.name)))


def list_authors(db: Session) -> list[Author]:
    return list(db.scalars(select(Author).order_by(func.lower(Author.name))))


def list_publishers(db: Session) -> list[Publisher]:
    return list(db.scalars(select(Publisher).order_by(func.lower(Publisher.name))))


def list_sagas(db: Session) -> list[str]:
    """Distinct saga names, alphabetically (for the catalog's saga filter)."""
    # Sort in Python: ``SELECT DISTINCT`` with an expression in ORDER BY is not
    # portable (PostgreSQL requires ordered expressions in the select list).
    names = db.scalars(
        select(Book.saga).where(Book.saga.is_not(None), Book.saga != "").distinct()
    )
    return sorted({name for name in names if name}, key=str.casefold)


# --------------------------------------------------------------------------- #
# Aggregates
# --------------------------------------------------------------------------- #
def get_stats(db: Session) -> dict:
    total = db.scalar(select(func.count(Book.id))) or 0
    authors = db.scalar(select(func.count(Author.id))) or 0
    publishers = db.scalar(select(func.count(Publisher.id))) or 0
    loans = db.scalar(select(func.count(Loan.id)).where(Loan.returned_at.is_(None))) or 0
    wishlist = get_status_by_slug(db, "wishlist")
    wishlist_count = 0
    if wishlist:
        wishlist_count = (
            db.scalar(select(func.count(Book.id)).where(Book.status_id == wishlist.id)) or 0
        )
    return {
        "total": total,
        "authors": authors,
        "publishers": publishers,
        "loans": loans,
        "wishlist": wishlist_count,
    }


def status_counts(db: Session) -> list[tuple[Status, int]]:
    rows = db.execute(
        select(Status, func.count(Book.id))
        .outerjoin(Book, Book.status_id == Status.id)
        .group_by(Status.id)
        .order_by(Status.sort_order, Status.name)
    ).all()
    return [(status, count) for status, count in rows]
