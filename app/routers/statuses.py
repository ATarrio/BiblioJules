"""Status management (add / edit / delete custom statuses)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy.orm import Session
from urllib.parse import urlencode

from ..database import get_db
from ..i18n import _
from ..models import Status
from ..services import library

router = APIRouter()


def _redirect(request: Request, url: str) -> Response:
    if request.headers.get("HX-Request"):
        return Response(status_code=204, headers={"HX-Redirect": url})
    return Response(status_code=303, headers={"Location": url})


def _redirect_error(request: Request, message: str) -> Response:
    return _redirect(request, "/statuses?" + urlencode({"error": message}))


async def _form_dict(request: Request) -> dict:
    form = await request.form()
    return dict(form)


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
            return _redirect_error(request, str(exc))
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
        return _redirect_error(request, str(exc))
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
