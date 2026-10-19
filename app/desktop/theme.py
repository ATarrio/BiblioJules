"""Dark theme matching the web app, wearing the colours the user picked.

The web UI is Tailwind's *slate* palette with a single accent — ``brand``, the
theme chosen in Settings. This module reproduces that look in Qt: a Fusion base
style, a dark palette for the bits QSS can't reach (menus, tooltips, calendar),
and one big stylesheet for the widgets we build. Everything — the accent *and*
the surfaces, whose hue follows it at slate's own lightness — comes from the
active theme in ``app/themes.json`` (shared with the web and Android
front-ends), so ``apply_theme()`` again is all a switch needs.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QApplication

from .. import themes

_ASSETS = Path(__file__).resolve().parent / "assets"
CHECK_ICON = (_ASSETS / "check.svg").as_posix()
CHEVRON_ICON = (_ASSETS / "chevron.svg").as_posix()
LOGO_SVG = (_ASSETS / "logo.svg").as_posix()
LOGO_PNG = (_ASSETS / "logo.png").as_posix()
_CHECK_SVG = (_ASSETS / "check.svg").read_text(encoding="utf-8")

# Colours with a meaning of their own, so they do not move with the theme.
EMERALD = "#34d399"
AMBER = "#f59e0b"
VIOLET = "#a78bfa"
RED = "#f87171"

#: The theme every widget draws with. ``apply_theme`` sets it from the one the
#: user chose; everything below reads it through ``accent()``/``surface()``.
_active: themes.ColorTheme = themes.get_theme(themes.DEFAULT_THEME)


def set_theme(slug: str | None) -> themes.ColorTheme:
    """Make ``slug``'s colours the ones the stylesheet and widgets use."""
    global _active
    _active = themes.get_theme(slug)
    return _active


def current_theme() -> themes.ColorTheme:
    """The theme in use right now."""
    return _active


def accent(shade: int = 500) -> str:
    """One shade of the active accent (``500`` when unsure)."""
    return _active.shade(shade)


def accent_ink() -> str:
    """The colour of text drawn *on* the active accent."""
    return _active.ink


def surface(shade: int = 900) -> str:
    """One step of the active surface ramp (``900`` when unsure).

    Slate's lightness at every step with the theme's hue, so panels, borders and
    body text all move together and keep the contrast they were designed with.
    """
    return _active.surface_shade(shade)


def _blend(first: str, second: str, ratio: float) -> str:
    """Mix ``first`` towards ``second`` — used for the shade between two steps."""
    one, two = QColor(first), QColor(second)
    mixed = (
        round(start + (end - start) * ratio)
        for start, end in (
            (one.red(), two.red()),
            (one.green(), two.green()),
            (one.blue(), two.blue()),
        )
    )
    return QColor(*mixed).name()


def surface_alt() -> str:
    """The step between ``900`` and ``950`` (table headers, striped rows)."""
    return _blend(surface(900), surface(950), 0.35)


def _tick_icon(ink: str) -> str:
    """A checkmark in ``ink``, as a path QSS can point at.

    The bundled tick is white, which is right for every theme but yellow. Qt
    stylesheets cannot recolour an image, so for a dark ink the artwork is
    re-tinted once into the temporary directory — and the shipped file is used
    unchanged (no write at all) whenever the ink is white.
    """
    if ink.lower() == "#ffffff":
        return CHECK_ICON
    try:
        target = Path(tempfile.gettempdir()) / f"bibliojules-check-{ink.lstrip('#')}.svg"
        if not target.exists():
            target.write_text(_CHECK_SVG.replace("#ffffff", ink), encoding="utf-8")
        return target.as_posix()
    except OSError:  # pragma: no cover - read-only temp directory
        return CHECK_ICON


def rgba(hex_color: str, alpha: float) -> str:
    """``#rrggbb`` + alpha → a Qt-friendly ``rgba(...)`` string."""
    color = QColor(hex_color)
    return f"rgba({color.red()}, {color.green()}, {color.blue()}, {alpha:.3f})"


