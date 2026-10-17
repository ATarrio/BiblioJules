"""Modal dialogs used by the desktop views."""

from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QDate, Qt
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QColorDialog,
    QComboBox,
    QDateEdit,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..services import library
from ..services.isbn_lookup import is_valid_isbn, lookup_isbn, normalize_isbn
from .cover import CoverImage
from .db import session_scope
from .util import (
    display_status,
    fill_combo,
    format_date,
    location_choices,
    status_choices,
    style_badge,
)
from .workers import run_async

UNSET_SPIN = "—"  # shown for value 0 in the optional number fields


def _style_primary(box: QDialogButtonBox, role: QDialogButtonBox.StandardButton) -> None:
    """Mark one button of a dialog button box as the primary (brand) action."""
    button = box.button(role)
    if button is not None:
        button.setProperty("variant", "primary")


# --------------------------------------------------------------------------- #
# Book add / edit
# --------------------------------------------------------------------------- #
class BookDialog(QDialog):
    """Add or edit a single book. Does not touch the DB; the caller saves."""

    def __init__(
        self,
        parent: QWidget | None = None,
        *,
        book_id: int | None = None,
        on_bulk_save: Callable[[dict], str | None] | None = None,
    ) -> None:
        super().__init__(parent)
        self.book_id = book_id
        self.on_bulk_save = on_bulk_save
        self.keep_open: QCheckBox | None = None
        self._source: str | None = None
        self.setWindowTitle("Add book" if book_id is None else "Edit book")
        self.setMinimumWidth(620)
        self._build_ui()
        self._load_choices()
        if book_id is None:
            self._source = "manual"
        else:
            self._load_book()

    # -- construction ------------------------------------------------------- #
    def _build_ui(self) -> None:
        form = QFormLayout()
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)

        self.isbn = QLineEdit()
        self.isbn.setPlaceholderText("Scan or type an ISBN, then press Look up")
        self.lookup_btn = QPushButton("Look up online")
        self.lookup_btn.clicked.connect(self._on_lookup_clicked)
        self.isbn.returnPressed.connect(self._on_lookup_clicked)
        isbn_row = QHBoxLayout()
        isbn_row.addWidget(self.isbn, 1)
        isbn_row.addWidget(self.lookup_btn)
        isbn_widget = QWidget()
        isbn_widget.setLayout(isbn_row)
        form.addRow("ISBN", isbn_widget)

        self.title = QLineEdit()
        self.subtitle = QLineEdit()
        self.authors = QLineEdit()
        self.authors.setPlaceholderText("Comma-separated, e.g. Ursula K. Le Guin")
        self.publisher = QLineEdit()
        self.published_date = QLineEdit()
        self.published_date.setPlaceholderText("free text, e.g. 1968 or 2005-04-01")

        self.year = QSpinBox()
        self.year.setRange(0, 3000)
        self.year.setSpecialValueText(UNSET_SPIN)

        self.pages = QSpinBox()
        self.pages.setRange(0, 200_000)
        self.pages.setSpecialValueText(UNSET_SPIN)

        self.language = QLineEdit()
        self.cover_url = QLineEdit()

        self.location = QComboBox()
        self.status = QComboBox()

        self.description = QPlainTextEdit()
        self.description.setFixedHeight(90)
        self.notes = QPlainTextEdit()
        self.notes.setFixedHeight(60)

        form.addRow("Title", self.title)
        form.addRow("Subtitle", self.subtitle)
        form.addRow("Authors", self.authors)
        form.addRow("Publisher", self.publisher)
        form.addRow("Published date", self.published_date)
        form.addRow("Published year", self.year)
        form.addRow("Page count", self.pages)
        form.addRow("Language", self.language)
        form.addRow("Cover URL", self.cover_url)
        form.addRow("Location", self.location)
        form.addRow("Status", self.status)
        form.addRow("Description", self.description)
        form.addRow("Notes", self.notes)

        self.message = QLabel("")
        self.message.setObjectName("Hint")
        self.message.setWordWrap(True)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        _style_primary(buttons, QDialogButtonBox.StandardButton.Save)
        buttons.accepted.connect(self._on_save)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(self.message)

        if self.book_id is None:
            self.keep_open = QCheckBox("Keep this dialog open so I can add several books in a row")
            self.keep_open.setToolTip(
                "After each save the ISBN details are cleared; the shelf, status and notes stay put."
            )
            layout.addWidget(self.keep_open)

        layout.addWidget(buttons)

    def _load_choices(self) -> None:
        with session_scope() as db:
            locations = location_choices(db)
            statuses = status_choices(db)
            default = library.get_default_status(db)
        fill_combo(self.location, locations, none_label="— none —")
        fill_combo(self.status, statuses, none_label="— default —")
        if self.book_id is None and default is not None:
            index = self.status.findData(default.id)
            if index >= 0:
                self.status.setCurrentIndex(index)

    # -- loading ------------------------------------------------------------ #
    def _load_book(self) -> None:
        with session_scope() as db:
            book = library.get_book(db, self.book_id)
            if book is None:
                QMessageBox.warning(self, "Not found", "This book no longer exists.")
                self.reject()
                return
            self.isbn.setText(book.isbn or "")
            self.title.setText(book.title or "")
            self.subtitle.setText(book.subtitle or "")
            self.authors.setText(", ".join(book.author_names))
            self.publisher.setText(book.publisher.name if book.publisher else "")
            self.published_date.setText(book.published_date or "")
            self.year.setValue(book.published_year or 0)
            self.pages.setValue(book.page_count or 0)
            self.language.setText(book.language or "")
            self.cover_url.setText(book.cover_url or "")
            self.description.setPlainText(book.description or "")
            self.notes.setPlainText(book.notes or "")
            self._source = book.source
            if book.location_id is not None:
                index = self.location.findData(book.location_id)
                if index >= 0:
                    self.location.setCurrentIndex(index)
            if book.status_id is not None:
                index = self.status.findData(book.status_id)
                if index >= 0:
                    self.status.setCurrentIndex(index)

    # -- ISBN lookup -------------------------------------------------------- #
    def _on_lookup_clicked(self) -> None:
        raw = self.isbn.text().strip()
        if not raw:
            self.message.setText("Enter an ISBN first.")
            return
        normalized = normalize_isbn(raw)
        if normalized and not is_valid_isbn(normalized):
            self.message.setText(f"'{normalized}' doesn't look like a valid ISBN; trying anyway…")
        else:
            self.message.setText("Looking up…")
        self.lookup_btn.setEnabled(False)
        run_async(lookup_isbn, self._on_lookup_done, self._on_lookup_error, raw)

    def _on_lookup_done(self, data: dict | None) -> None:
        self.lookup_btn.setEnabled(True)
        if not data:
            self.message.setText("No catalogue entry found for that ISBN.")
            return
        self.message.setText(f"Filled from {data.get('source') or 'online'}.")
        if data.get("isbn"):
            self.isbn.setText(data["isbn"])
        if data.get("title"):
            self.title.setText(data["title"])
        if data.get("subtitle"):
            self.subtitle.setText(data["subtitle"])
        if data.get("authors"):
            self.authors.setText(", ".join(data["authors"]))
        if data.get("publisher"):
            self.publisher.setText(data["publisher"])
        if data.get("published_date"):
            self.published_date.setText(data["published_date"])
        if data.get("published_year"):
            self.year.setValue(int(data["published_year"]))
        if data.get("page_count"):
            self.pages.setValue(int(data["page_count"]))
        if data.get("language"):
            self.language.setText(data["language"])
        if data.get("cover_url"):
            self.cover_url.setText(data["cover_url"])
        if data.get("description") and not self.description.toPlainText().strip():
            self.description.setPlainText(data["description"])
        if data.get("source"):
            self._source = data["source"]

    def _on_lookup_error(self, message: str) -> None:
        self.lookup_btn.setEnabled(True)
        self.message.setText(f"Lookup failed: {message}")

    # -- result ------------------------------------------------------------- #
    def _set_message(self, text: str, *, ok: bool = False) -> None:
        self.message.setObjectName("Muted" if ok else "Hint")
        self.message.setText(text)
        style = self.message.style()
        style.unpolish(self.message)
        style.polish(self.message)

    def _clear_for_next(self) -> None:
        """Clear everything an ISBN lookup fills in, keeping the shelf/status/notes."""
        for widget in (
            self.isbn,
            self.title,
            self.subtitle,
            self.authors,
            self.publisher,
            self.published_date,
            self.year,
            self.pages,
            self.language,
            self.cover_url,
            self.description,
        ):
            if isinstance(widget, (QLineEdit, QPlainTextEdit)):
                widget.clear()
            else:  # QSpinBox
                widget.setValue(0)
        self._source = "manual"
        self._set_message("Added. Scan or type the next ISBN.", ok=True)
        self.isbn.setFocus()

    def _on_save(self) -> None:
        if not self.title.text().strip():
            self.message.setText("A title is required (it will be saved as 'Untitled' if blank).")
        if (
            self.book_id is None
            and self.keep_open is not None
            and self.keep_open.isChecked()
            and self.on_bulk_save is not None
        ):
            error = self.on_bulk_save(self.data())
            if error:
                self._set_message(f"Could not save: {error}")
                return
            self._clear_for_next()
            return
        self.accept()

    def data(self) -> dict:
        payload = {
            "isbn": self.isbn.text().strip(),
            "title": self.title.text().strip(),
            "subtitle": self.subtitle.text().strip(),
            "authors": self.authors.text().strip(),
            "publisher": self.publisher.text().strip(),
            "published_date": self.published_date.text().strip(),
            "published_year": self.year.value() or None,
            "page_count": self.pages.value() or None,
            "language": self.language.text().strip(),
            "cover_url": self.cover_url.text().strip(),
            "description": self.description.toPlainText().strip(),
            "notes": self.notes.toPlainText().strip(),
            "location_id": self.location.currentData(),
            "status_id": self.status.currentData(),
        }
        if self._source:
            payload["source"] = self._source
        return payload


