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


def _clear(layout) -> None:
    while layout.count():
        item = layout.takeAt(0)
        widget = item.widget()
        if widget is not None:
            widget.setParent(None)
            widget.deleteLater()


def _goal_card(goal: dict, on_remove=None) -> QFrame:
    """One saved objective: its year plus Books/Pages progress bars."""
    frame = card()
    col = QVBoxLayout(frame)
    col.setContentsMargins(18, 16, 18, 16)
    col.setSpacing(10)

    year = goal.get("year")
    header_row = QHBoxLayout()
    heading = QLabel(str(year) if year else _("Any year"))
    heading.setObjectName("SectionTitle")
    header_row.addWidget(heading)
    header_row.addStretch(1)
    if on_remove is not None:
        btn = QPushButton("🗑️")
        btn.setProperty("variant", "muted")
        btn.clicked.connect(on_remove)
        header_row.addWidget(btn)
    col.addLayout(header_row)

    books_done = int(goal.get("books_done", 0) or 0)
    pages_done = int(goal.get("pages_done", 0) or 0)
    for label, target_key, done in (
        (_("Books"), "target_books", books_done),
        (_("Pages"), "target_pages", pages_done),
    ):
        target = int(goal.get(target_key, 0) or 0)
        if not target:
            continue
        bar = QProgressBar()
        bar.setRange(0, 100)
        bar.setValue(min(100, round(done / target * 100)))
        bar.setTextVisible(True)
        bar.setFormat(f"{done}/{target}")
        col.addWidget(QLabel(label))
        col.addWidget(bar)
    return frame


class ReadingView(QWidget):
    def __init__(self, on_change=None, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.on_change = on_change
        self._values: dict[str, QLabel] = {}
        self._pstats: dict = {}
        self._goals: list[dict] = []
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

        self.goals_host = QVBoxLayout()
        self.goals_host.setSpacing(14)
        goals_layout.addLayout(self.goals_host, 1)

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

        self._goals = list(goals) if isinstance(goals, list) else []
        self._fill_years(self._goals)
        self._render_goals(self._goals)
        self.message.setVisible(False)

    def _fill_years(self, goals: list[dict]) -> None:
        self.year.blockSignals(True)
        self.year.clear()
        self.year.addItem(_("Any year"), None)
        this_year = date.today().year
        # Only offer the current year and future years.
        years = {
            g.get("year")
            for g in goals
            if g.get("year") is not None and int(g.get("year")) >= this_year
        }
        years.update(range(this_year, this_year + 3))
        for year in sorted(years):
            self.year.addItem(str(year), year)
        self.year.setCurrentIndex(0)
        self.year.blockSignals(False)

    def _render_goals(self, goals: list[dict]) -> None:
        _clear(self.goals_host)
        if not goals:
            hint = QLabel(_("Set your goals above to see progress."))
            hint.setObjectName("Hint")
            hint.setWordWrap(True)
            self.goals_host.addWidget(hint)
            return
        for goal in goals:
            # Qt's clicked(bool) may pass through, so swallow it with `_`.
            on_remove = lambda _, g=goal: self._remove(g)
            self.goals_host.addWidget(_goal_card(goal, on_remove=on_remove))

    # -- actions ------------------------------------------------------------ #
    def _save(self) -> None:
        goal = {
            "year": self.year.currentData(),
            "target_books": self.target_books.value(),
            "target_pages": self.target_pages.value(),
            # A brand-new objective starts at zero progress; per-goal counts only
            # move when a book is actually marked read.
            "books_done": 0,
            "pages_done": 0,
        }
        self.save_btn.setEnabled(False)
        self.message.setText(_("Saving…"))
        self.message.setVisible(True)
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                lambda: get_repo().save_goals(goal),
                lambda _result: self._saved(goal),
                self._save_failed,
            )
            return
        try:
            get_repo().save_goals(goal)
        except Exception as exc:  # noqa: BLE001
            self._save_failed(str(exc))

            return
        self._saved(goal)

    def _saved(self, goal: dict) -> None:
        self.save_btn.setEnabled(True)
        if self._deleted:
            return
        # Merge the saved objective locally so the cards refresh without a
        # second round-trip to the repo (which would block the GUI in remote mode).
        year = goal.get("year")
        clean = {
            "year": year,
            "target_books": int(goal.get("target_books", 0) or 0),
            "target_pages": int(goal.get("target_pages", 0) or 0),
            # Progress is now per-objective counters; a brand-new objective starts
            # at zero, and the server will preserve existing progress on re-save.
            "books_done": int(goal.get("books_done", 0) or 0),
            "pages_done": int(goal.get("pages_done", 0) or 0),
        }
        merged = [g for g in self._goals if g.get("year") != year]
        if clean["target_books"] or clean["target_pages"]:
            merged.append(clean)
        self._goals = merged
        self._fill_years(merged)
        self._render_goals(merged)
        self.message.setText(_("Goals saved."))
        self.message.setVisible(True)

    def _remove(self, goal: dict) -> None:
        year = goal.get("year")
        target = 0 if year is None else int(year)
        self.message.setText(_("Removing…"))
        self.message.setVisible(True)
        if isinstance(get_repo(), RemoteRepo):
            run_blocking(
                lambda: get_repo().remove_goals(target),
                lambda _result: self._removed(goal),
                self._save_failed,
            )
            return
        try:
            get_repo().remove_goals(target)
        except Exception as exc:  # noqa: BLE001
            self._save_failed(str(exc))
            return
        self._removed(goal)

    def _removed(self, goal: dict) -> None:
        if self._deleted:
            return
        year = goal.get("year")
        self._goals = [g for g in self._goals if g.get("year") != year]
        self._fill_years(self._goals)
        self._render_goals(self._goals)
        self.message.setText(_("Objective removed."))
        self.message.setVisible(True)

    def _save_failed(self, message: str) -> None:
        self.save_btn.setEnabled(True)
        if self._deleted:
            return
        self.message.setText(_("Could not save the goals: %s") % message)
        self.message.setVisible(True)
