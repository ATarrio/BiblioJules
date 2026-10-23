"""Data access for the desktop app: one interface, two back-ends.

The desktop app can run in either of two modes:

* **local** (the default) — it opens the SQLite file directly through the same
  service layer as the web app, exactly as it always has; or
* **remote** — it talks to a hosted BiblioJules server over its JSON API, so a
  laptop away from home can read and edit the same shared catalogue.

Both back-ends implement :class:`Repo` and return plain dictionaries in the
shape produced by :mod:`app.services.serializers`, so the views and dialogs
have a single code path and never hold an ORM object.

The active repo is a module-level singleton, chosen at start-up by
:func:`app.desktop.app.run` and read everywhere else through :func:`get_repo`.
"""

from __future__ import annotations

import socket
from abc import ABC, abstractmethod
from datetime import date, datetime
from typing import Any
from urllib.parse import quote

import httpx

from .. import preferences
from ..i18n import _
from ..models import Location, Status
from ..services import library
from ..services.serializers import (
    book_to_dict,
    loan_to_dict,
    location_to_dict,
    status_to_dict,
)
from .db import session_scope

#: Seconds before a slow server is declared unreachable.
DEFAULT_TIMEOUT = 15.0


# --------------------------------------------------------------------------- #
# Errors
# --------------------------------------------------------------------------- #
class RepoError(RuntimeError):
    """Any data-access failure worth showing the user as a message."""


class AuthError(RepoError):
    """The server rejected our token (missing, expired or revoked)."""


class ConnectionFailure(RepoError):
    """The server could not be reached at all."""


class NotFound(RepoError):
    """The requested record does not exist (HTTP 404)."""


# --------------------------------------------------------------------------- #
# The interface
# --------------------------------------------------------------------------- #
class Repo(ABC):
    """Everything the UI is allowed to do with the catalogue.

    Every method returns plain dictionaries (or lists of them) matching
    ``app.services.serializers``. Raise :class:`RepoError` (or a subclass) for
    anything the user should see as a message.
    """

    @property
    @abstractmethod
    def description(self) -> str:
        """A short human label for where the data lives (shown in the UI)."""

    # -- books ------------------------------------------------------------- #
    @abstractmethod
    def list_books(
        self,
        *,
        search: str | None = None,
        status_id: int | None = None,
        location_id: int | None = None,
        saga: str | None = None,
        read_status: str | None = None,
        loaned: str | None = None,
        sort: str = "recent",
    ) -> list[dict]: ...

    @abstractmethod
    def get_book(self, book_id: int) -> dict | None: ...

    @abstractmethod
    def book_loans(self, book_id: int) -> list[dict]:
        """Every loan a book has had, newest first."""

    @abstractmethod
    def create_book(self, data: dict) -> dict: ...

    @abstractmethod
    def update_book(self, book_id: int, data: dict) -> dict: ...

    @abstractmethod
    def delete_book(self, book_id: int) -> None: ...

    @abstractmethod
    def find_by_isbn(self, isbn: str) -> dict | None: ...

    @abstractmethod
    def lend_book(self, book_id: int, payload: dict) -> dict: ...

    @abstractmethod
    def return_book(self, book_id: int) -> None: ...

    # -- statuses ---------------------------------------------------------- #
    @abstractmethod
    def list_statuses(self) -> list[dict]: ...

    @abstractmethod
    def get_status(self, status_id: int) -> dict | None: ...

    @abstractmethod
    def status_by_slug(self, slug: str) -> dict | None: ...

    @abstractmethod
    def create_status(self, data: dict) -> dict: ...

    @abstractmethod
    def update_status(self, status_id: int, data: dict) -> dict: ...

    @abstractmethod
    def delete_status(self, status_id: int) -> None: ...

    # -- locations --------------------------------------------------------- #
    @abstractmethod
    def list_locations(self) -> list[dict]:
        """Flat list, already in tree order (parents before their children)."""

    @abstractmethod
    def get_location(self, location_id: int) -> dict | None: ...

    @abstractmethod
    def create_location(self, data: dict) -> dict: ...

    @abstractmethod
    def update_location(self, location_id: int, data: dict) -> dict: ...

    @abstractmethod
    def delete_location(self, location_id: int) -> None: ...

    # -- dashboard --------------------------------------------------------- #
    @abstractmethod
    def stats(self) -> dict: ...

    @abstractmethod
    def status_counts(self) -> list[dict]:
        """``[{"status": {...}, "count": n}, ...]`` for every status."""

    @abstractmethod
    def personal_stats(self) -> dict:
        """Reading stats derived from the library (shared data, local view)."""

    @abstractmethod
    def goals(self) -> dict:
        """Per-device reading goals (local-only)."""

    @abstractmethod
    def save_goals(self, goals: dict) -> None: ...

    @abstractmethod
    def want_list(self) -> list[dict]: ...

    @abstractmethod
    def add_want(self, entry: dict) -> None: ...

    @abstractmethod
    def remove_want(self, entry_id: str) -> None: ...

    @abstractmethod
    def sagas(self) -> list[str]: ...


