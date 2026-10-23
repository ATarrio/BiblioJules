"""Settings: where the catalogue lives, the account behind it, and the theme."""

from __future__ import annotations

from pathlib import Path

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
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
from .repo import RemoteRepo, current_repo, login as repo_login
from .workers import run_blocking


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
        self._closed = False
        self.destroyed.connect(self._mark_closed)
        # A rejected token was cleared when the server answered 401, but the
        # dialog may already be open (or the preference may predate the fix).
        repo = current_repo()
        if getattr(repo, "token_rejected", False):
            self._token = ""
            self._account = ""
            try:
                preferences.set_remote_session(token="", account="")
            except OSError:
                pass
        # The URL the token was issued for. Changing the server without
        # signing in again must not carry the old token over.
        self._signed_in_url = preferences.get_backend_url() if self._token else ""
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

        shared = QGroupBox(_("Shared library"))
        shared_form = QFormLayout(shared)
        self.shared = shared

        self.sync_file = QLineEdit(preferences.get_sync_file())
        self.sync_file.setPlaceholderText("/home/you/Google Drive/BiblioJules")
        browse = QPushButton(_("Browse…"))
        browse.clicked.connect(self._browse_sync_folder)
        folder_row = QHBoxLayout()
        folder_row.setContentsMargins(0, 0, 0, 0)
        folder_row.addWidget(self.sync_file, 1)
        folder_row.addWidget(browse)
        shared_form.addRow(_("Folder"), self._wrap(folder_row))

        self.sync_on_start = QCheckBox(_("Sync when the app starts"))
        self.sync_on_start.setChecked(preferences.get_sync_on_start())
        shared_form.addRow("", self.sync_on_start)

        hint = QLabel(
            _(
                "Every device keeps its own copy of the library. Each sync merges "
                "the snapshot in this folder and writes a fresh one, so Google "
                "Drive (or Syncthing, or a USB stick) never sees a live database."
            )
        )
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        shared_form.addRow("", hint)

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
        layout.addWidget(shared)
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
        # The shared folder belongs to the local library; a remote server has
        # its own copy and its own admin page.
        self.shared.setEnabled(not remote)

    def _render_status(self) -> None:
        if self._token:
            self.status.setText(
                _("Signed in as %s") % (self._account or _("(unknown account)"))
            )
        else:
            self.status.setText(_("Not signed in"))

    # -- actions ------------------------------------------------------------ #
    def _mark_closed(self, *_: object) -> None:
        self._closed = True

    def _browse_sync_folder(self) -> None:
        start = self.sync_file.text().strip() or str(Path.home())
        folder = QFileDialog.getExistingDirectory(self, _("Choose the shared folder"), start)
        if folder:
            self.sync_file.setText(folder)

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
        # The request can take seconds on a slow link; never block the window.
        run_blocking(
            repo_login,
            lambda payload: self._signed_in(payload, url, username),
            self._sign_in_failed,
            url,
            username,
            password,
        )

    def _sign_in_failed(self, message: str) -> None:
        if self._closed:
            return
        self.sign_in_btn.setEnabled(self.mode.currentData() == preferences.MODE_REMOTE)
        self.message.setText(message)

    def _signed_in(self, payload: object, url: str, username: str) -> None:
        if self._closed:
            return
        self.sign_in_btn.setEnabled(self.mode.currentData() == preferences.MODE_REMOTE)
        if not isinstance(payload, dict):
            self.message.setText(_("The server did not return a valid response."))
            return
        token = payload.get("token")
        if not isinstance(token, str) or not token.strip():
            self.message.setText(_("The server did not return a sign-in token."))
            return
        user = payload.get("user") or {}
        self._token = token.strip()
        raw_name = user.get("username") if isinstance(user, dict) else None
        self._account = str(raw_name) if raw_name else username
        self._signed_in_url = url
        self.username.setText(self._account)
        self.password.clear()
        self.message.setText(_("Connected."))
        self._render_status()
        self._sync_enabled()

    def _on_sign_out(self) -> None:
        repo = current_repo()
        if isinstance(repo, RemoteRepo) and repo.token:
            # Revoke server-side as well as forgetting locally. The request is
            # best-effort and must not block the dialog.
            run_blocking(
                repo.logout,
                lambda _result=None: None,
                self._sign_out_failed,
            )
        self._token = ""
        self._account = ""
        self._signed_in_url = ""
        self.password.clear()
        self.message.setText(_("Signed out. The server token was forgotten."))
        self._render_status()
        self._sync_enabled()

    def _sign_out_failed(self, message: str) -> None:
        # The local token is already forgotten; mention that revocation could
        # not be confirmed so the user can revoke it from the server if needed.
        if not self._closed:
            self.message.setText(
                _("Signed out locally, but the server could not be reached: %s")
                % message
            )

    # -- result ------------------------------------------------------------- #
    def done(self, result: int) -> None:
        self._closed = True
        super().done(result)

    def result_data(self) -> dict:
        url = self.url.text().strip()
        token = self._token
        account = self._account
        if token and self._signed_in_url and url != self._signed_in_url:
            # The URL changed after the token was issued; require a fresh
            # sign-in instead of sending the old token to another server.
            token = ""
            account = ""
        return {
            "mode": self.mode.currentData() or preferences.MODE_LOCAL,
            "backend_url": url,
            "token": token,
            "account": account,
            "color_theme": self.color_theme.currentData() or themes.DEFAULT_THEME,
            "sync_file": self.sync_file.text().strip(),
            "sync_on_start": self.sync_on_start.isChecked(),
        }
