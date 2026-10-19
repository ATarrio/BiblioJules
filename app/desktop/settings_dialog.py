"""Settings: where the catalogue lives, the account behind it, and the theme."""

from __future__ import annotations

from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from .. import preferences, themes
from ..i18n import _
from .repo import RepoError, login as repo_login


class SettingsDialog(QDialog):
    """Pick where the catalogue lives, sign in when it is a remote server, and
    choose the accent colour.

    The dialog performs the sign-in itself (it is the only place that holds a
    not-yet-saved backend URL). The caller reads :meth:`result_data` and applies
    it, so cancelling leaves the current configuration untouched.
    """

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(_("Settings"))
        self.setMinimumWidth(540)
        self._token = preferences.get_api_token()
        self._account = preferences.get_account_name()
        self._build_ui()

    # -- construction ------------------------------------------------------- #
    def _build_ui(self) -> None:
        source = QGroupBox(_("Where is your library?"))
        source_form = QFormLayout(source)

        self.mode = QComboBox()
        self.mode.addItem(_("Local database — on this computer"), preferences.MODE_LOCAL)
        self.mode.addItem(_("Remote server — a hosted library"), preferences.MODE_REMOTE)
        index = self.mode.findData(preferences.get_mode())
        if index >= 0:
            self.mode.setCurrentIndex(index)
        source_form.addRow(_("Source"), self.mode)

        self.url = QLineEdit(preferences.get_backend_url())
        self.url.setPlaceholderText("https://library.example.com")
        source_form.addRow(_("Backend URL"), self.url)

        account = QGroupBox(_("Account"))
        account_form = QFormLayout(account)

        self.username = QLineEdit(self._account)
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.EchoMode.Password)
        self.password.returnPressed.connect(self._on_sign_in)

        self.sign_in_btn = QPushButton(_("Sign in"))
        self.sign_in_btn.setProperty("variant", "primary")
        self.sign_in_btn.clicked.connect(self._on_sign_in)
        self.sign_out_btn = QPushButton(_("Sign out"))
        self.sign_out_btn.clicked.connect(self._on_sign_out)

        credentials = QHBoxLayout()
        credentials.setContentsMargins(0, 0, 0, 0)
        account_form.addRow(_("Username"), self.username)
        account_form.addRow(_("Password"), self.password)

        self.status = QLabel("")
        self.status.setObjectName("Muted")
        self.status.setWordWrap(True)

        buttons_row = QHBoxLayout()
        buttons_row.addWidget(self.status, 1)
        buttons_row.addWidget(self.sign_out_btn)
        buttons_row.addWidget(self.sign_in_btn)
        account_form.addRow("", self._wrap(buttons_row))

        # The accent the whole UI is drawn in. Applied on Save like everything
        # else, so cancelling really does change nothing.
        appearance = QGroupBox(_("Appearance"))
        appearance_form = QFormLayout(appearance)

        self.color_theme = QComboBox()
        for option in themes.THEMES:
            self.color_theme.addItem(_(option.label), option.slug)
        index = self.color_theme.findData(preferences.get_color_theme())
        if index >= 0:
            self.color_theme.setCurrentIndex(index)
        appearance_form.addRow(_("Theme"), self.color_theme)

        self.message = QLabel("")
        self.message.setObjectName("Hint")
        self.message.setWordWrap(True)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        ok = buttons.button(QDialogButtonBox.StandardButton.Save)
        if ok is not None:
            ok.setProperty("variant", "primary")

        layout = QVBoxLayout(self)
        layout.setSpacing(12)
        layout.addWidget(source)
        layout.addWidget(account)
        layout.addWidget(appearance)
        layout.addWidget(self.message)
        layout.addWidget(buttons)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        self.mode.currentIndexChanged.connect(self._sync_enabled)
        self._sync_enabled()
        self._render_status()

    @staticmethod
    def _wrap(layout) -> QWidget:
        holder = QWidget()
        holder.setLayout(layout)
        return holder

    # -- state -------------------------------------------------------------- #
    def _sync_enabled(self) -> None:
        remote = self.mode.currentData() == preferences.MODE_REMOTE
        for widget in (self.url, self.username, self.password, self.sign_in_btn):
            widget.setEnabled(remote)
        self.sign_out_btn.setEnabled(remote and bool(self._token))

    def _render_status(self) -> None:
        if self._token:
            self.status.setText(
                _("Signed in as %s") % (self._account or _("(unknown account)"))
            )
        else:
            self.status.setText(_("Not signed in"))

    # -- actions ------------------------------------------------------------ #
    def _on_sign_in(self) -> None:
        url = self.url.text().strip()
        username = self.username.text().strip()
        password = self.password.text()
        if not url or not username or not password:
            self.message.setText(
                _("Enter the backend URL, your username and your password first.")
            )
            return
        self.message.setText(_("Signing in…"))
        self.sign_in_btn.setEnabled(False)
        QApplication.processEvents()  # let the "Signing in…" message paint
        try:
            payload = repo_login(url, username, password)
        except RepoError as exc:
            self.message.setText(str(exc))
            return
        finally:
            self.sign_in_btn.setEnabled(self.mode.currentData() == preferences.MODE_REMOTE)

        user = payload.get("user") or {}
        self._token = payload.get("token") or ""
        self._account = user.get("username") or username
        self.username.setText(self._account)
        self.password.clear()
        self.message.setText(_("Connected."))
        self._render_status()
        self._sync_enabled()

    def _on_sign_out(self) -> None:
        self._token = ""
        self._account = ""
        self.password.clear()
        self.message.setText(_("Signed out. The server token was forgotten."))
        self._render_status()
        self._sync_enabled()

    # -- result ------------------------------------------------------------- #
    def result_data(self) -> dict:
        return {
            "mode": self.mode.currentData() or preferences.MODE_LOCAL,
            "backend_url": self.url.text().strip(),
            "token": self._token,
            "account": self._account,
            "color_theme": self.color_theme.currentData() or themes.DEFAULT_THEME,
        }
