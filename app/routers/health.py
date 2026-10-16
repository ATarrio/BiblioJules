"""Health / uptime endpoint.

Returns ``200 OK`` when the app is up and the database answers, and
``503 Service Unavailable`` when the database is unreachable — so uptime
monitors can distinguish "process is running" from "actually usable".
"""

from __future__ import annotations

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..database import get_db

router = APIRouter(tags=["health"])


@router.get("/health")
def health(db: Session = Depends(get_db)) -> JSONResponse:
    try:
        db.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001 - report any DB failure as unhealthy
        return JSONResponse(
            status_code=503,
            content={"status": "error", "database": "unreachable", "detail": str(exc)},
        )
    return JSONResponse(status_code=200, content={"status": "ok", "database": "ok"})
