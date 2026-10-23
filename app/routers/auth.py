"""Login / logout and the small account endpoints.

Runs in two flavours:

* the browser, which gets an httpOnly session cookie after posting the login
  form, and
* native clients (desktop, mobile), which post to ``/api/auth/login`` and get
  back a bearer token.

The whole router is mounted *without* the blanket ``require_user`` guard, so
``/login`` and ``/api/auth/login`` stay reachable; the endpoints that do need an
account say so explicitly.
"""

from __future__ import annotations

import secrets
from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from sqlalchemy.orm import Session

from .. import i18n, themes
from ..config import settings
from ..database import get_db
from ..i18n import _
from ..dependencies import (
    CSRF_COOKIE,
    CSRF_FIELD,
    SESSION_COOKIE,
    get_current_user,
    require_user,
)
from ..models import User
from ..models.token import KIND_API, KIND_WEB
from ..schemas import LoginIn
from ..services import auth, rate_limit
from ..services.serializers import user_to_dict
from ..templating import templates

router = APIRouter()

# How long a language choice sticks (a year).
_LANGUAGE_COOKIE_MAX_AGE = 60 * 60 * 24 * 365
# …and how long the accent colour does (same again).
_THEME_COOKIE_MAX_AGE = 60 * 60 * 24 * 365


def _session_max_age() -> int:
    return max(1, settings.session_ttl_days) * 60 * 60 * 24


def _safe_next(value: str | None, default: str = "/") -> str:
    """Only ever redirect back into this site (no open redirects)."""
    if not value or not value.startswith("/") or value.startswith("//"):
        return default
    if value.startswith("/login"):
        return default
    return value


def _set_session_cookie(response, raw_token: str) -> None:
    response.set_cookie(
        SESSION_COOKIE,
        raw_token,
        max_age=_session_max_age(),
        httponly=True,
        samesite="lax",
        secure=settings.cookie_secure,
        path="/",
    )


# --------------------------------------------------------------------------- #
# Browser: language switcher
# --------------------------------------------------------------------------- #
@router.get("/language")
def switch_language(request: Request):
    """Remember the chosen language in a cookie and go back where we came from."""
    code = i18n.normalize_language(request.query_params.get("lang"))
    target = _safe_next(
        request.query_params.get("next") or request.headers.get("referer") or "/"
    )
    response = RedirectResponse(target, status_code=303)
    response.set_cookie(
        "lang", code, max_age=_LANGUAGE_COOKIE_MAX_AGE, samesite="lax", path="/"
    )
    return response


# --------------------------------------------------------------------------- #
# Browser: colour theme switcher
# --------------------------------------------------------------------------- #
@router.get("/theme")
def switch_theme(request: Request):
    """Remember the chosen accent colour in a cookie and go back."""
    slug = themes.normalize_theme(request.query_params.get("theme"))
    target = _safe_next(
        request.query_params.get("next") or request.headers.get("referer"),
        default="/settings",
    )
    response = RedirectResponse(target, status_code=303)
    response.set_cookie(
        themes.THEME_COOKIE, slug, max_age=_THEME_COOKIE_MAX_AGE, samesite="lax", path="/"
    )
    return response


# --------------------------------------------------------------------------- #
# Browser: login / logout
# --------------------------------------------------------------------------- #
@router.get("/login", response_class=HTMLResponse)
def login_form(
    request: Request,
    db: Session = Depends(get_db),
    user: User | None = Depends(get_current_user),
):
    next_url = _safe_next(request.query_params.get("next"))
    if user is not None:
        return RedirectResponse(next_url, status_code=303)

    csrf = request.cookies.get(CSRF_COOKIE) or secrets.token_urlsafe(24)
    # Templates read `csrf_token` from the shared context processor in
    # app/templating.py, which is fed from request.state. Starlette applies
    # context processors *after* the context dict below, so a token passed
    # there would be overwritten — publish it on the request instead, so the
    # hidden field always matches the cookie we set.
    request.state.csrf = csrf
    response = templates.TemplateResponse(
        request,
        "auth/login.html",
        {
            "next": next_url,
            "setup_needed": auth.count_users(db) == 0,
            "username": "",
            "error": None,
        },
    )
    if request.cookies.get(CSRF_COOKIE) != csrf:
        response.set_cookie(
            CSRF_COOKIE,
            csrf,
            max_age=60 * 60 * 12,
            httponly=True,
            samesite="lax",
            secure=settings.cookie_secure,
            path="/",
        )
    return response


