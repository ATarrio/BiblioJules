"""Desktop entry point: create the QApplication, pick a data source, show the UI."""

from __future__ import annotations

import sys

from PySide6.QtWidgets import QApplication

from .. import i18n, preferences
from ..config import settings
from .main_window import MainWindow
from .repo import LocalRepo, RemoteRepo, set_repo
from .theme import apply_theme


def run(argv: list[str] | None = None) -> int:
    app = QApplication(argv if argv is not None else sys.argv)
    app.setApplicationName(settings.app_name)
    app.setApplicationDisplayName(settings.app_name)
    app.setOrganizationName(settings.app_name)

    # Apply the saved UI language before any widget text is built.
    i18n.set_language(preferences.get_preferred_language())

    apply_theme(app)

    if preferences.get_mode() == preferences.MODE_REMOTE:
        # Remote mode touches no local database at all.
        set_repo(RemoteRepo(preferences.get_backend_url(), preferences.get_api_token()))
    else:
        from .db import initialize_database

        # Same tables + seed data as the web app's startup hook.
        initialize_database()
        set_repo(LocalRepo())

    window = MainWindow()
    window.show()
    return app.exec()
