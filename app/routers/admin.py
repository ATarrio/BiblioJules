"""Administrator panel: who may use the library.

A small, deliberately functional set of screens for the handful of people who
share the shelf: list the accounts, add one, change a role, reset a password or
remove someone. Only administrators can reach any of these routes (the whole
router is mounted behind :func:`app.dependencies.require_admin`).
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from sqlalchemy.orm import Session

from ..config import settings
from ..database import get_db
from ..i18n import _
from ..models import User
from ..models.user import ROLE_ADMIN, ROLE_MEMBER
from ..schemas import UserIn, UserUpdateIn
from ..services import auth
from ..services import sync as sync_service
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



# --------------------------------------------------------------------------- #
# Shared library (sync)
# --------------------------------------------------------------------------- #
def _sync_summary(result) -> str:
    parts: list[str] = []
    merge = result.merge
    if merge is not None and merge.changes:
        parts.append(
            _("Merged %(changes)s change(s) from %(device)s.")
            % {
                "changes": merge.changes,
                "device": merge.source_device or _("another device"),
            }
        )
    elif merge is not None:
        parts.append(_("The shared file had nothing new."))
    if result.pushed:
        parts.append(_("Published a fresh snapshot."))
    else:
        parts.append(_("Nothing needed publishing."))
    if merge is not None and merge.conflicts:
        parts.append(
            _("%s note(s) about edits made on both devices are in the sync report.")
            % len(merge.conflicts)
        )
    return " ".join(parts)


@router.get("/admin/sync", response_class=HTMLResponse)
def sync_page(request: Request):
    try:
        db_path = sync_service.database_path()
    except sync_service.SyncError as exc:
        return templates.TemplateResponse(
            request,
            "admin/sync.html",
            {"status": {"configured": False}, "configured": "", "env_locked": False, "error": str(exc)},
        )
    configured = sync_service.configured_sync_file(db_path)
    status = sync_service.sync_status(db_path=db_path)
    return templates.TemplateResponse(
        request,
        "admin/sync.html",
        {
            "status": status,
            "configured": configured,
            "env_locked": bool(settings.sync_file),
            "sync_on_start": settings.sync_on_start,
            "error": request.query_params.get("error") or status.get("error"),
            "ok": request.query_params.get("ok"),
        },
    )


@router.post("/admin/sync/settings")
async def save_sync_settings(request: Request):
    form = await request.form()
    value = (form.get("sync_file") or "").strip()
    try:
        db_path = sync_service.database_path()
        if value:
            # Fails early when the folder is mistyped.
            sync_service.resolve_target(value, db_path=db_path)
        sync_service.set_sync_file(db_path, value)
    except sync_service.SyncError as exc:
        return _redirect(request, "/admin/sync?" + _error_param(str(exc)))
    return _redirect(request, "/admin/sync?" + _ok_param(_("Shared folder saved.")))


@router.post("/admin/sync")
def run_sync(request: Request):
    try:
        result = sync_service.sync_now()
    except sync_service.SyncError as exc:
        return _redirect(request, "/admin/sync?" + _error_param(str(exc)))
    except Exception as exc:  # pragma: no cover - unexpected filesystem trouble
        logging.exception("Shared library sync failed")
        return _redirect(
            request, "/admin/sync?" + _error_param(_("The sync failed: %s") % exc)
        )
    return _redirect(request, "/admin/sync?" + _ok_param(_sync_summary(result)))


def _ok_param(message: str) -> str:
    from urllib.parse import urlencode

    return urlencode({"ok": message})


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