# --------------------------------------------------------------------------- #
# Book details
# --------------------------------------------------------------------------- #
class BookDetailsDialog(QDialog):
    """Read-only overview of a book: cover, metadata, loans and an Edit action."""

    def __init__(
        self,
        parent: QWidget | None = None,
        *,
        book_id: int,
        on_change: Callable[[], None] | None = None,
    ) -> None:
        super().__init__(parent)
        self.book_id = book_id
        self.on_change = on_change
        self.setWindowTitle("Book details")
        self.setMinimumWidth(640)
        self._build_ui()
        self._load()

    def _build_ui(self) -> None:
        # --- header: cover on the left, title block on the right ---------- #
        self.cover = CoverImage(170)

        self.status_badge = QLabel()
        self.status_badge.setVisible(False)

        self.title_label = QLabel("")
        self.title_label.setObjectName("DetailTitle")
        self.title_label.setWordWrap(True)

        self.subtitle_label = QLabel("")
        self.subtitle_label.setObjectName("Muted")
        self.subtitle_label.setWordWrap(True)

        self.authors_label = QLabel("")
        self.authors_label.setObjectName("DetailAuthors")
        self.authors_label.setWordWrap(True)

        badge_row = QHBoxLayout()
        badge_row.setContentsMargins(0, 0, 0, 0)
        badge_row.addWidget(self.status_badge, 0, Qt.AlignmentFlag.AlignLeft)
        badge_row.addStretch(1)

        header_col = QVBoxLayout()
        header_col.setSpacing(6)
        header_col.addLayout(badge_row)
        header_col.addWidget(self.title_label)
        header_col.addWidget(self.subtitle_label)
        header_col.addWidget(self.authors_label)

        top = QHBoxLayout()
        top.setSpacing(18)
        top.addWidget(self.cover, 0, Qt.AlignmentFlag.AlignTop)
        top.addLayout(header_col, 1)

        # --- metadata ----------------------------------------------------- #
        self.fields: dict[str, QLabel] = {}
        meta = QFormLayout()
        meta.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        for key, label in (
            ("publisher", "Publisher"),
            ("published", "Published"),
            ("isbn", "ISBN"),
            ("location", "Location"),
            ("loan", "Current loan"),
        ):
            value = QLabel("")
            value.setWordWrap(True)
            value.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            self.fields[key] = value
            meta.addRow(label, value)

        # --- description & notes ------------------------------------------ #
        self.description_label = QLabel("Description")
        self.description_label.setObjectName("SectionTitle")
        self.description = QLabel("")
        self.description.setWordWrap(True)
        self.description.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)

        self.notes_label = QLabel("Notes")
        self.notes_label.setObjectName("SectionTitle")
        self.notes = QLabel("")
        self.notes.setWordWrap(True)
        self.notes.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)

        # --- loan history -------------------------------------------------- #
        self.loans_label = QLabel("Loan history")
        self.loans_label.setObjectName("SectionTitle")
        self.loans = QTableWidget(0, 4)
        self.loans.setHorizontalHeaderLabels(["Borrower", "Lent", "Due", "Returned"])
        self.loans.verticalHeader().setVisible(False)
        self.loans.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.loans.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.loans.setAlternatingRowColors(True)
        self.loans.setShowGrid(False)
        self.loans.horizontalHeader().setStretchLastSection(True)
        self.loans.setMinimumHeight(140)

        # --- buttons ------------------------------------------------------- #
        edit_btn = QPushButton("Edit details")
        edit_btn.setProperty("variant", "primary")
        edit_btn.clicked.connect(self._edit)
        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.reject)

        buttons = QHBoxLayout()
        buttons.addStretch(1)
        buttons.addWidget(close_btn)
        buttons.addWidget(edit_btn)

        header_col.setSpacing(10)
        header_col.addLayout(meta)
        header_col.addWidget(self.description_label)
        header_col.addWidget(self.description)
        header_col.addWidget(self.notes_label)
        header_col.addWidget(self.notes)
        header_col.addWidget(self.loans_label)
        header_col.addWidget(self.loans)
        header_col.addStretch(1)

        layout = QVBoxLayout(self)
        layout.setSpacing(14)
        layout.addLayout(top, 1)
        layout.addLayout(buttons)

    def _load(self) -> None:
        with session_scope() as db:
            book = library.get_book(db, self.book_id)
            if book is None:
                QMessageBox.warning(self, "Not found", "This book no longer exists.")
                self.reject()
                return

            self.cover.load(book.cover_url, book.title or "")
            self.title_label.setText(book.title or "Untitled")
            self.subtitle_label.setText(book.subtitle or "")
            self.subtitle_label.setVisible(bool(book.subtitle))
            self.authors_label.setText(book.author_display or "")

            if book.status is not None:
                style_badge(
                    self.status_badge,
                    display_status(book.status),
                    book.status.color or "#64748b",
                )
                self.status_badge.setVisible(True)
            else:
                self.status_badge.setVisible(False)

            self.fields["publisher"].setText(book.publisher.name if book.publisher else "—")
            published = " ".join(
                p for p in (book.published_date, str(book.published_year or "")) if p
            )
            if book.page_count:
                published = (
                    f"{published} · {book.page_count} pp."
                    if published
                    else f"{book.page_count} pp."
                )
            self.fields["published"].setText(published or "—")
            self.fields["isbn"].setText(book.isbn or "—")
            self.fields["location"].setText(book.location.full_path if book.location else "—")

            loan = book.active_loan
            if loan:
                due = f" due {format_date(loan.due_at)}" if loan.due_at else ""
                overdue = " · OVERDUE" if loan.is_overdue else ""
                self.fields["loan"].setText(
                    f"{loan.borrower_name} since {format_date(loan.lent_at)}{due}{overdue}"
                )
            else:
                self.fields["loan"].setText("Not on loan")

            self.description.setText(book.description or "")
            self.description.setVisible(bool(book.description))
            self.description_label.setVisible(bool(book.description))
            self.notes.setText(book.notes or "")
            self.notes.setVisible(bool(book.notes))
            self.notes_label.setVisible(bool(book.notes))

            self.loans.setRowCount(len(book.loans))
            for row, loan in enumerate(book.loans):
                for col, text in enumerate(
                    (
                        loan.borrower_name,
                        format_date(loan.lent_at),
                        format_date(loan.due_at),
                        format_date(loan.returned_at) or "on loan",
                    )
                ):
                    self.loans.setItem(row, col, QTableWidgetItem(text))
            self.loans.resizeColumnsToContents()
            self.loans_label.setVisible(bool(book.loans))
            self.loans.setVisible(bool(book.loans))

    def _edit(self) -> None:
        dialog = BookDialog(self, book_id=self.book_id)
        if dialog.exec() != BookDialog.DialogCode.Accepted:
            return
        try:
            with session_scope() as db:
                book = library.get_book(db, self.book_id)
                if book is None:
                    raise ValueError("This book no longer exists.")
                library.update_book(db, book, dialog.data())
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Could not save", str(exc))
            return
        self._load()
        if self.on_change is not None:
            self.on_change()


