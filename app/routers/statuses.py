"""Status management (add / edit / delete custom statuses)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..models import Status
from ..services import library
from .common import (
    form_dict as _form_dict,
    redirect as _redirect,
    redirect_error as _redirect_error,
)

router = APIRouter()


@router.post("/statuses")
async def create_status(request: Request, db: Session = Depends(get_db)):
    form = await _form_dict(request)
    name = (form.get("name") or "").strip()
    if name:
        try:
            library.create_status(
                db,
                name=name,
                color=form.get("color") or "#64748b",
                icon=form.get("icon"),
                description=form.get("description"),
            )
        except ValueError as exc:
            return _redirect_error(request, "/statuses", str(exc))
    return _redirect(request, "/statuses")


@router.post("/statuses/{status_id}")
async def update_status(status_id: int, request: Request, db: Session = Depends(get_db)):
    status = db.get(Status, status_id)
    if status is None:
        raise HTTPException(status_code=404, detail=_("Status not found"))
    form = await _form_dict(request)
    try:
        library.update_status(
            db,
            status,
            name=form.get("name"),
            color=form.get("color"),
            icon=form.get("icon"),
            description=form.get("description"),
        )
    except ValueError as exc:
        return _redirect_error(request, "/statuses", str(exc))
    return _redirect(request, "/statuses")


@router.post("/statuses/{status_id}/delete")
def delete_status(status_id: int, request: Request, db: Session = Depends(get_db)):
    status = db.get(Status, status_id)
    if status is None:
        raise HTTPException(status_code=404, detail=_("Status not found"))
    try:
        library.delete_status(db, status)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _redirect(request, "/statuses")
