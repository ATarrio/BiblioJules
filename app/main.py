"""BiblioJules application entry point (FastAPI app factory)."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from .config import settings
from .database import Base, SessionLocal, engine
from .i18n import LanguageMiddleware, _
from .routers import api, books, health, locations, lookup, pages, statuses
from .services.library import prune_orphans
from .services.seed import seed_defaults
from .templating import templates

logging.basicConfig(level=logging.INFO)

STATIC_DIR = Path(__file__).resolve().parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables on first run. For a schema that needs to evolve, add
    # Alembic later — the naming convention is already in place.
    Base.metadata.create_all(bind=engine)

    # Seed the built-in statuses (available, reading, lent, wishlist...).
    db = SessionLocal()
    try:
        seed_defaults(db)
        # Clear out authors/publishers left behind by earlier book deletions.
        prune_orphans(db)
    finally:
        db.close()

    yield


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        description=settings.app_description,
        version="0.1.0",
        lifespan=lifespan,
    )

    @app.middleware("http")
    async def log_request_headers(request: Request, call_next):
        # Temporary diagnostic: log who is calling us (uvicorn's access log
        # omits headers, so an unexpected hit like `GET /v1/models` is hard to
        # attribute). Handy for tracking down OpenAI-compatible clients that
        # have been pointed at this port.
        header_dump = "; ".join(f"{key}: {value}" for key, value in request.headers.items())
        logging.info("INCOMING %s %s | %s", request.method, request.url.path, header_dump)
        return await call_next(request)

    # Runs outermost so the per-request language is set before anything renders.
    app.add_middleware(LanguageMiddleware)

    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    # JSON API first (its paths are unambiguous), then the HTML UI.
    app.include_router(health.router)
    app.include_router(api.router)
    app.include_router(lookup.router)
    app.include_router(books.router)
    app.include_router(locations.router)
    app.include_router(statuses.router)
    app.include_router(pages.router)

    @app.exception_handler(StarletteHTTPException)
    async def not_found(request: Request, exc: StarletteHTTPException):
        # Return a friendly HTML page for browser navigation.
        if exc.status_code == 404 and "text/html" in request.headers.get("accept", ""):
            return templates.TemplateResponse(
                request,
                "404.html",
                {"message": exc.detail or _("Not found")},
                status_code=404,
            )
        from fastapi.responses import JSONResponse

        return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)

    return app


app = create_app()
