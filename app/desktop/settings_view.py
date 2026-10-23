"""Settings shortcuts: the same dialog as the menu, plus a quick sync action."""

from __future__ import annotations

from typing import Callable

from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from .. import preferences
from ..i18n import _
from .repo import RemoteRepo, current_repo
from .util import card, page_header, section_title


class SettingsView(QWidget):
    def __init__(
        self,
        on_open_settings: Callable[[], None],
        on_sync: Callable[[], None],
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self._on_open_settings = on_open_settings
        self._on_sync = on_sync
        self._mode = QLabel("")
        self._account = QLabel("")
        self._build_ui()

    def _build_ui(self) -> None:
        settings_card = card()
        settings_layout = QVBoxLayout(settings_card)
        settings_layout.setContentsMargins(18, 16, 18, 16)
        settings_layout.setSpacing(10)
        settings_layout.addWidget(section_title(_("Library source")))
        settings_layout.addWidget(self._mode)
        settings_layout.addWidget(self._account)

        hint = QLabel(
            _(
                "Change the library location, sign in, choose a shared folder, "
                "or pick the app language and accent colour."
            )
        )
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        settings_layout.addWidget(hint)

        open_btn = QPushButton(_("Open settings…"))
        open_btn.setProperty("variant", "primary")
        open_btn.clicked.connect(self._on_open_settings)
        sync_btn = QPushButton(_("Sync library now…"))
        sync_btn.clicked.connect(self._on_sync)
        buttons = QHBoxLayout()
        buttons.setSpacing(8)
        buttons.addWidget(open_btn)
        buttons.addWidget(sync_btn)
        buttons.addStretch(1)
        settings_layout.addLayout(buttons)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(16)
        layout.addWidget(
            page_header(
                _("Settings"),
                _("Where your library lives, the account behind it, and your preferences."),
            )
        )
        layout.addWidget(settings_card)
        layout.addStretch(1)

    def refresh(self) -> None:
        repo = current_repo()
        if isinstance(repo, RemoteRepo):
            self._mode.setText(
                _("Library source: remote server at %s") % (repo.description or "—")
            )
            account = preferences.get_account_name()
            self._account.setText(
                _("Signed in as %s") % account
                if account
                else _("Not signed in")
            )
        else:
            self._mode.setText(_("Library source: local database on this computer"))
            self._account.setText(_("No account needed in local mode."))
