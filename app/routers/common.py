"""HTTP helpers shared by the HTML routers.

The web UI has three ways to answer a request: redirect after a form post,
return a small error fragment to HTMX, or raise a normal HTTP error for a full
page load. Keeping those rules in one place stops the routers from drifting.
"""

from __future__ import annotations

from urllib.parse import urlencode

from fastapi import HTTPException, Request
from fastapi.responses import Response

from ..templating import templates


def redirect(request: Request, url: str) -> Response:
    """Redirect, transparently supporting HTMX requests."""
    if request.headers.get("HX-Request"):
        return Response(status_code=204, headers={"HX-Redirect": url})
    return Response(status_code=303, headers={"Location": url})


async def form_dict(request: Request) -> dict:
    form = await request.form()
    return {key: value for key, value in form.items()}


def fragment_error(request: Request, message: str, status_code: int = 400):
    """A small HTML error for HTMX, a normal HTTP error otherwise."""
    if request.headers.get("HX-Request"):
        return templates.TemplateResponse(
            request, "_fragment_error.html", {"message": message}, status_code=status_code
        )
    raise HTTPException(status_code=status_code, detail=message)


def redirect_error(request: Request, path: str, message: str) -> Response:
    """Send the browser back to ``path`` with a query-string error message."""
    return redirect(request, f"{path}?{urlencode({'error': message})}")


def user_id(request: Request) -> int | None:
    user = getattr(request.state, "user", None)
    return getattr(user, "id", None)
