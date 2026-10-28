"""Location management (add / edit / delete shelves, rooms, boxes...)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from ..database import get_db
from ..i18n import _
from ..models import Location
from ..services import library
from .common import (
    form_dict as _form_dict,
    redirect as _redirect,
    redirect_error as _redirect_error,
)

router = APIRouter()


@router.post("/locations")
async def create_location(request: Request, db: Session = Depends(get_db)):
    form = await _form_dict(request)
    name = (form.get("name") or "").strip()
    if name:
        try:
            library.create_location(
                db,
                name=name,
                parent_id=form.get("parent_id"),
                kind=form.get("kind"),
                description=form.get("description"),
            )
        except ValueError as exc:
            return _redirect_error(request, "/locations", str(exc))
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
        return _redirect_error(request, "/locations", str(exc))
    return _redirect(request, "/locations")


@router.post("/locations/{location_id}/delete")
def delete_location(location_id: int, request: Request, db: Session = Depends(get_db)):
    location = db.get(Location, location_id)
    if location is None:
        raise HTTPException(status_code=404, detail=_("Location not found"))
    library.delete_location(db, location)
    return _redirect(request, "/locations")
