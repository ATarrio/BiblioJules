"""Desktop entry point: create the QApplication, pick a data source, show the UI."""

from __future__ import annotations

import sys

from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from .. import i18n, preferences
from ..config import settings
from .main_window import MainWindow
from .repo import LocalRepo, RemoteRepo, set_repo
from .theme import LOGO_PNG, apply_theme


def run(argv: list[str] | None = None) -> int:
    app = QApplication(argv if argv is not None else sys.argv)
    app.setApplicationName(settings.app_name)
    app.setApplicationDisplayName(settings.app_name)
    app.setOrganizationName(settings.app_name)

    # Window/taskbar icon. The PNG (not the SVG) so every platform and desktop
    # environment gets a bitmap it recognises.
    app.setWindowIcon(QIcon(LOGO_PNG))

    # Apply the saved UI language before any widget text is built.
    i18n.set_language(preferences.get_preferred_language())

    apply_theme(app, preferences.get_color_theme())

    if preferences.get_mode() == preferences.MODE_REMOTE:
        # Remote mode touches no local database at all.
        set_repo(RemoteRepo(preferences.get_backend_url(), preferences.get_api_token()))
    else:
        from .db import initialize_database

        # Same tables + seed data as the web app's startup hook.
        initialize_database()
        set_repo(LocalRepo())

        # Optional auto-sync on start (never on close: a merge changes data and
        # deserves the user watching). Keep going if the folder is unavailable.
        if preferences.get_sync_on_start():
            folder = preferences.get_sync_file()
            if folder:
                from ..services import sync as sync_service

                try:
                    result = sync_service.sync_now(folder)
                    merge = result.merge
                    if merge is not None and merge.changes:
                        print(
                            "BiblioJules: merged "
                            f"{merge.changes} change(s) from the shared folder."
                        )
                except sync_service.SyncError as exc:
                    print(f"BiblioJules: shared library not synced: {exc}", file=sys.stderr)
                except Exception:  # pragma: no cover - unexpected filesystem trouble
                    print("BiblioJules: shared library sync failed.", file=sys.stderr)

    window = MainWindow()
    window.show()
    return app.exec()