# --------------------------------------------------------------------------- #
# Lending
# --------------------------------------------------------------------------- #
class LendDialog(QDialog):
    def __init__(self, parent: QWidget | None = None, *, book_title: str = "") -> None:
        super().__init__(parent)
        self.setWindowTitle("Lend book")
        self.setMinimumWidth(420)
        form = QFormLayout()

        self.borrower = QLineEdit()
        self.borrower.setPlaceholderText("Required")
        self.contact = QLineEdit()

        self.lent_at = QDateEdit(QDate.currentDate())
        self.lent_at.setCalendarPopup(True)

        self.has_due = QCheckBox("Set a due date")
        self.due_at = QDateEdit(QDate.currentDate().addDays(30))
        self.due_at.setCalendarPopup(True)
        self.due_at.setEnabled(False)
        self.has_due.toggled.connect(self.due_at.setEnabled)
        due_row = QHBoxLayout()
        due_row.addWidget(self.due_at, 1)

        self.mark_status = QCheckBox("Mark the book as 'Lent out'")
        self.mark_status.setChecked(True)

        self.notes = QPlainTextEdit()
        self.notes.setFixedHeight(60)

        form.addRow("Book", QLabel(book_title or "—"))
        form.addRow("Borrower", self.borrower)
        form.addRow("Contact", self.contact)
        form.addRow("Lent on", self.lent_at)
        form.addRow(self.has_due, self.due_at)
        form.addRow("", self.mark_status)
        form.addRow("Notes", self.notes)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        _style_primary(buttons, QDialogButtonBox.StandardButton.Ok)
        buttons.accepted.connect(self._on_ok)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(buttons)

    def _on_ok(self) -> None:
        if not self.borrower.text().strip():
            QMessageBox.warning(self, "Borrower required", "Please enter the borrower's name.")
            return
        self.accept()

    def data(self) -> dict:
        return {
            "borrower_name": self.borrower.text().strip(),
            "borrower_contact": self.contact.text().strip(),
            "lent_at": self.lent_at.date().toPython(),
            "due_at": self.due_at.date().toPython() if self.has_due.isChecked() else None,
            "notes": self.notes.toPlainText().strip(),
            "mark_status": self.mark_status.isChecked(),
        }


