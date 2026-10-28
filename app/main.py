"""BiblioJules application entry point (FastAPI app factory)."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlencode

from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import __version__
from .bootstrap import prepare_database, sync_on_start
from .config import settings
from .dependencies import (
    AuthenticationRequired,
    PermissionDenied,
    require_admin,
    require_user,
)
from .i18n import LanguageMiddleware, _
from .routers import admin, api, auth, books, health, import_route as import_router, locations, lookup, pages, statuses
from .templating import templates

logging.basicConfig(level=logging.INFO)

STATIC_DIR = Path(__file__).resolve().parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    prepare_database()
    if settings.sync_on_start:
        sync_on_start()
    yield


def create_app() -> FastAPI:
    docs_enabled = settings.enable_docs
    app = FastAPI(
        title=settings.app_name,
        description=settings.app_description,
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if docs_enabled else None,
        redoc_url="/redoc" if docs_enabled else None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )

    # Runs outermost so the per-request language is set before anything renders.
    app.add_middleware(LanguageMiddleware)

    if settings.cors_origin_list:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origin_list,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    # Uploaded covers live next to the database (local-only, never synced) and
    # are served from their own path so they stay out of the shared snapshot.
    from .config import DATA_DIR

    covers_dir = DATA_DIR / "covers"
    covers_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/covers", StaticFiles(directory=str(covers_dir)), name="covers")

    # Browsers ask for /favicon.ico even when base.html points at an icon, so
    # serve the generated file instead of a 404. Public like /static.
    @app.get("/favicon.ico", include_in_schema=False)
    async def favicon() -> FileResponse:
        return FileResponse(STATIC_DIR / "img" / "favicon.ico")

    # Public first: health, login/logout and the language switcher. Then every
    # other router behind the appropriate guard. The JSON API authenticates with
    # a bearer token; the HTML routes with the session cookie.
    app.include_router(health.router)
    app.include_router(auth.router)

    app.include_router(api.router, dependencies=[Depends(require_user)])
    app.include_router(lookup.router, dependencies=[Depends(require_user)])
    app.include_router(books.router, dependencies=[Depends(require_user)])
    app.include_router(locations.router, dependencies=[Depends(require_user)])
    app.include_router(statuses.router, dependencies=[Depends(require_user)])
    app.include_router(pages.router, dependencies=[Depends(require_user)])
    app.include_router(import_router.router, dependencies=[Depends(require_user)])
    app.include_router(admin.router, dependencies=[Depends(require_admin)])

    @app.exception_handler(AuthenticationRequired)
    async def _authentication_required(request: Request, exc: AuthenticationRequired):
        if request.url.path.startswith("/api/"):
            return JSONResponse(
                {"detail": "Not authenticated"},
                status_code=401,
                headers={"WWW-Authenticate": "Bearer"},
            )
        target = "/login"
        if exc.next_url:
            target += "?" + urlencode({"next": exc.next_url})
        return RedirectResponse(target, status_code=303)

    @app.exception_handler(PermissionDenied)
    async def _permission_denied(request: Request, exc: PermissionDenied):
        detail = exc.detail or _("You do not have permission to do that.")
        if request.url.path.startswith("/api/"):
            return JSONResponse({"detail": detail}, status_code=403)
        if request.headers.get("HX-Request"):
            return templates.TemplateResponse(
                request,
                "_fragment_error.html",
                {"message": detail},
                status_code=403,
            )
        return templates.TemplateResponse(
            request, "403.html", {"message": detail}, status_code=403
        )

    @app.exception_handler(StarletteHTTPException)
    async def not_found(request: Request, exc: StarletteHTTPException):
        # HTMX swaps an HTML fragment, never a raw JSON error object.
        if request.headers.get("HX-Request"):
            return templates.TemplateResponse(
                request,
                "_fragment_error.html",
                {"message": exc.detail or _("Something went wrong.")},
                status_code=exc.status_code,
            )
        # Return a friendly HTML page for browser navigation.
        if exc.status_code == 404 and "text/html" in request.headers.get("accept", ""):
            return templates.TemplateResponse(
                request,
                "404.html",
                {"message": exc.detail or _("Not found")},
                status_code=404,
            )

        return JSONResponse(
            {"detail": exc.detail}, status_code=exc.status_code, headers=exc.headers
        )

    return app


app = create_app()
