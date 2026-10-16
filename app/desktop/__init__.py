"""Qt (PySide6) desktop front-end for BiblioJules.

The desktop UI is a second front-end over exactly the same SQLAlchemy models,
SQLite database and service layer (``app.services.library``) as the FastAPI web
app. It never talks to the web server: it opens the database file directly, so
both front-ends operate on the same catalog.
"""

from __future__ import annotations


def main(argv: list[str] | None = None) -> int:
    """Launch the desktop application (returns the Qt exit code)."""
    from .app import run

    return run(argv)


__all__ = ["main"]