# --------------------------------------------------------------------------- #
# Locations
# --------------------------------------------------------------------------- #
class LocationDialog(QDialog):
    def __init__(
        self,
        parent: QWidget | None = None,
        *,
        location_id: int | None = None,
        preselect_parent: int | None = None,
    ) -> None:
        super().__init__(parent)
        self.location_id = location_id
        self.setWindowTitle("Add location" if location_id is None else "Edit location")
        self.setMinimumWidth(420)
        self._build_ui(preselect_parent)
        if location_id is not None:
            self._load()

    def _build_ui(self, preselect_parent: int | None) -> None:
        form = QFormLayout()
        self.name = QLineEdit()
        self.parent = QComboBox()
        self.kind = QLineEdit()
        self.kind.setPlaceholderText("room, bookcase, shelf, box…")
        self.description = QPlainTextEdit()
        self.description.setFixedHeight(70)
        form.addRow("Name", self.name)
        form.addRow("Parent", self.parent)
        form.addRow("Kind", self.kind)
        form.addRow("Description", self.description)

        with session_scope() as db:
            choices = location_choices(db)
        fill_combo(self.parent, choices, none_label="— top level —", current=preselect_parent)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        _style_primary(buttons, QDialogButtonBox.StandardButton.Ok)
        buttons.accepted.connect(self._on_ok)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(buttons)

    def _load(self) -> None:
        from ..models import Location

        with session_scope() as db:
            location = db.get(Location, self.location_id)
            if location is None:
                QMessageBox.warning(self, "Not found", "This location no longer exists.")
                self.reject()
                return
            self.name.setText(location.name or "")
            self.kind.setText(location.kind or "")
            self.description.setPlainText(location.description or "")
            index = self.parent.findData(location.parent_id)
            if index >= 0:
                self.parent.setCurrentIndex(index)

    def _on_ok(self) -> None:
        if not self.name.text().strip():
            QMessageBox.warning(self, "Name required", "Please enter a location name.")
            return
        self.accept()

    def data(self) -> dict:
        return {
            "name": self.name.text().strip(),
            "parent_id": self.parent.currentData(),
            "kind": self.kind.text().strip(),
            "description": self.description.toPlainText().strip(),
        }


