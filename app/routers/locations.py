"""Location management (add / edit / delete shelves, rooms, boxes...)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..models import Location
from ..services import library

router = APIRouter()


def _redirect(request: Request, url: str) -> Response:
    if request.headers.get("HX-Request"):
        return Response(status_code=204, headers={"HX-Redirect": url})
    return Response(status_code=303, headers={"Location": url})


async def _form_dict(request: Request) -> dict:
    form = await request.form()
    return dict(form)


@router.post("/locations")
async def create_location(request: Request, db: Session = Depends(get_db)):
    form = await _form_dict(request)
    name = (form.get("name") or "").strip()
    if name:
        library.create_location(
            db,
            name=name,
            parent_id=form.get("parent_id"),
            kind=form.get("kind"),
            description=form.get("description"),
        )
    return _redirect(request, "/locations")


@router.post("/locations/{location_id}")
async def update_location(location_id: int, request: Request, db: Session = Depends(get_db)):
    location = db.get(Location, location_id)
    if location is None:
        raise HTTPException(status_code=404, detail=_("Location not found"))
    form = await _form_dict(request)
    try:
        library.update_location(
            db,
            location,
            name=form.get("name"),
            parent_id=form.get("parent_id", ...) if "parent_id" in form else ...,
            kind=form.get("kind"),
            description=form.get("description"),
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _redirect(request, "/locations")


@router.post("/locations/{location_id}/delete")
def delete_location(location_id: int, request: Request, db: Session = Depends(get_db)):
    location = db.get(Location, location_id)
    if location is None:
        raise HTTPException(status_code=404, detail=_("Location not found"))
    library.delete_location(db, location)
    return _redirect(request, "/locations")
