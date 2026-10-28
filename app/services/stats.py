"""Personal reading stats and objectives.

These are *local-only*: they are never included in the cross-device sync
snapshot (``bibliojules-library.sqlite`` contains no accounts and no personal
metadata).  Each device keeps its own stats and objectives; they simply don't
travel when the library is merged from another machine.

Stats are computed from the shared library on each read.  Objectives now live in
the ``reading_goals`` table rather than a side JSON file, so the single-file
``.sqlite`` export carries them and a reinstalled app gets them back.

The web dashboard reaches them via the JSON API (``/api/personal-stats`` etc.);
the desktop app talks to the same endpoints (remote mode) or reads the files
directly (local mode, through this module).
"""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any

from sqlalchemy import func, select

from ..config import DATA_DIR
from ..models import Book, ReadingGoal, Status
from .jsonstore import file_lock, load_json, save_json

GOALS_FILE = DATA_DIR / "goals.json"
WANT_LIST_FILE = DATA_DIR / "want_list.json"


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return default


def _scoped_path(path: Path, user_id: int | None) -> Path:
    """Goals/wantlist are per account on a shared server, per device offline."""
    if user_id is None:
        return path
    return path.with_name(f"{path.stem}.u{_as_int(user_id)}{path.suffix}")


def _read_scoped(
    path: Path, default: Any, user_id: int | None, *, locked: bool = False
) -> Any:
    target = _scoped_path(path, user_id)
    # Lock the file this caller actually reads: the legacy migration and a
    # concurrent save must not race and copy the old shared file over the
    # account's newer data. Callers that already hold this file's lock pass
    # ``locked=True`` — flock is not re-entrant across two open handles.
    if locked:
        return _read_scoped_unlocked(path, target, default, user_id)
    with file_lock(target):
        return _read_scoped_unlocked(path, target, default, user_id)


def _read_scoped_unlocked(
    path: Path, target: Path, default: Any, user_id: int | None
) -> Any:
    if user_id is not None and not target.exists() and path.exists():
        # One-time migration: the old shared file becomes this account's file.
        # Re-checked under the lock, so only the first reader copies.
        data = load_json(path, default)
        save_json(target, data)
        return data
    return load_json(target, default)


def _write_scoped(path: Path, data: Any, user_id: int | None) -> None:
    save_json(_scoped_path(path, user_id), data)


# --------------------------------------------------------------------------- #
# Stats – computed from the shared library DB on each read
# --------------------------------------------------------------------------- #


def compute_stats(db) -> dict:
    """Return stats derived from the shared library database.

    These numbers are read-only aggregations computed on every call, so they
    always reflect the current library state.  They are *not* persisted here —
    only goals and the want-to-read list are saved to disk.
    """
    from .library import get_stats

    shared = get_stats(db)

    # Read status and shelf status are different axes: "lost"/"donated" are
    # shelves, not read-status slugs, so they must be counted from status_id.
    by_status = {
        (slug or "unread"): count
        for slug, count in db.execute(
            select(Book.read_status, func.count(Book.id)).group_by(Book.read_status)
        ).all()
    }
    by_shelf = {
        slug: count
        for slug, count in db.execute(
            select(Status.slug, func.count(Book.id))
            .join(Book, Book.status_id == Status.id)
            .where(Status.slug.in_(("lost", "donated")))
            .group_by(Status.slug)
        ).all()
    }

    books_read = by_status.get("read", 0)
    pages_read = (
        db.scalar(
            select(func.coalesce(func.sum(Book.page_count), 0)).where(
                Book.read_status == "read"
            )
        )
        or 0
    )
    average = db.scalar(
        select(func.avg(Book.score)).where(
            Book.read_status == "read", Book.score.is_not(None)
        )
    )
    avg_rating = round(float(average), 1) if average is not None else None

    return {
        "total_books": shared["total"],
        "in_library": (shared["total"] - shared["wishlist"]) if shared["total"] >= shared["wishlist"] else shared["total"],
        "books_read": books_read,
        "pages_read": pages_read,
        "avg_rating": avg_rating,
        "currently_reading": by_status.get("currently_reading", 0),
        "loans": shared["loans"],
        "wishlist": shared["wishlist"],
        "authors": shared["authors"],
        "status_breakdown": {
            "read": books_read,
            "currently_reading": by_status.get("currently_reading", 0),
            "dnf": by_status.get("dnf", 0),
            "lost": by_shelf.get("lost", 0),
            "donated": by_shelf.get("donated", 0),
            "unread": by_status.get("unread", 0),
            "to_read": by_status.get("to_read", 0),
        },
    }