# --- Application stylesheet ------------------------------------------------ #
def build_qss() -> str:
    """The application stylesheet, in the accent currently selected."""
    brand_300 = accent(300)
    brand_500 = accent(500)
    brand_600 = accent(600)
    brand_700 = accent(700)
    ink = accent_ink()
    check_icon = _tick_icon(ink)
    return f"""
    /* ---------- base ---------- */
    QWidget {{
        color: {surface(200)};
        font-size: 13px;
    }}
    QMainWindow, QDialog {{ background-color: {surface(950)}; }}

    QToolTip {{
        background-color: {surface(800)};
        color: {surface(200)};
        border: 1px solid {surface(700)};
        border-radius: 6px;
        padding: 4px 8px;
    }}

    /* ---------- sidebar ---------- */
    QWidget#Sidebar {{
        background-color: {surface(900)};
        border-right: 1px solid {surface(800)};
    }}
    QLabel#BrandLogo {{ background: transparent; }}
    QLabel#BrandTitle {{
        color: {surface(50)};
        font-size: 17px;
        font-weight: bold;
        background: transparent;
    }}
    QLabel#SidebarSection {{
        color: {surface(500)};
        font-size: 11px;
        font-weight: bold;
        padding: 12px 14px 4px 14px;
        background: transparent;
    }}

    QListWidget#NavList {{
        background: transparent;
        border: none;
        outline: 0;
        padding: 4px 8px;
    }}
    QListWidget#NavList::item {{
        color: {surface(400)};
        padding: 9px 12px;
        margin: 2px 0;
        border-radius: 8px;
    }}
    QListWidget#NavList::item:hover {{
        background-color: {surface(800)};
        color: {surface(200)};
    }}
    QListWidget#NavList::item:selected {{
        background-color: {rgba(brand_500, 0.16)};
        color: {brand_300};
        font-weight: bold;
    }}

    /* The "which library am I using?" footer button: reads as a caption, not a button. */
    QPushButton#ConnectionButton {{
        background: transparent;
        border: none;
        color: {surface(400)};
        font-weight: normal;
        text-align: left;
        padding: 6px 8px;
    }}
    QPushButton#ConnectionButton:hover {{
        background-color: {surface(800)};
        color: {surface(200)};
        border-radius: 8px;
    }}

    /* ---------- page headers ---------- */
    QLabel#PageTitle {{
        font-size: 24px;
        font-weight: bold;
        color: {surface(50)};
        background: transparent;
    }}
    QLabel#PageSubtitle {{
        font-size: 13px;
        color: {surface(400)};
        background: transparent;
    }}
    QLabel#SectionTitle {{
        font-size: 16px;
        font-weight: bold;
        color: {surface(50)};
        background: transparent;
    }}

    /* ---------- cards ---------- */
    QFrame#Card {{
        background-color: {surface(900)};
        border: 1px solid {surface(800)};
        border-radius: 12px;
    }}
    QFrame#BookCard {{
        background-color: {surface(900)};
        border: 1px solid {surface(800)};
        border-radius: 12px;
    }}
    QFrame#BookCard:hover {{ border-color: {surface(700)}; }}

    QLabel#StatValue {{ font-size: 30px; font-weight: bold; background: transparent; }}
    QLabel#StatLabel {{ font-size: 12px; color: {surface(400)}; background: transparent; }}
    QLabel#StatIcon {{ font-size: 20px; background: transparent; }}
    QLabel#Muted {{ color: {surface(400)}; background: transparent; }}
    QLabel#Dim {{ color: {surface(500)}; background: transparent; }}
    QLabel#Hint {{ color: {AMBER}; background: transparent; }}
    QLabel#DetailTitle {{ font-size: 20px; font-weight: bold; color: {surface(50)}; background: transparent; }}
    QLabel#DetailAuthors {{ color: {brand_300}; font-weight: bold; background: transparent; }}
    QLabel#CoverImage {{
        background-color: {surface(900)};
        border: 1px solid {surface(800)};
        border-radius: 12px;
        color: {surface(500)};
        font-size: 34px;
    }}

    /* ---------- buttons ---------- */
    QPushButton {{
        background-color: {surface(800)};
        color: {surface(200)};
        border: 1px solid {surface(700)};
        border-radius: 9px;
        padding: 7px 14px;
        font-weight: bold;
    }}
    QPushButton:hover {{ background-color: {surface(700)}; }}
    QPushButton:pressed {{ background-color: {surface(800)}; }}
    QPushButton:disabled {{ color: {surface(600)}; border-color: {surface(800)}; }}
    QPushButton:default {{ }}

    QPushButton[variant="primary"] {{
        background-color: {brand_600};
        border-color: {brand_600};
        color: {ink};
    }}
    QPushButton[variant="primary"]:hover {{ background-color: {brand_700}; border-color: {brand_700}; }}

    QPushButton[variant="danger"] {{
        background-color: transparent;
        border-color: {rgba(RED, 0.4)};
        color: {RED};
    }}
    QPushButton[variant="danger"]:hover {{ background-color: {rgba(RED, 0.12)}; }}

    QPushButton[variant="ghost"] {{
        background-color: transparent;
        border-color: transparent;
        color: {surface(400)};
    }}
    QPushButton[variant="ghost"]:hover {{ background-color: {surface(800)}; color: {surface(200)}; }}

    /* ---------- inputs ---------- */
    QLineEdit, QPlainTextEdit, QTextEdit, QSpinBox, QDoubleSpinBox, QDateEdit, QComboBox {{
        background-color: {surface(950)};
        border: 1px solid {surface(700)};
        border-radius: 9px;
        padding: 7px 10px;
        color: {surface(200)};
        selection-background-color: {brand_600};
        selection-color: {ink};
    }}
    QLineEdit:focus, QPlainTextEdit:focus, QTextEdit:focus, QSpinBox:focus,
    QDoubleSpinBox:focus, QDateEdit:focus, QComboBox:focus {{
        border-color: {brand_500};
    }}
    QLineEdit:disabled, QComboBox:disabled, QSpinBox:disabled, QDateEdit:disabled {{
        color: {surface(600)};
    }}
    QLineEdit::placeholder, QPlainTextEdit {{ color: {surface(200)}; }}

    QComboBox::drop-down {{ border: none; width: 24px; }}
    QComboBox::down-arrow {{ image: url({CHEVRON_ICON}); width: 16px; height: 16px; }}
    QComboBox QAbstractItemView {{
        background-color: {surface(900)};
        border: 1px solid {surface(700)};
        border-radius: 8px;
        color: {surface(200)};
        outline: 0;
        selection-background-color: {brand_600};
        selection-color: {ink};
        padding: 4px;
    }}
    QComboBox QAbstractItemView::item {{ padding: 6px 8px; border-radius: 6px; }}

    QSpinBox::up-button, QSpinBox::down-button,
    QDoubleSpinBox::up-button, QDoubleSpinBox::down-button {{
        width: 0; height: 0; border: none; background: transparent;
    }}

    QDateEdit::drop-down {{ border: none; width: 22px; }}
    QDateEdit::down-arrow {{ image: url({CHEVRON_ICON}); width: 16px; height: 16px; }}

    /* ---------- checkboxes ---------- */
    QCheckBox {{ color: {surface(300)}; spacing: 8px; background: transparent; }}
    QCheckBox::indicator {{
        width: 16px; height: 16px;
        border: 1px solid {surface(600)};
        border-radius: 4px;
        background-color: {surface(950)};
    }}
    QCheckBox::indicator:hover {{ border-color: {brand_500}; }}
    QCheckBox::indicator:checked {{
        background-color: {brand_600};
        border-color: {brand_600};
        image: url({check_icon});
    }}

    /* ---------- tables / trees ---------- */
    QTableWidget, QTreeWidget, QListWidget#PlainList {{
        background-color: {surface(900)};
        alternate-background-color: {surface_alt()};
        border: 1px solid {surface(800)};
        border-radius: 12px;
        gridline-color: {surface(800)};
        color: {surface(200)};
        outline: 0;
    }}
    QTableWidget::item, QTreeWidget::item {{
        padding: 6px;
        border: none;
    }}
    QTableWidget::item:selected, QTreeWidget::item:selected {{
        background-color: {rgba(brand_500, 0.22)};
        color: {surface(50)};
    }}
    QTableWidget::item:hover, QTreeWidget::item:hover {{
        background-color: {rgba(brand_500, 0.10)};
    }}
    QHeaderView {{ background: transparent; }}
    QHeaderView::section {{
        background-color: {surface_alt()};
        color: {surface(400)};
        border: none;
        border-bottom: 1px solid {surface(800)};
        padding: 8px;
        font-weight: bold;
    }}
    QHeaderView::section:first {{ border-top-left-radius: 12px; }}
    QHeaderView::section:last {{ border-top-right-radius: 12px; }}
    QTableCornerButton::section {{ background-color: {surface_alt()}; border: none; }}
    QTreeWidget::branch {{ background: transparent; }}

    /* ---------- scrollbars ---------- */
    QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
    QScrollBar::handle:vertical {{ background: {surface(700)}; border-radius: 5px; min-height: 30px; }}
    QScrollBar::handle:vertical:hover {{ background: {surface(600)}; }}
    QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 2px; }}
    QScrollBar::handle:horizontal {{ background: {surface(700)}; border-radius: 5px; min-width: 30px; }}
    QScrollBar::handle:horizontal:hover {{ background: {surface(600)}; }}
    QScrollBar::add-line, QScrollBar::sub-line {{ width: 0; height: 0; }}
    QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

    /* ---------- menus ---------- */
    QMenuBar {{ background-color: {surface(900)}; color: {surface(400)}; border-bottom: 1px solid {surface(800)}; }}
    QMenuBar::item {{ padding: 6px 10px; background: transparent; }}
    QMenuBar::item:selected {{ background-color: {surface(800)}; color: {surface(200)}; }}
    QMenu {{ background-color: {surface(900)}; color: {surface(200)}; border: 1px solid {surface(800)}; padding: 4px; }}
    QMenu::item {{ padding: 6px 22px; border-radius: 6px; }}
    QMenu::item:selected {{ background-color: {brand_600}; color: {ink}; }}

    /* ---------- dialog button box ---------- */
    QDialogButtonBox QPushButton {{ min-width: 84px; }}

    /* ---------- misc ---------- */
    QScrollArea {{ border: none; background: transparent; }}
    QScrollArea > QWidget > QWidget {{ background: transparent; }}
    QWidget#PageContent {{ background-color: {surface(950)}; }}
    QStatusBar {{ background-color: {surface(900)}; color: {surface(400)}; border-top: 1px solid {surface(800)}; }}
    QSplitter::handle {{ background-color: {surface(800)}; }}
    QCalendarWidget QWidget {{ background-color: {surface(900)}; }}
    QCalendarWidget QAbstractItemView:enabled {{ color: {surface(200)}; selection-background-color: {brand_600}; }}
    """


