"""Health / uptime endpoint.

Returns ``200 OK`` when the app is up and the database answers, and
``503 Service Unavailable`` when the database is unreachable — so uptime
monitors can distinguish "process is running" from "actually usable".
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..database import get_db

logger = logging.getLogger(__name__)

router = APIRouter(tags=["health"])


@router.get("/health")
def health(db: Session = Depends(get_db)) -> JSONResponse:
    try:
        db.execute(text("SELECT 1"))
    except Exception:  # noqa: BLE001 - report any DB failure as unhealthy
        # The detail belongs in the server log: a public health check must not
        # leak a connection string, filesystem path or driver traceback.
        logger.exception("Health check failed: the database is unreachable")
        return JSONResponse(
            status_code=503,
            content={"status": "error", "database": "unreachable"},
        )
    return JSONResponse(status_code=200, content={"status": "ok", "database": "ok"})
