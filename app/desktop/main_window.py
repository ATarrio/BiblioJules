"""Main application window: sidebar navigation over the individual views."""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QAction, QIcon
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from .. import i18n, preferences
from ..config import settings
from ..i18n import _
from ..services import sync as sync_service
from .catalog import CatalogView
from .dashboard import DashboardView
from .discover import DiscoverView
from .import_view import ImportView
from .locations_view import LocationsView
from .reading_view import ReadingView
from .repo import AuthError, LocalRepo, RemoteRepo, Repo, RepoError, current_repo, set_repo
from .settings_dialog import SettingsDialog
from .settings_view import SettingsView
from .statuses_view import StatusesView
from .wantlist_view import WantlistView
from .theme import LOGO_SVG, apply_theme
from .workers import run_blocking

# (emoji, English source label) — order mirrors the web app's sidebar.
# Labels are translated when the UI is built, so a language switch can rebuild it.
_PAGES = [
    ("🏠", "Dashboard"),
    ("📚", "Catalog"),
    ("🔍", "Discover"),
    ("📖", "Reading stats"),
    ("⭐", "Want-to-read list"),
    ("📥", "Import"),
    ("📍", "Locations"),
    ("🏷️", "Statuses"),
    ("⚙️", "Settings"),
]


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(settings.app_name)
        self.resize(1240, 800)
        # Defer the first refresh so the sign-in prompt (if any) can appear
        # before any view asks the data source for rows.
        self._ready = False
        self._settings_open = False
        self._sync_running = False
        self._build_menu()
        self._build_ui()
        QTimer.singleShot(0, self._startup_check)

    # -- construction ------------------------------------------------------- #
    def _build_ui(self) -> None:
        # --- sidebar ----------------------------------------------------- #
        sidebar = QWidget()
        sidebar.setObjectName("Sidebar")
        sidebar.setFixedWidth(232)

        brand = QWidget()
        brand_layout = QHBoxLayout(brand)
        brand_layout.setContentsMargins(20, 18, 20, 12)
        brand_layout.setSpacing(8)
        logo_label = QLabel()
        logo_label.setObjectName("BrandLogo")
        # Rendered from the SVG at the label's size, so it stays sharp on HiDPI.
        logo_label.setPixmap(QIcon(LOGO_SVG).pixmap(26, 26))
        title_label = QLabel(settings.app_name)
        title_label.setObjectName("BrandTitle")
        brand_layout.addWidget(logo_label)
        brand_layout.addWidget(title_label)
        brand_layout.addStretch(1)

        self.nav = QListWidget()
        self.nav.setObjectName("NavList")
        self.nav.setFrameShape(QListWidget.Shape.NoFrame)
        for emoji, source in _PAGES:
            self.nav.addItem(QListWidgetItem(f"{emoji}   {_(source)}"))

        # Which catalogue are we using? Clicking opens the settings dialog.
        self.connection_btn = QPushButton(self._connection_label())
        self.connection_btn.setObjectName("ConnectionButton")
        self.connection_btn.setFlat(True)
        self.connection_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.connection_btn.setToolTip(_("Choose which library to use, and sign in."))
        self.connection_btn.clicked.connect(self._open_settings)
        connection_row = QWidget()
        connection_layout = QHBoxLayout(connection_row)
        connection_layout.setContentsMargins(14, 6, 14, 0)
        connection_layout.addWidget(self.connection_btn)

        # Language selector, pinned to the bottom of the sidebar.
        self.language = QComboBox()
        for code, name in i18n.SUPPORTED_LANGUAGES.items():
            self.language.addItem(f"🌐  {name}", code)
        index = self.language.findData(i18n.get_language())
        if index >= 0:
            self.language.setCurrentIndex(index)
        self.language.currentIndexChanged.connect(self._on_language_changed)
        language_row = QWidget()
        language_layout = QHBoxLayout(language_row)
        language_layout.setContentsMargins(14, 6, 14, 14)
        language_layout.addWidget(self.language)

        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.setContentsMargins(0, 0, 0, 0)
        sidebar_layout.setSpacing(0)
        sidebar_layout.addWidget(brand)
        sidebar_layout.addWidget(self.nav, 1)
        sidebar_layout.addWidget(connection_row)
        sidebar_layout.addWidget(language_row)

        # --- views ------------------------------------------------------- #
        self.stack = QStackedWidget()
        self.dashboard = DashboardView(self.notify_change)
        self.catalog = CatalogView(self.notify_change)
        self.discover = DiscoverView(self.notify_change)
        self.reading = ReadingView(self.notify_change)
        self.wantlist = WantlistView(self.notify_change)
        self.import_view = ImportView(self.notify_change)
        self.locations = LocationsView(self.notify_change)
        self.statuses = StatusesView(self.notify_change)
        self.settings_page = SettingsView(self._open_settings, self._sync_library)
        self._views = [
            self.dashboard,
            self.catalog,
            self.discover,
            self.reading,
            self.wantlist,
            self.import_view,
            self.locations,
            self.statuses,
            self.settings_page,
        ]
        for view in self._views:
            self.stack.addWidget(view)

        central = QWidget()
        layout = QHBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(sidebar)
        layout.addWidget(self.stack, 1)
        self.setCentralWidget(central)

        self.nav.currentRowChanged.connect(self._on_nav_changed)
        self.nav.setCurrentRow(0)

    def _rebuild(self) -> None:
        """Recreate the whole UI after a language or connection change."""
        current = self.stack.currentIndex() if hasattr(self, "stack") else 0
        self._ready = False
        # ``clear()`` removes the actions but does not delete the menus (and
        # their shortcuts), so a few language switches used to pile them up.
        for action in list(self.menuBar().actions()):
            menu = action.menu()
            if menu is not None:
                menu.deleteLater()
            action.deleteLater()
        self.menuBar().clear()
        self._build_menu()
        self._build_ui()
        if current > 0:
            self.nav.setCurrentRow(current)
        self._ready = True
        self.refresh_all()

    # -- connection --------------------------------------------------------- #
    def _connection_label(self) -> str:
        repo = current_repo()
        if isinstance(repo, RemoteRepo):
            if repo.token and not repo.token_rejected:
                account = preferences.get_account_name()
                return f"🌐  {account or repo.description}"
            return "🌐  " + _("Not signed in")
        return "💾  " + _("Local database")

    def _refresh_connection_label(self) -> None:
        if hasattr(self, "connection_btn"):
            self.connection_btn.setText(self._connection_label())

    def _open_settings(self) -> None:
        # Guarded: a failing refresh triggered from inside the dialog must not
        # stack a second copy of it on top.
        if self._settings_open:
            return
        self._settings_open = True
        try:
            dialog = SettingsDialog(self)
            if dialog.exec() != SettingsDialog.DialogCode.Accepted:
                return
            self._apply_settings(dialog.result_data())
        finally:
            self._settings_open = False

    def _apply_settings(self, data: dict) -> None:
        preferences.set_mode(data.get("mode") or preferences.MODE_LOCAL)
        preferences.set_remote_session(
            backend_url=data.get("backend_url") or "",
            token=data.get("token") or "",
            account=data.get("account") or "",
        )
        # Recolour before rebuilding: the new widgets are built (and the old ones
        # torn down) under the theme that was just chosen.
        preferences.set_sync_file(data.get("sync_file") or "")
        preferences.set_sync_on_start(bool(data.get("sync_on_start")))
        color_theme = preferences.set_color_theme(
            data.get("color_theme") or preferences.get_color_theme()
        )
        app = QApplication.instance()
        if isinstance(app, QApplication):
            apply_theme(app, color_theme)
        retired = self._install_repo()
        self._rebuild()
        if retired is not None:
            # Keep the old client alive briefly: a lookup or dashboard fetch
            # started just before the switch may still be finishing.
            QTimer.singleShot(5000, retired.close)
        if preferences.get_mode() == preferences.MODE_REMOTE and not preferences.get_api_token():
            # Still no token: put the user back in the dialog rather than leave
            # them staring at empty views.
            QTimer.singleShot(0, self._open_settings)

    def _install_repo(self) -> RemoteRepo | None:
        """Install the repo for the saved settings, returning any retired one.

        The previous remote client is closed by the caller *after* the widgets
        are rebuilt, so a request already in flight does not hit a closed pool.
        A failure while preparing the new repo leaves the old one in place.
        """
        previous = current_repo()
        if preferences.get_mode() == preferences.MODE_REMOTE:
            new_repo: Repo = RemoteRepo(
                preferences.get_backend_url(), preferences.get_api_token()
            )
        else:
            # Imported lazily so remote mode never opens the local SQLite file.
            from .db import initialize_database

            initialize_database()
            new_repo = LocalRepo()
        set_repo(new_repo)
        return previous if isinstance(previous, RemoteRepo) else None

    def _startup_check(self) -> None:
        repo = current_repo()
        if preferences.get_mode() == preferences.MODE_REMOTE and isinstance(repo, RemoteRepo):
            if not repo.token:
                self._ready = True
                self._open_settings()
                # Signed in? Then show the catalogue. Cancelled? Leave the views
                # empty — the sidebar and status bar explain why.
                self.refresh_all()
                return
            # Verifying reaches the network; keep the window responsive while
            # it runs.
            run_blocking(repo.verify, self._startup_verified, self._startup_failed)
            return
        self._ready = True
        self.refresh_all()

    def _startup_verified(self, _result: object = None) -> None:
        self._ready = True
        self.refresh_all()

    def _startup_failed(self, message: str) -> None:
        repo = current_repo()
        self.statusBar().showMessage(message, 8000)
        if isinstance(repo, RemoteRepo) and repo.token_rejected:
            self._ready = True
            self._open_settings()
        self._ready = True
        self.refresh_all()

    # -- language ----------------------------------------------------------- #
    def _on_language_changed(self, index: int) -> None:
        code = self.language.itemData(index)
        if not code or code == i18n.get_language():
            return
        i18n.set_language(code)
        preferences.set_preferred_language(code)
        # Defer: this combo lives inside the widget we are about to replace, so
        # let the signal handler return before its parent is destroyed.
        QTimer.singleShot(0, self._rebuild)

    # -- behaviour ---------------------------------------------------------- #
    def _on_nav_changed(self, row: int) -> None:
        if row < 0:
            return
        self.stack.setCurrentIndex(row)
        if self._ready:
            self._safe_refresh(self._views[row])

    def notify_change(self) -> None:
        """Called by views after they mutate data.

        Deferred so the originating widget can finish its event handler before
        every view (including itself) is rebuilt.
        """
        QTimer.singleShot(0, self.refresh_all)

    def refresh_all(self) -> None:
        current = self.stack.currentIndex()
        for row, view in enumerate(self._views):
            # Reload the visible view immediately; the rest lazily on navigation.
            if row == current:
                self._safe_refresh(view)

    def _safe_refresh(self, view) -> None:
        """Refresh a view, turning data-source failures into a message.

        We deliberately do *not* pop the settings dialog here: a signed-out
        session would otherwise greet the user with one dialog per view. The
        status bar says what to do, and the sidebar button is one click away.
        """
        try:
            view.refresh()
        except AuthError as exc:
            self.statusBar().showMessage(str(exc), 15000)
            self._refresh_connection_label()
        except RepoError as exc:
            self.statusBar().showMessage(str(exc), 8000)

    # -- shared library ----------------------------------------------------- #
    def _sync_library(self) -> None:
        if self._sync_running:
            return
        if preferences.get_mode() == preferences.MODE_REMOTE:
            QMessageBox.information(
                self,
                _("Shared library"),
                _("The hosted server keeps its own shared folder. Open its admin page to sync it."),
            )
            return
        folder = preferences.get_sync_file()
        if not folder:
            QMessageBox.information(
                self,
                _("Shared library"),
                _("Choose a shared folder in Settings first."),
            )
            self._open_settings()
            return
        self._sync_running = True
        self.sync_action.setEnabled(False)
        self.statusBar().showMessage(_("Syncing with the shared folder…"))
        # Copying and merging whole files takes long enough to notice, so keep
        # it off the GUI thread.
        run_blocking(sync_service.sync_now, self._sync_done, self._sync_failed, target=folder)

    def _sync_done(self, result) -> None:
        self._sync_running = False
        self.sync_action.setEnabled(True)
        self.refresh_all()

        merge = result.merge
        lines: list[str] = []
        if merge is not None and merge.changes:
            lines.append(
                _("Merged %(changes)s change(s) from %(device)s.")
                % {
                    "changes": merge.changes,
                    "device": merge.source_device or _("another device"),
                }
            )
            for bucket, label in (
                (merge.added, _("Added")),
                (merge.updated, _("Updated")),
                (merge.deleted, _("Deleted")),
            ):
                parts = ", ".join(
                    f"{count} {table}" for table, count in sorted(bucket.items())
                )
                if parts:
                    lines.append(f"{label}: {parts}")
        elif merge is not None:
            lines.append(_("The shared file had nothing new."))
        if result.pushed:
            lines.append(_("Published a fresh snapshot."))
        if merge is not None and merge.conflicts:
            lines.append("")
            lines.append(_("Edits made on both devices:"))
            lines.extend(f"• {note}" for note in merge.conflicts[:5])
        if not lines:
            lines.append(_("Already up to date."))

        self.statusBar().showMessage(lines[0], 10000)
        QMessageBox.information(self, _("Shared library"), "\n".join(lines))

    def _sync_failed(self, message: str) -> None:
        self._sync_running = False
        self.sync_action.setEnabled(True)
        self.statusBar().showMessage(message, 15000)
        QMessageBox.warning(self, _("Shared library"), message)

    # -- menu --------------------------------------------------------------- #
    def _build_menu(self) -> None:
        file_menu = self.menuBar().addMenu(_("&File"))
        settings_action = QAction(_("&Settings…"), self)
        settings_action.setShortcut("Ctrl+,")
        settings_action.triggered.connect(self._open_settings)
        file_menu.addAction(settings_action)

        self.sync_action = QAction(_("&Sync library now…"), self)
        self.sync_action.setShortcut("Ctrl+Shift+S")
        self.sync_action.triggered.connect(self._sync_library)
        file_menu.addAction(self.sync_action)
        file_menu.addSeparator()
        quit_action = QAction(_("&Quit"), self)
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

        help_menu = self.menuBar().addMenu(_("&Help"))
        about_action = QAction(_("&About"), self)
        about_action.triggered.connect(self._about)
        help_menu.addAction(about_action)

    def _about(self) -> None:
        if preferences.get_mode() == preferences.MODE_REMOTE:
            where = _(
                "Connected to the hosted library at <b>%s</b>."
                % (preferences.get_backend_url() or _("(no URL set)"))
            )
        else:
            where = _("Using the SQLite database on this computer, shared with the web app.")
        QMessageBox.about(
            self,
            _("About %(app)s") % {"app": settings.app_name},
            _(
                "<b>%(app)s</b><br>%(description)s<br><br>"
                "Desktop edition.<br>%(where)s"
            )
            % {
                "app": settings.app_name,
                "description": _("A catalog for your home library."),
                "where": where,
            },
        )
