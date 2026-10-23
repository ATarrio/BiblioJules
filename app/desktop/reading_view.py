"""Reading stats: personal totals and the reading goals kept on this device."""

from __future__ import annotations

from datetime import date

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

from ..i18n import _
from .repo import RemoteRepo, get_repo
from .theme import AMBER, EMERALD, VIOLET, accent
from .util import card, page_header, section_title
from .workers import run_blocking


def _stat_card(icon: str, label: str, color: str) -> tuple[QFrame, QLabel]:
    frame = card()
    value = QLabel("—")
    value.setObjectName("StatValue")
    value.setStyleSheet(f"color: {color};")
    caption = QLabel(label)
    caption.setObjectName("StatLabel")
    caption.setWordWrap(True)
    icon_label = QLabel(icon)
    icon_label.setObjectName("StatIcon")

    text_col = QVBoxLayout()
    text_col.setSpacing(0)
    text_col.addWidget(value)
    text_col.addWidget(caption)

    row = QHBoxLayout(frame)
    row.setContentsMargins(18, 16, 18, 16)
    row.addLayout(text_col)
    row.addStretch(1)
    row.addWidget(icon_label)
    return frame, value


class ReadingView(QWidget):
    def __init__(self, on_change=None, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._values: dict[str, QLabel] = {}
        self._pstats: dict = {}
        self._loading = False
        self._deleted = False
        self.destroyed.connect(self._mark_deleted)
        self._build_ui()

    def _mark_deleted(self, *_: object) -> None:
        self._deleted = True

    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        content = QWidget()
        content.setObjectName("PageContent")
        scroll.setWidget(content)
        outer.addWidget(scroll)

        layout = QVBoxLayout(content)
        layout.setContentsMargins(28, 24, 28, 24)
        layout.setSpacing(20)
        layout.addWidget(
            page_header(
                _("Reading stats"),
                _("Personal reading insights, stored on this device only."),
            )
        )

        self.message = QLabel("")
        self.message.setObjectName("Hint")
        self.message.setWordWrap(True)
        self.message.setVisible(False)
        layout.addWidget(self.message)

        stats_card = card()
        stats_layout = QVBoxLayout(stats_card)
        stats_layout.setContentsMargins(18, 16, 18, 16)
        stats_layout.setSpacing(14)
        stats_layout.addWidget(section_title(_("Your reading stats")))

        grid = QGridLayout()
        grid.setSpacing(12)
        specs = [
            ("books_read", _("Books read"), "📚", accent()),
            ("pages_read", _("Pages read"), "📄", EMERALD),
            ("avg_rating", _("Average rating"), "⭐", AMBER),
            ("currently_reading", _("Currently reading"), "📖", accent()),
            ("dnf", _("DNF"), "🚫", VIOLET),
            ("lost_donated", _("Lost / donated"), "🕳️", AMBER),
        ]
        for index, (key, label, icon, color) in enumerate(specs):
            frame, value = _stat_card(icon, label, color)
            self._values[key] = value
            grid.addWidget(frame, index // 3, index % 3)
        stats_layout.addLayout(grid)

        hint = QLabel(
            _(
                "These numbers are computed from your shared library but stored "
                "locally — they do not travel across sync merges."
            )
        )
        hint.setObjectName("Hint")
        hint.setWordWrap(True)
        stats_layout.addWidget(hint)
        layout.addWidget(stats_card)

        goals_card = card()
        goals_layout = QHBoxLayout(goals_card)
        goals_layout.setContentsMargins(18, 16, 18, 16)
        goals_layout.setSpacing(24)

        form_col = QVBoxLayout()
        form_col.setSpacing(10)
        form_col.addWidget(section_title(_("Reading goals")))

        self.year = QComboBox()
        self.year.setMinimumWidth(150)
        self.target_books = QSpinBox()
        self.target_books.setRange(0, 100000)
        self.target_books.setSpecialValueText(_("Not set"))
        self.target_pages = QSpinBox()
        self.target_pages.setRange(0, 10_000_000)
        self.target_pages.setSpecialValueText(_("Not set"))

        for label, widget in (
            (_("Year"), self.year),
            (_("Target books"), self.target_books),
            (_("Target pages"), self.target_pages),
        ):
            caption = QLabel(label)
            caption.setObjectName("Muted")
            form_col.addWidget(caption)
            form_col.addWidget(widget)

        self.save_btn = QPushButton(_("Save goals"))
        self.save_btn.setProperty("variant", "primary")
        self.save_btn.clicked.connect(self._save)
        form_col.addWidget(self.save_btn)
        form_col.addStretch(1)
        goals_layout.addLayout(form_col, 1)

        progress_col = QVBoxLayout()
        progress_col.setSpacing(10)
        progress_col.addWidget(section_title(_("Progress")))
        self.books_bar = QProgressBar()
        self.pages_bar = QProgressBar()
        for bar in (self.books_bar, self.pages_bar):
            bar.setRange(0, 100)
            bar.setValue(0)
            bar.setTextVisible(True)
        progress_col.addWidget(QLabel(_("Books")))
        progress_col.addWidget(self.books_bar)
        progress_col.addWidget(QLabel(_("Pages")))
        progress_col.addWidget(self.pages_bar)
        progress_col.addStretch(1)
        goals_layout.addLayout(progress_col, 1)

        layout.addWidget(goals_card)
        layout.addStretch(1)

    # -- data --------------------------------------------------------------- #
    @staticmethod
    def _fetch() -> tuple[dict, dict]:
        repo = get_repo()
        return repo.personal_stats(), repo.goals()

    def refresh(self) -> None:
        if self._loading:
            return
        if isinstance(get_repo(), RemoteRepo):
            self._loading = True
            run_blocking(self._fetch, self._apply, self._load_failed)
            return
        self._apply(self._fetch())

    def _load_failed(self, message: str) -> None:
        self._loading = False
        if self._deleted:
            return
        self.message.setText(_("Could not load reading stats: %s") % message)
        self.message.setVisible(True)

    def _apply(self, data: tuple[dict, dict]) -> None:
        self._loading = False
        if self._deleted:
            return
        pstats, goals = data
        self._pstats = pstats or {}
        breakdown = self._pstats.get("status_breakdown") or {}
        lost_donated = int(breakdown.get("lost", 0) or 0) + int(
            breakdown.get("donated", 0) or 0
        )
        avg = self._pstats.get("avg_rating")
        values = {
            "books_read": self._pstats.get("books_read", 0),
            "pages_read": self._pstats.get("pages_read", 0),
            "avg_rating": "—" if avg is None else str(avg),
            "currently_reading": self._pstats.get("currently_reading", 0),
            "dnf": breakdown.get("dnf", 0),
            "lost_donated": lost_donated,
        }
        for key, value in values.items():
            label = self._values.get(key)
            if label is not None:
                label.setText(str(value))

        goal_year = goals.get("year") if goals else None
        self._fill_years(goal_year)
        self.target_books.setValue(int((goals or {}).get("target_books", 0) or 0))
        self.target_pages.setValue(int((goals or {}).get("target_pages", 0) or 0))
        self._update_progress(goals or {})
        self.message.setVisible(False)

    def _fill_years(self, selected: int | None) -> None:
        self.year.blockSignals(True)
        self.year.clear()
        self.year.addItem(_("Any year"), None)
        this_year = date.today().year
        for year in range(this_year - 2, this_year + 2):
            self.year.addItem(str(year), year)
        if selected and self.year.findData(selected) < 0:
            self.year.addItem(str(selected), selected)
        index = self.year.findData(selected)
        self.year.setCurrentIndex(max(0, index))
        self.year.blockSignals(False)

    def _update_progress(self, goals: dict) -> None:
        books_done = int(self._pstats.get("books_read", 0) or 0)
        pages_done = int(self._pstats.get("pages_read", 0) or 0)
        book_target = int(goals.get("target_books", 0) or 0)
        page_target = int(goals.get("target_pages", 0) or 0)
        for bar, done, target in (
            (self.books_bar, books_done, book_target),
            (self.pages_bar, pages_done, page_target),
        ):
            bar.setValue(
                min(100, round(done / target * 100)) if target else 0
            )
            bar.setFormat(f"{done}/{target}" if target else str(done))

    # -- actions ------------------------------------------------------------ #
    def _save(self) -> None:
        goals = {
            "year": self.year.currentData(),
            "target_books": self.target_books.value(),
            "target_pages": self.target_pages.value(),
            "progress": {
                "books_read": int(self._pstats.get("books_read", 0) or 0),
                "pages_read": int(self._pstats.get("pages_read", 0) or 0),
            },
        }
        self.save_btn.setEnabled(False)
        self.message.setText(_("Saving…"))
        self.message.setVisible(True)
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                lambda: get_repo().save_goals(goals),
                lambda _result: self._saved(goals),
                self._save_failed,
            )
            return
        try:
            get_repo().save_goals(goals)
        except Exception as exc:  # noqa: BLE001
            self._save_failed(str(exc))

            return
        self._saved(goals)

    def _saved(self, goals: dict) -> None:
        self.save_btn.setEnabled(True)
        if self._deleted:
            return
        self._update_progress(goals)
        self.message.setText(_("Goals saved."))
        self.message.setVisible(True)

    def _save_failed(self, message: str) -> None:
        self.save_btn.setEnabled(True)
        if self._deleted:
            return
        self.message.setText(_("Could not save the goals: %s") % message)
        self.message.setVisible(True)
