"""FastAPI dependencies for authentication and CSRF.

Authentication resolves to either an ``api`` token sent as
``Authorization: Bearer …`` (used by the desktop and mobile clients) or the
``web`` token stored in an httpOnly cookie (used by the browser). Both are
opaque and looked up server-side, so a token can be revoked instantly.

The resolved user is stashed on ``request.state`` so templates can show the
current account (see ``app.templating``) without every route threading it
through by hand.
"""

from __future__ import annotations

import secrets

from fastapi import Depends, Request
from sqlalchemy.orm import Session

from .database import get_db
from .i18n import _
from .models import User
from .models.token import KIND_API, KIND_WEB
from .services import auth

SESSION_COOKIE = "bj_session"
CSRF_COOKIE = "bj_csrf"
CSRF_HEADER = "x-csrf-token"
CSRF_FIELD = "_csrf"

SAFE_METHODS = {"GET", "HEAD", "OPTIONS", "TRACE"}


# --------------------------------------------------------------------------- #
# Exceptions (turned into responses by handlers in app.main)
# --------------------------------------------------------------------------- #
class AuthProblem(Exception):
    """Base class for auth/permission failures."""

    status_code = 403
    detail: str | None = None


class AuthenticationRequired(AuthProblem):
    """An anonymous request tried to reach a protected route."""

    status_code = 401

    def __init__(self, next_url: str = "/") -> None:
        super().__init__()
        self.next_url = next_url


class PermissionDenied(AuthProblem):
    status_code = 403


class CsrfError(PermissionDenied):
    def __init__(self) -> None:
        super().__init__()
        self.detail = _(
            "Your session expired or the page was stale. Please reload and try again."
        )


# --------------------------------------------------------------------------- #
# Resolution
# --------------------------------------------------------------------------- #
def _resolve(db: Session, request: Request) -> tuple[User | None, object | None]:
    header = request.headers.get("authorization", "")
    if header[:7].lower() == "bearer ":
        token = auth.get_token(db, header[7:].strip(), kind=KIND_API)
        if token is not None:
            auth.touch_token(db, token)
            return token.user, token
        # A bad bearer token must not silently fall back to the cookie.
        return None, None

    # The JSON API is bearer-only for the general catalogue endpoints;
    # the personal (local-only) endpoints additionally accept the browser
    # session cookie because the web UI reads/writes them with plain fetch().
    personal_paths = (
        "/api/personal-stats",
        "/api/goals",
        "/api/wantlist",
    )
    if request.url.path.startswith("/api/") and not any(
        request.url.path == p or request.url.path.startswith(p + "/") for p in personal_paths
    ):
        return None, None

    raw = request.cookies.get(SESSION_COOKIE)
    if raw:
        token = auth.get_token(db, raw, kind=KIND_WEB)
        if token is not None:
            auth.touch_token(db, token)
            return token.user, token

    return None, None


async def get_current_user(
    request: Request, db: Session = Depends(get_db)
) -> User | None:
    """Attach the current user (if any) to the request and return it."""
    user, token = _resolve(db, request)
    request.state.user = user
    request.state.token = token
    request.state.csrf = getattr(token, "csrf_token", None) if token else None
    return user


# --------------------------------------------------------------------------- #
# Enforcement
# --------------------------------------------------------------------------- #
async def _enforce_csrf(request: Request) -> None:
    """Reject state-changing browser requests without the session's CSRF value."""
    if request.method in SAFE_METHODS:
        return
    # Bearer-token API calls carry no cookies, so CSRF is not a concern there.
    # A browser session that happens to call /api/ *is* cookie-authenticated,
    # though, and those endpoints can change personal data (goals, wantlist),
    # so they get the same check as the HTML routes.
    if request.url.path.startswith("/api/"):
        token = getattr(request.state, "token", None)
        if getattr(token, "kind", None) != KIND_WEB:
            return

    expected = getattr(request.state, "csrf", None)
    if not expected:
        return

    submitted = request.headers.get(CSRF_HEADER)
    if not submitted:
        content_type = request.headers.get("content-type", "")
        if content_type.startswith("application/x-www-form-urlencoded") or content_type.startswith(
            "multipart/form-data"
        ):
            form = await request.form()
            submitted = form.get(CSRF_FIELD)

    if not submitted or not secrets.compare_digest(str(submitted), str(expected)):
        raise CsrfError()


async def require_user(
    request: Request, user: User | None = Depends(get_current_user)
) -> User:
    if user is None:
        next_url = request.url.path
        if request.url.query:
            next_url += "?" + request.url.query
        raise AuthenticationRequired(next_url=next_url)
    await _enforce_csrf(request)
    return user


async def require_admin(user: User = Depends(require_user)) -> User:
    if not user.is_admin:
        raise PermissionDenied()
    return user