@router.post("/login", response_class=HTMLResponse)
async def login(request: Request, db: Session = Depends(get_db)):
    form = await request.form()
    username = (form.get("username") or "").strip()
    password = form.get("password") or ""
    next_url = _safe_next(form.get("next"))

    expected = request.cookies.get(CSRF_COOKIE)
    submitted = form.get(CSRF_FIELD)
    if not expected or not submitted or not secrets.compare_digest(str(submitted), str(expected)):
        return _login_error(
            db, request, username, next_url, _("Your session expired. Please try again.")
        )

    keys = [f"ip:{rate_limit.client_key(request)}", f"user:{username.casefold()}"]
    wait = rate_limit.retry_after(keys)
    if wait:
        return _login_error(
            db,
            request,
            username,
            next_url,
            _("Too many sign-in attempts. Try again in %(seconds)s seconds.")
            % {"seconds": wait},
        )

    user = auth.authenticate(db, username, password)
    if user is None:
        rate_limit.record_failure(keys)
        return _login_error(
            db,
            request,
            username,
            next_url,
            _("Incorrect username or password.") if auth.count_users(db) else None,
        )
    rate_limit.reset(keys)

    raw, _token = auth.create_token(
        db, user, kind=KIND_WEB, label=(request.headers.get("user-agent") or "")[:120]
    )
    response = RedirectResponse(next_url, status_code=303)
    _set_session_cookie(response, raw)
    response.delete_cookie(CSRF_COOKIE, path="/")
    return response


def _login_error(db, request, username, next_url, message):
    csrf = request.cookies.get(CSRF_COOKIE) or secrets.token_urlsafe(24)
    # As in login_form(): the template takes csrf_token from request.state, so
    # a failed attempt re-renders a form that can actually be submitted again.
    request.state.csrf = csrf
    response = templates.TemplateResponse(
        request,
        "auth/login.html",
        {
            "next": next_url,
            "setup_needed": auth.count_users(db) == 0,
            "username": username,
            "error": message,
        },
        status_code=401,
    )
    if request.cookies.get(CSRF_COOKIE) != csrf:
        response.set_cookie(
            CSRF_COOKIE,
            csrf,
            max_age=60 * 60 * 12,
            httponly=True,
            samesite="lax",
            secure=settings.cookie_secure,
            path="/",
        )
    return response


@router.post("/logout")
def logout(request: Request, db: Session = Depends(get_db), user: User = Depends(require_user)):
    token = getattr(request.state, "token", None)
    if token is not None:
        auth.revoke_token(db, token)
    response = RedirectResponse("/login", status_code=303)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return response


# --------------------------------------------------------------------------- #
# Native clients: JSON login / me / logout
# --------------------------------------------------------------------------- #
@router.post("/api/auth/login")
def api_login(payload: LoginIn, request: Request, db: Session = Depends(get_db)):
    keys = [f"ip:{rate_limit.client_key(request)}", f"user:{payload.username.casefold()}"]
    wait = rate_limit.retry_after(keys)
    if wait:
        return JSONResponse(
            {
                "detail": _("Too many sign-in attempts. Try again in %(seconds)s seconds.")
                % {"seconds": wait}
            },
            status_code=429,
            headers={"Retry-After": str(wait)},
        )
    user = auth.authenticate(db, payload.username, payload.password)
    if user is None:
        rate_limit.record_failure(keys)
        return JSONResponse(
            {"detail": "Incorrect username or password."}, status_code=401
        )
    rate_limit.reset(keys)
    raw, token = auth.create_token(
        db,
        user,
        kind=KIND_API,
        label=payload.label or (request.headers.get("user-agent") or "")[:120],
    )
    return {
        "token": raw,
        "expires_at": token.expires_at.isoformat() if token.expires_at else None,
        "user": user_to_dict(user),
    }


@router.get("/api/auth/me")
def api_me(user: User = Depends(require_user)):
    return user_to_dict(user)


@router.post("/api/auth/logout")
def api_logout(request: Request, db: Session = Depends(get_db), user: User = Depends(require_user)):
    token = getattr(request.state, "token", None)
    if token is not None:
        auth.revoke_token(db, token)
    return {"ok": True}