# --------------------------------------------------------------------------- #
# Goals — stored in the ``reading_goals`` table, scoped by account
# --------------------------------------------------------------------------- #
#
# Objectives live in the database (not a side JSON file) so the single-file
# ``.sqlite`` export carries them and a reinstalled app gets them back. They are
# still kept out of the cross-device sync merge (see ``app/services/sync.py``).
# Progress is tracked per objective (``books_done`` / ``pages_done``), bumped
# whenever a book is marked read in that objective's year — never the all-time
# count of read books, which stays on the dashboard.


def _scope(user_id: int | None):
    """Rows belonging to ``user_id`` (or the offline device when ``None``)."""
    if user_id is None:
        return ReadingGoal.user_id.is_(None)
    return ReadingGoal.user_id == user_id


def _year_clause(year: int | None):
    """Match an objective's year, where ``None`` means "any year"."""
    if year is None:
        return ReadingGoal.year.is_(None)
    return ReadingGoal.year == year


def _goal_dict(goal: ReadingGoal) -> dict:
    """Serialize one objective row to its API shape."""
    return {
        "year": goal.year,
        "target_books": goal.target_books or 0,
        "target_pages": goal.target_pages or 0,
        "books_done": goal.books_done or 0,
        "pages_done": goal.pages_done or 0,
    }


def _has_target(goal: ReadingGoal) -> bool:
    """An objective counts as set only when it has a target to aim at."""
    return bool((goal.target_books or 0) or (goal.target_pages or 0))


def load_goals(db, user_id: int | None = None) -> list[dict]:
    """Return the reading objectives for ``user_id`` (or the offline device).

    Each objective is a ``{year, target_books, target_pages, books_done,
    pages_done}`` dict. A legacy ``goals.json`` file is migrated into the table
    once, on the first read for a scope that has no rows yet.
    """
    _migrate_legacy_goals(db, user_id)
    rows = db.scalars(select(ReadingGoal).where(_scope(user_id))).all()
    return [_goal_dict(g) for g in rows if _has_target(g)]


def save_goals(db, goal: dict, user_id: int | None = None) -> None:
    """Add or replace one reading objective, keyed by its year.

    Saving an objective for a year replaces any existing objective for that
    same year, so a year never shows up twice. An objective with no target is
    dropped, which lets callers clear a year by saving an empty one. A brand-new
    objective starts at zero progress; the per-goal counter only moves when a
    book is actually marked read.
    """
    year = _as_int(goal.get("year"), 0) or None
    target_books = _as_int(goal.get("target_books"))
    target_pages = _as_int(goal.get("target_pages"))
    # A re-save keeps any progress the existing row for this year already had.
    existing = db.scalars(
        select(ReadingGoal).where(_scope(user_id) & _year_clause(year))
    ).first()
    books_done = existing.books_done if existing else 0
    pages_done = existing.pages_done if existing else 0
    if existing is not None:
        db.delete(existing)
        db.flush()
    if target_books or target_pages:
        db.add(
            ReadingGoal(
                user_id=user_id,
                year=year,
                target_books=target_books,
                target_pages=target_pages,
                books_done=books_done,
                pages_done=pages_done,
            )
        )
    db.commit()


