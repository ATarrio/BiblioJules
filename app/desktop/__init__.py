"""Qt (PySide6) desktop front-end for BiblioJules.

The desktop UI runs in one of two modes (see :mod:`app.desktop.repo`):

* **local** — it opens the SQLite database directly, through exactly the same
  SQLAlchemy models and service layer (``app.services.library``) as the FastAPI
  web app, so both front-ends operate on the same file; or
* **remote** — it talks to a hosted BiblioJules server over its JSON API, so
  the same catalogue can be used from anywhere without a local database.

Views and dialogs never know which one is active.
"""

from __future__ import annotations


def main(argv: list[str] | None = None) -> int:
    """Launch the desktop application (returns the Qt exit code)."""
    from .app import run

    return run(argv)


__all__ = ["main"]