def apply_theme(app: QApplication, slug: str | None = None) -> None:
    """Apply the Fusion style, the dark palette and the stylesheet.

    ``slug`` selects the accent; leave it out to keep the one in use.
    """
    if slug is not None:
        set_theme(slug)

    app.setStyle("Fusion")

    font = QFont()
    font.setFamilies(["Inter", "Segoe UI", "Helvetica Neue", "Ubuntu", "Arial", "sans-serif"])
    font.setPointSize(10)
    app.setFont(font)

    palette = QPalette()
    palette.setColor(QPalette.ColorRole.Window, QColor(surface(950)))
    palette.setColor(QPalette.ColorRole.WindowText, QColor(surface(200)))
    palette.setColor(QPalette.ColorRole.Base, QColor(surface(900)))
    palette.setColor(QPalette.ColorRole.AlternateBase, QColor(surface_alt()))
    palette.setColor(QPalette.ColorRole.Text, QColor(surface(200)))
    palette.setColor(QPalette.ColorRole.Button, QColor(surface(800)))
    palette.setColor(QPalette.ColorRole.ButtonText, QColor(surface(200)))
    palette.setColor(QPalette.ColorRole.ToolTipBase, QColor(surface(800)))
    palette.setColor(QPalette.ColorRole.ToolTipText, QColor(surface(200)))
    palette.setColor(QPalette.ColorRole.Highlight, QColor(accent(600)))
    palette.setColor(QPalette.ColorRole.HighlightedText, QColor(accent_ink()))
    palette.setColor(QPalette.ColorRole.Link, QColor(accent(300)))
    palette.setColor(QPalette.ColorRole.PlaceholderText, QColor(surface(500)))
    app.setPalette(palette)

    app.setStyleSheet(build_qss())