# --------------------------------------------------------------------------- #
# Local back-end
# --------------------------------------------------------------------------- #
class LocalRepo(Repo):
    """Opens the SQLite file directly through ``app.services.library``."""

    def __init__(self, description: str | None = None) -> None:
        self._description = description

    @property
    def description(self) -> str:
        return self._description or _("This computer")

    # -- books ------------------------------------------------------------- #
    def list_books(
        self,
        *,
        search: str | None = None,
        status_id: int | None = None,
        location_id: int | None = None,
        saga: str | None = None,
        read_status: str | None = None,
        loaned: str | None = None,
        sort: str = "recent",
    ) -> list[dict]:
        with session_scope() as db:
            books = library.query_books(
                db,
                search=search,
                status_id=status_id,
                location_id=location_id,
                saga=saga,
                read_status=read_status,
                loaned=loaned,
                sort=sort,
            )
            return [book_to_dict(book) for book in books]

    def get_book(self, book_id: int) -> dict | None:
        with session_scope() as db:
            book = library.get_book(db, book_id)
            return book_to_dict(book) if book is not None else None

    def book_loans(self, book_id: int) -> list[dict]:
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is None:
                return []
            return [loan_to_dict(loan) for loan in book.loans]

    def create_book(self, data: dict) -> dict:
        with session_scope() as db:
            book = library.create_book(db, data)
            fresh = library.get_book(db, book.id)
            return book_to_dict(fresh)

    def update_book(self, book_id: int, data: dict) -> dict:
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is None:
                raise NotFound(_("This book no longer exists."))
            library.update_book(db, book, data)
            fresh = library.get_book(db, book_id)
            return book_to_dict(fresh)

    def delete_book(self, book_id: int) -> None:
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is not None:
                library.delete_book(db, book)

    def find_by_isbn(self, isbn: str) -> dict | None:
        if not isbn:
            return None
        with session_scope() as db:
            book = library.find_by_isbn(db, isbn)
            return book_to_dict(book) if book is not None else None

    def lend_book(self, book_id: int, payload: dict) -> dict:
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is None:
                raise NotFound(_("This book no longer exists."))
            return loan_to_dict(library.lend_book(db, book, **payload))

    def return_book(self, book_id: int) -> None:
        with session_scope() as db:
            book = library.get_book(db, book_id)
            if book is None:
                raise NotFound(_("This book no longer exists."))
            library.return_loan(db, book)

    # -- statuses ---------------------------------------------------------- #
    def list_statuses(self) -> list[dict]:
        with session_scope() as db:
            return [status_to_dict(status) for status in library.list_statuses(db)]

    def get_status(self, status_id: int) -> dict | None:
        with session_scope() as db:
            status = db.get(Status, status_id)
            return status_to_dict(status) if status is not None else None

    def status_by_slug(self, slug: str) -> dict | None:
        with session_scope() as db:
            status = library.get_status_by_slug(db, slug)
            return status_to_dict(status) if status is not None else None

    def create_status(self, data: dict) -> dict:
        with session_scope() as db:
            return status_to_dict(library.create_status(db, **data))

    def update_status(self, status_id: int, data: dict) -> dict:
        with session_scope() as db:
            status = db.get(Status, status_id)
            if status is None:
                raise NotFound(_("This status no longer exists."))
            library.update_status(db, status, **data)
            return status_to_dict(status)

    def delete_status(self, status_id: int) -> None:
        with session_scope() as db:
            status = db.get(Status, status_id)
            if status is not None:
                library.delete_status(db, status)

    # -- locations --------------------------------------------------------- #
    def list_locations(self) -> list[dict]:
        with session_scope() as db:
            return [location_to_dict(loc) for loc, _depth in library.flatten_locations(db)]

    def get_location(self, location_id: int) -> dict | None:
        with session_scope() as db:
            location = db.get(Location, location_id)
            return location_to_dict(location) if location is not None else None

    def create_location(self, data: dict) -> dict:
        with session_scope() as db:
            return location_to_dict(library.create_location(db, **data))

    def update_location(self, location_id: int, data: dict) -> dict:
        with session_scope() as db:
            location = db.get(Location, location_id)
            if location is None:
                raise NotFound(_("This location no longer exists."))
            library.update_location(db, location, **data)
            return location_to_dict(location)

    def delete_location(self, location_id: int) -> None:
        with session_scope() as db:
            location = db.get(Location, location_id)
            if location is not None:
                library.delete_location(db, location)

    # -- dashboard --------------------------------------------------------- #
    def stats(self) -> dict:
        with session_scope() as db:
            return library.get_stats(db)

    def status_counts(self) -> list[dict]:
        with session_scope() as db:
            return [
                {"status": status_to_dict(status), "count": count}
                for status, count in library.status_counts(db)
            ]

    def personal_stats(self) -> dict:
        from ..services.stats import compute_stats

        with session_scope() as db:
            return compute_stats(db)

    def goals(self) -> dict:
        from ..services.stats import load_goals

        return load_goals()

    def save_goals(self, goals: dict) -> None:
        from ..services.stats import save_goals

        save_goals(goals)

    def want_list(self) -> list[dict]:
        from ..services.stats import load_want_list

        return load_want_list()

    def add_want(self, entry: dict) -> None:
        from ..services.stats import add_want_entry

        add_want_entry(entry)

    def remove_want(self, entry_id: str) -> None:
        from ..services.stats import remove_want_entry

        remove_want_entry(entry_id=entry_id)

    def sagas(self) -> list[str]:
        with session_scope() as db:
            return library.list_sagas(db)