def remove_goals(db, year: int | None, user_id: int | None = None) -> None:
    """Delete the objective for ``year`` (``None`` = the "any year" objective)."""
    for goal in db.scalars(
        select(ReadingGoal).where(_scope(user_id) & _year_clause(year))
    ).all():
        db.delete(goal)
    db.commit()


def record_read(db, user_id: int | None = None, pages: int = 0) -> None:
    """Count a book marked read, toward the objective for the current year.

    A mark-read bumps the objective whose year is the current calendar year,
    and also any "any year" objective (``year IS NULL``). Progress is per
    objective, so this never touches the all-time dashboard count.
    """
    year = date.today().year
    rows = db.scalars(
        select(ReadingGoal).where(
            _scope(user_id) & ((ReadingGoal.year == year) | ReadingGoal.year.is_(None))
        )
    ).all()
    for goal in rows:
        goal.books_done = (goal.books_done or 0) + 1
        goal.pages_done = (goal.pages_done or 0) + max(0, pages)
    db.commit()


def _migrate_legacy_goals(db, user_id: int | None) -> None:
    """Move a device's old ``goals.json`` into the table, once."""
    path = _scoped_path(GOALS_FILE, user_id)
    if not path.exists():
        return
    if db.scalars(select(ReadingGoal).where(_scope(user_id))).first() is not None:
        # Already migrated (or the user set goals directly): leave the file alone.
        return
    data = load_json(path, [])
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        data = []
    for item in data:
        if not isinstance(item, dict):
            continue
        year = _as_int(item.get("year"), 0) or None
        target_books = _as_int(item.get("target_books"))
        target_pages = _as_int(item.get("target_pages"))
        if not (target_books or target_pages):
            continue
        progress = item.get("progress")
        progress = progress if isinstance(progress, dict) else {}
        db.add(
            ReadingGoal(
                user_id=user_id,
                year=year,
                target_books=target_books,
                target_pages=target_pages,
                books_done=_as_int(progress.get("books_read")),
                pages_done=_as_int(progress.get("pages_read")),
            )
        )
    db.commit()
    try:
        path.unlink()
    except OSError:  # pragma: no cover
        pass


# --------------------------------------------------------------------------- #
# Want-to-read list
# --------------------------------------------------------------------------- #


def load_want_list(user_id: int | None = None) -> list[dict]:
    """Return the want-to-read list for ``user_id`` (or the offline device)."""
    data = _read_scoped(WANT_LIST_FILE, [], user_id)
    return [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []


def add_want_entry(entry: dict, user_id: int | None = None) -> None:
    """Append an entry, deduplicating by ISBN (or title) when present."""
    if not isinstance(entry, dict):
        return
    with file_lock(_scoped_path(WANT_LIST_FILE, user_id)):
        data = _read_scoped(WANT_LIST_FILE, [], user_id, locked=True)
        items = [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []
        isbn = (entry.get("isbn") or "").strip()
        title = (entry.get("title") or "").strip().casefold()
        if isbn:
            items = [i for i in items if (i.get("isbn") or "").strip() != isbn]
        elif title:
            items = [
                i for i in items if (i.get("title") or "").strip().casefold() != title
            ]
        items.append(entry)
        _write_scoped(WANT_LIST_FILE, items, user_id)


def remove_want_entry(
    isbn: str | None = None,
    entry_id: str | None = None,
    user_id: int | None = None,
) -> None:
    """Remove an entry by its id (or by ISBN as a fallback)."""
    with file_lock(_scoped_path(WANT_LIST_FILE, user_id)):
        data = _read_scoped(WANT_LIST_FILE, [], user_id, locked=True)
        items = [item for item in data if isinstance(item, dict)] if isinstance(data, list) else []
        if entry_id:
            items = [i for i in items if i.get("id") != entry_id]
        elif isbn:
            items = [i for i in items if i.get("isbn") != isbn]
        _write_scoped(WANT_LIST_FILE, items, user_id)