# --------------------------------------------------------------------------- #
# Statuses
# --------------------------------------------------------------------------- #
class StatusDialog(QDialog):
    def __init__(self, parent: QWidget | None = None, *, status_id: int | None = None) -> None:
        super().__init__(parent)
        self.status_id = status_id
        self._color = "#64748b"
        self.setWindowTitle("Add status" if status_id is None else "Edit status")
        self.setMinimumWidth(420)
        self._build_ui()
        if status_id is not None:
            self._load()

    def _build_ui(self) -> None:
        form = QFormLayout()
        self.name = QLineEdit()
        self.icon = QLineEdit()
        self.icon.setPlaceholderText("optional emoji, e.g. 📚")
        self.description = QPlainTextEdit()
        self.description.setFixedHeight(70)

        self.color_btn = QPushButton()
        self.color_btn.clicked.connect(self._pick_color)
        self._render_color()

        form.addRow("Name", self.name)
        form.addRow("Colour", self.color_btn)
        form.addRow("Icon", self.icon)
        form.addRow("Description", self.description)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        _style_primary(buttons, QDialogButtonBox.StandardButton.Ok)
        buttons.accepted.connect(self._on_ok)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(buttons)

    def _render_color(self) -> None:
        self.color_btn.setText(self._color)
        self.color_btn.setStyleSheet(
            f"background-color: {self._color}; color: white; padding: 4px; border-radius: 4px;"
        )

    def _pick_color(self) -> None:
        color = QColorDialog.getColor(QColor(self._color), self, "Pick a colour")
        if color.isValid():
            self._color = color.name()
            self._render_color()

    def _load(self) -> None:
        from ..models import Status

        with session_scope() as db:
            status = db.get(Status, self.status_id)
            if status is None:
                QMessageBox.warning(self, "Not found", "This status no longer exists.")
                self.reject()
                return
            self.name.setText(status.name or "")
            self.icon.setText(status.icon or "")
            self.description.setPlainText(status.description or "")
            if status.color:
                self._color = status.color
                self._render_color()

    def _on_ok(self) -> None:
        if not self.name.text().strip():
            QMessageBox.warning(self, "Name required", "Please enter a status name.")
            return
        self.accept()

    def data(self) -> dict:
        return {
            "name": self.name.text().strip(),
            "color": self._color,
            "icon": self.icon.text().strip(),
            "description": self.description.toPlainText().strip(),
        }