# --------------------------------------------------------------------------- #
# Remote back-end
# --------------------------------------------------------------------------- #
class RemoteRepo(Repo):
    """Talks to a hosted BiblioJules server over its JSON API."""

    def __init__(self, base_url: str, token: str | None = None) -> None:
        self.base_url = (base_url or "").strip().rstrip("/")
        self.token = (token or "").strip()
        #: Set when the server has rejected our token, so the UI can say so.
        self.token_rejected = False
        self._client = httpx.Client(timeout=DEFAULT_TIMEOUT, follow_redirects=True)

    @property
    def description(self) -> str:
        return self.base_url or _("Remote server")

    def close(self) -> None:
        self._client.close()

    # -- transport --------------------------------------------------------- #
    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict | None = None,
        json: Any = None,
    ) -> Any:
        if not self.base_url:
            raise RepoError(_("No backend URL is configured yet."))
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            response = self._client.request(
                method, self.base_url + path, params=params, json=json, headers=headers
            )
        except httpx.HTTPError as exc:
            raise ConnectionFailure(
                _("Could not reach %(url)s. Check the backend URL and your connection.")
                % {"url": self.base_url}
            ) from exc

        if response.status_code == 401:
            self.token_rejected = True
            # The server no longer accepts this token. Forget it so the next
            # launch does not present it as a valid session.
            self.token = ""
            try:
                preferences.set_remote_session(token="", account="")
            except OSError:
                pass
            raise AuthError(
                _("Your session has expired. Please sign in again from File → Settings.")
            )
        if response.status_code == 404:
            raise NotFound(_error_detail(response))
        if response.status_code >= 400:
            raise RepoError(_error_detail(response))
        self.token_rejected = False
        if response.status_code == 204 or not response.content:
            return None
        try:
            return response.json()
        except ValueError as exc:
            raise RepoError(
                _("Unexpected response from %s.") % self.base_url
            ) from exc

    def _optional(self, method: str, path: str, **kwargs) -> Any:
        """Like :meth:`_request`, but a missing record becomes ``None``."""
        try:
            return self._request(method, path, **kwargs)
        except NotFound:
            return None

    def verify(self) -> dict:
        """Return the signed-in account, or raise :class:`AuthError`."""
        return self._request("GET", "/api/auth/me") or {}

    def logout(self) -> None:
        """Best-effort revocation of the current token server-side."""
        if not self.token:
            return
        try:
            self._request("POST", "/api/auth/logout")
        except RepoError:
            pass

    # -- books ------------------------------------------------------------- #
    def list_books(
        self,
        *,
        search: str | None = None,
        status_id: int | None = None,
        location_id: int | None = None,
        saga: str | None = None,
        read_status: str | None = None,
        loaned: str | None = None,
        sort: str = "recent",
    ) -> list[dict]:
        params: dict[str, Any] = {"sort": sort}
        if search:
            params["search"] = search
        if status_id:
            params["status"] = status_id
        if location_id:
            params["location"] = location_id
        if saga:
            params["saga"] = saga
        if read_status:
            params["read_status"] = read_status
        if loaned:
            params["loaned"] = loaned
        # The API pages at 500 rows; loop so a large catalogue is complete.
        books: list[dict] = []
        offset = 0
        while True:
            params["limit"] = 500
            params["offset"] = offset
            data = self._request("GET", "/api/books", params=params) or {}
            page = data.get("items") or []
            books.extend(page)
            total = data.get("count")
            # No count means an older server returned its whole catalogue in
            # one page; asking again would loop forever.
            if not page or not isinstance(total, int) or len(books) >= total:
                break
            offset += len(page)
        return books

    def get_book(self, book_id: int) -> dict | None:
        return self._optional("GET", f"/api/books/{book_id}")

    def book_loans(self, book_id: int) -> list[dict]:
        return self._optional("GET", f"/api/books/{book_id}/loans") or []

    def create_book(self, data: dict) -> dict:
        return self._request("POST", "/api/books", json=_jsonable(data))

    def update_book(self, book_id: int, data: dict) -> dict:
        return self._request("PUT", f"/api/books/{book_id}", json=_jsonable(data))

    def delete_book(self, book_id: int) -> None:
        # Already gone is not an error (mirrors LocalRepo).
        self._optional("DELETE", f"/api/books/{book_id}")

    def find_by_isbn(self, isbn: str) -> dict | None:
        if not isbn:
            return None
        return self._optional("GET", f"/api/books/by-isbn/{quote(isbn, safe='')}")

    def lend_book(self, book_id: int, payload: dict) -> dict:
        return self._request("POST", f"/api/books/{book_id}/lend", json=_jsonable(payload))

    def return_book(self, book_id: int) -> None:
        self._request("POST", f"/api/books/{book_id}/return", json={})

    # -- statuses ---------------------------------------------------------- #
    def list_statuses(self) -> list[dict]:
        return self._request("GET", "/api/statuses") or []

    def get_status(self, status_id: int) -> dict | None:
        return self._optional("GET", f"/api/statuses/{status_id}")

    def status_by_slug(self, slug: str) -> dict | None:
        for status in self.list_statuses():
            if status.get("slug") == slug:
                return status
        return None

    def create_status(self, data: dict) -> dict:
        return self._request("POST", "/api/statuses", json=data)

    def update_status(self, status_id: int, data: dict) -> dict:
        return self._request("PUT", f"/api/statuses/{status_id}", json=data)

    def delete_status(self, status_id: int) -> None:
        # Already gone is not an error (mirrors LocalRepo).
        self._optional("POST", f"/api/statuses/{status_id}/delete")

    # -- locations --------------------------------------------------------- #
    def list_locations(self) -> list[dict]:
        return self._request("GET", "/api/locations") or []

    def get_location(self, location_id: int) -> dict | None:
        return self._optional("GET", f"/api/locations/{location_id}")

    def create_location(self, data: dict) -> dict:
        return self._request("POST", "/api/locations", json=data)

    def update_location(self, location_id: int, data: dict) -> dict:
        return self._request("PUT", f"/api/locations/{location_id}", json=data)

    def delete_location(self, location_id: int) -> None:
        # Already gone is not an error (mirrors LocalRepo).
        self._optional("POST", f"/api/locations/{location_id}/delete")

    # -- dashboard --------------------------------------------------------- #
    def stats(self) -> dict:
        return self._request("GET", "/api/stats") or {}

    def status_counts(self) -> list[dict]:
        data = self._request("GET", "/api/dashboard") or {}
        return data.get("status_counts", [])

    def personal_stats(self) -> dict:
        return self._request("GET", "/api/personal-stats") or {}

    def goals(self) -> dict:
        return self._request("GET", "/api/goals") or {}

    def save_goals(self, goals: dict) -> None:
        self._request("POST", "/api/goals", json=goals)

    def want_list(self) -> list[dict]:
        return self._request("GET", "/api/wantlist") or []

    def add_want(self, entry: dict) -> None:
        self._request("POST", "/api/wantlist", json=entry)

    def remove_want(self, entry_id: str) -> None:
        self._request("DELETE", f"/api/wantlist/{quote(entry_id, safe='')}")

    def sagas(self) -> list[str]:
        return self._request("GET", "/api/sagas") or []


