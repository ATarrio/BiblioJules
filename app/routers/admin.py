"""Administrator panel: who may use the library.

A small, deliberately functional set of screens for the handful of people who
share the shelf: list the accounts, add one, change a role, reset a password or
remove someone. Only administrators can reach any of these routes (the whole
router is mounted behind :func:`app.dependencies.require_admin`).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..models import User
from ..models.user import ROLE_ADMIN, ROLE_MEMBER
from ..schemas import UserIn, UserUpdateIn
from ..services import auth
from ..services.serializers import user_to_dict
from ..templating import templates

router = APIRouter()


def _redirect(request: Request, url: str) -> Response:
    if request.headers.get("HX-Request"):
        return Response(status_code=204, headers={"HX-Redirect": url})
    return Response(status_code=303, headers={"Location": url})


def _current_user(request: Request) -> User:
    user = getattr(request.state, "user", None)
    if user is None:  # pragma: no cover - the router guard prevents this
        raise HTTPException(status_code=401, detail=_("Not authenticated"))
    return user


# --------------------------------------------------------------------------- #
# HTML
# --------------------------------------------------------------------------- #
@router.get("/admin/users", response_class=HTMLResponse)
def users_page(request: Request, db: Session = Depends(get_db)):
    return templates.TemplateResponse(
        request,
        "admin/users.html",
        {
            "users": auth.list_users(db),
            "me": _current_user(request),
            "roles": [ROLE_ADMIN, ROLE_MEMBER],
            "error": request.query_params.get("error"),
        },
    )


@router.post("/admin/users")
async def create_user(request: Request, db: Session = Depends(get_db)):
    form = await request.form()
    try:
        auth.create_user(
            db,
            username=form.get("username") or "",
            password=form.get("password") or "",
            role=(form.get("role") or ROLE_MEMBER).strip(),
            display_name=form.get("display_name"),
        )
    except ValueError as exc:
        return _redirect(request, "/admin/users?" + _error_param(str(exc)))
    return _redirect(request, "/admin/users")


@router.post("/admin/users/{user_id}")
async def update_user(user_id: int, request: Request, db: Session = Depends(get_db)):
    user = auth.get_user(db, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail=_("User not found"))
    form = await request.form()
    is_active = "is_active" in form
    if not is_active and user.id == _current_user(request).id:
        return _redirect(
            request, "/admin/users?" + _error_param(_("You cannot deactivate yourself."))
        )
    try:
        auth.update_user(
            db,
            user,
            display_name=form.get("display_name"),
            role=(form.get("role") or user.role).strip(),
            is_active=is_active,
            password=(form.get("password") or "").strip() or None,
        )
    except ValueError as exc:
        return _redirect(request, "/admin/users?" + _error_param(str(exc)))
    return _redirect(request, "/admin/users")


@router.post("/admin/users/{user_id}/delete")
def delete_user(user_id: int, request: Request, db: Session = Depends(get_db)):
    user = auth.get_user(db, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail=_("User not found"))
    if user.id == _current_user(request).id:
        return _redirect(
            request, "/admin/users?" + _error_param(_("You cannot delete your own account."))
        )
    try:
        auth.delete_user(db, user)
    except ValueError as exc:
        return _redirect(request, "/admin/users?" + _error_param(str(exc)))
    return _redirect(request, "/admin/users")


def _error_param(message: str) -> str:
    from urllib.parse import urlencode

    return urlencode({"error": message})


# --------------------------------------------------------------------------- #
# JSON API
# --------------------------------------------------------------------------- #
@router.get("/api/users")
def list_users(db: Session = Depends(get_db)):
    return [user_to_dict(user) for user in auth.list_users(db)]


@router.post("/api/users", status_code=201)
def api_create_user(payload: UserIn, db: Session = Depends(get_db)):
    try:
        user = auth.create_user(
            db,
            username=payload.username,
            password=payload.password,
            role=payload.role,
            display_name=payload.display_name,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return user_to_dict(user)


@router.put("/api/users/{user_id}")
def api_update_user(user_id: int, payload: UserUpdateIn, db: Session = Depends(get_db)):
    user = auth.get_user(db, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail=_("User not found"))
    fields = payload.model_dump(exclude_unset=True)
    try:
        auth.update_user(
            db,
            user,
            display_name=fields.get("display_name", ...),
            role=fields.get("role", ...),
            is_active=fields.get("is_active", ...),
            password=fields.get("password") or None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return user_to_dict(user)


@router.delete("/api/users/{user_id}", status_code=204)
def api_delete_user(user_id: int, db: Session = Depends(get_db)):
    user = auth.get_user(db, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail=_("User not found"))
    try:
        auth.delete_user(db, user)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
