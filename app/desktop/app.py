"""Desktop entry point: create the QApplication, prepare the DB, show the UI."""

from __future__ import annotations

import sys

from PySide6.QtWidgets import QApplication

from ..config import settings
from .db import initialize_database
from .main_window import MainWindow
from .theme import apply_theme


def run(argv: list[str] | None = None) -> int:
    app = QApplication(argv if argv is not None else sys.argv)
    app.setApplicationName(settings.app_name)
    app.setApplicationDisplayName(settings.app_name)
    app.setOrganizationName(settings.app_name)

    apply_theme(app)

    # Same tables + seed data as the web app's startup hook.
    initialize_database()

    window = MainWindow()
    window.show()
    return app.exec()