# --------------------------------------------------------------------------- #
# Standalone helpers (used by the settings/login dialog)
# --------------------------------------------------------------------------- #
def login(base_url: str, username: str, password: str, *, label: str | None = None) -> dict:
    """Exchange a username and password for an API token.

    Returns the server's ``{"token": ..., "user": {...}}`` payload.
    """
    base = (base_url or "").strip().rstrip("/")
    if not base:
        raise RepoError(_("Enter the backend URL first."))
    payload = {
        "username": username,
        "password": password,
        "label": label or device_label(),
    }
    try:
        with httpx.Client(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as client:
            response = client.post(f"{base}/api/auth/login", json=payload)
    except httpx.HTTPError as exc:
        raise ConnectionFailure(
            _("Could not reach %(url)s. Check the backend URL and your connection.")
            % {"url": base}
        ) from exc
    if response.status_code == 401:
        raise AuthError(_("Incorrect username or password."))
    if response.status_code >= 400:
        raise RepoError(_error_detail(response))
    try:
        data = response.json()
    except ValueError as exc:
        raise RepoError(_("The server did not return a valid response.")) from exc
    if not isinstance(data, dict):
        raise RepoError(_("The server did not return a valid response."))
    token = data.get("token")
    if not isinstance(token, str) or not token.strip():
        raise RepoError(_("The server did not return a sign-in token."))
    return data


def device_label() -> str:
    """A short note telling the server which device a token belongs to."""
    try:
        return f"{socket.gethostname()} (desktop)"
    except OSError:  # pragma: no cover - hostname lookup rarely fails
        return "desktop"


def _error_detail(response: httpx.Response) -> str:
    """Pull a readable message out of a FastAPI error body."""
    try:
        data = response.json()
    except ValueError:
        data = None
    if isinstance(data, dict):
        detail = data.get("detail")
        if isinstance(detail, str) and detail:
            return detail
        if isinstance(detail, list) and detail:
            first = detail[0]
            if isinstance(first, dict) and first.get("msg"):
                return str(first["msg"])
    return _("The server returned an error (%s).") % response.status_code


def _jsonable(value: Any) -> Any:
    """Recursively turn dates into ISO strings so a payload is JSON-safe."""
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


# --------------------------------------------------------------------------- #
# The active repo
# --------------------------------------------------------------------------- #
_repo: Repo | None = None


def set_repo(repo: Repo | None) -> None:
    """Install the repo the UI should use (called once at start-up)."""
    global _repo
    _repo = repo


def current_repo() -> Repo | None:
    """The active repo, or ``None`` if the app has not chosen one yet."""
    return _repo


def get_repo() -> Repo:
    """The active repo. Raises if the app never installed one."""
    if _repo is None:
        raise RepoError(_("No catalogue is configured yet."))
    return _repo
