"""Dark theme matching the web app.

The web UI is Tailwind's *slate* palette with a custom *brand* blue and
optionally the `dark` class. This module reproduces that look in Qt: a Fusion
base style, a dark palette for the bits QSS can't reach (menus, tooltips,
calendar), and one big stylesheet for the widgets we build.
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QApplication

_ASSETS = Path(__file__).resolve().parent / "assets"
CHECK_ICON = (_ASSETS / "check.svg").as_posix()
CHEVRON_ICON = (_ASSETS / "chevron.svg").as_posix()

# --- Palette (Tailwind slate + the web app's brand blue) ------------------- #
SLATE_950 = "#020617"
SLATE_900 = "#0f172a"
SLATE_800 = "#1e293b"
SLATE_700 = "#334155"
SLATE_600 = "#475569"
SLATE_500 = "#64748b"
SLATE_400 = "#94a3b8"
SLATE_300 = "#cbd5e1"
SLATE_200 = "#e2e8f0"
WHITE = "#f8fafc"

BRAND_500 = "#3366f2"
BRAND_600 = "#2049db"
BRAND_700 = "#1b3bb0"
BRAND_300 = "#8eb6ff"

EMERALD = "#34d399"
AMBER = "#f59e0b"
VIOLET = "#a78bfa"
RED = "#f87171"


def rgba(hex_color: str, alpha: float) -> str:
    """``#rrggbb`` + alpha → a Qt-friendly ``rgba(...)`` string."""
    color = QColor(hex_color)
    return f"rgba({color.red()}, {color.green()}, {color.blue()}, {alpha:.3f})"


# --- Application stylesheet ------------------------------------------------ #
QSS = f"""
/* ---------- base ---------- */
QWidget {{
    color: {SLATE_200};
    font-size: 13px;
}}
QMainWindow, QDialog {{ background-color: {SLATE_950}; }}

QToolTip {{
    background-color: {SLATE_800};
    color: {SLATE_200};
    border: 1px solid {SLATE_700};
    border-radius: 6px;
    padding: 4px 8px;
}}

/* ---------- sidebar ---------- */
QWidget#Sidebar {{
    background-color: {SLATE_900};
    border-right: 1px solid {SLATE_800};
}}
QLabel#BrandEmoji {{ font-size: 22px; background: transparent; }}
QLabel#BrandTitle {{
    color: {WHITE};
    font-size: 17px;
    font-weight: bold;
    background: transparent;
}}
QLabel#SidebarSection {{
    color: {SLATE_500};
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
    color: {SLATE_400};
    padding: 9px 12px;
    margin: 2px 0;
    border-radius: 8px;
}}
QListWidget#NavList::item:hover {{
    background-color: {SLATE_800};
    color: {SLATE_200};
}}
QListWidget#NavList::item:selected {{
    background-color: {rgba(BRAND_500, 0.16)};
    color: {BRAND_300};
    font-weight: bold;
}}

/* ---------- page headers ---------- */
QLabel#PageTitle {{
    font-size: 24px;
    font-weight: bold;
    color: {WHITE};
    background: transparent;
}}
QLabel#PageSubtitle {{
    font-size: 13px;
    color: {SLATE_400};
    background: transparent;
}}
QLabel#SectionTitle {{
    font-size: 16px;
    font-weight: bold;
    color: {WHITE};
    background: transparent;
}}

/* ---------- cards ---------- */
QFrame#Card {{
    background-color: {SLATE_900};
    border: 1px solid {SLATE_800};
    border-radius: 12px;
}}
QFrame#BookCard {{
    background-color: {SLATE_900};
    border: 1px solid {SLATE_800};
    border-radius: 12px;
}}
QFrame#BookCard:hover {{ border-color: {SLATE_700}; }}

QLabel#StatValue {{ font-size: 30px; font-weight: bold; background: transparent; }}
QLabel#StatLabel {{ font-size: 12px; color: {SLATE_400}; background: transparent; }}
QLabel#StatIcon {{ font-size: 20px; background: transparent; }}
QLabel#Muted {{ color: {SLATE_400}; background: transparent; }}
QLabel#Dim {{ color: {SLATE_500}; background: transparent; }}
QLabel#Hint {{ color: {AMBER}; background: transparent; }}
QLabel#DetailTitle {{ font-size: 20px; font-weight: bold; color: {WHITE}; background: transparent; }}
QLabel#DetailAuthors {{ color: {BRAND_300}; font-weight: bold; background: transparent; }}
QLabel#CoverImage {{
    background-color: {SLATE_900};
    border: 1px solid {SLATE_800};
    border-radius: 12px;
    color: {SLATE_500};
    font-size: 34px;
}}

/* ---------- buttons ---------- */
QPushButton {{
    background-color: {SLATE_800};
    color: {SLATE_200};
    border: 1px solid {SLATE_700};
    border-radius: 9px;
    padding: 7px 14px;
    font-weight: bold;
}}
QPushButton:hover {{ background-color: {SLATE_700}; }}
QPushButton:pressed {{ background-color: {SLATE_800}; }}
QPushButton:disabled {{ color: {SLATE_600}; border-color: {SLATE_800}; }}
QPushButton:default {{ }}

QPushButton[variant="primary"] {{
    background-color: {BRAND_600};
    border-color: {BRAND_600};
    color: #ffffff;
}}
QPushButton[variant="primary"]:hover {{ background-color: {BRAND_700}; border-color: {BRAND_700}; }}

QPushButton[variant="danger"] {{
    background-color: transparent;
    border-color: {rgba(RED, 0.4)};
    color: {RED};
}}
QPushButton[variant="danger"]:hover {{ background-color: {rgba(RED, 0.12)}; }}

QPushButton[variant="ghost"] {{
    background-color: transparent;
    border-color: transparent;
    color: {SLATE_400};
}}
QPushButton[variant="ghost"]:hover {{ background-color: {SLATE_800}; color: {SLATE_200}; }}

/* ---------- inputs ---------- */
QLineEdit, QPlainTextEdit, QTextEdit, QSpinBox, QDoubleSpinBox, QDateEdit, QComboBox {{
    background-color: {SLATE_950};
    border: 1px solid {SLATE_700};
    border-radius: 9px;
    padding: 7px 10px;
    color: {SLATE_200};
    selection-background-color: {BRAND_600};
    selection-color: #ffffff;
}}
QLineEdit:focus, QPlainTextEdit:focus, QTextEdit:focus, QSpinBox:focus,
QDoubleSpinBox:focus, QDateEdit:focus, QComboBox:focus {{
    border-color: {BRAND_500};
}}
QLineEdit:disabled, QComboBox:disabled, QSpinBox:disabled, QDateEdit:disabled {{
    color: {SLATE_600};
}}
QLineEdit::placeholder, QPlainTextEdit {{ color: {SLATE_200}; }}

QComboBox::drop-down {{ border: none; width: 24px; }}
QComboBox::down-arrow {{ image: url({CHEVRON_ICON}); width: 16px; height: 16px; }}
QComboBox QAbstractItemView {{
    background-color: {SLATE_900};
    border: 1px solid {SLATE_700};
    border-radius: 8px;
    color: {SLATE_200};
    outline: 0;
    selection-background-color: {BRAND_600};
    selection-color: #ffffff;
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
QCheckBox {{ color: {SLATE_300}; spacing: 8px; background: transparent; }}
QCheckBox::indicator {{
    width: 16px; height: 16px;
    border: 1px solid {SLATE_600};
    border-radius: 4px;
    background-color: {SLATE_950};
}}
QCheckBox::indicator:hover {{ border-color: {BRAND_500}; }}
QCheckBox::indicator:checked {{
    background-color: {BRAND_600};
    border-color: {BRAND_600};
    image: url({CHECK_ICON});
}}

/* ---------- tables / trees ---------- */
QTableWidget, QTreeWidget, QListWidget#PlainList {{
    background-color: {SLATE_900};
    alternate-background-color: #0b1324;
    border: 1px solid {SLATE_800};
    border-radius: 12px;
    gridline-color: {SLATE_800};
    color: {SLATE_200};
    outline: 0;
}}
QTableWidget::item, QTreeWidget::item {{
    padding: 6px;
    border: none;
}}
QTableWidget::item:selected, QTreeWidget::item:selected {{
    background-color: {rgba(BRAND_500, 0.22)};
    color: {WHITE};
}}
QTableWidget::item:hover, QTreeWidget::item:hover {{
    background-color: {rgba(BRAND_500, 0.10)};
}}
QHeaderView {{ background: transparent; }}
QHeaderView::section {{
    background-color: #0b1324;
    color: {SLATE_400};
    border: none;
    border-bottom: 1px solid {SLATE_800};
    padding: 8px;
    font-weight: bold;
}}
QHeaderView::section:first {{ border-top-left-radius: 12px; }}
QHeaderView::section:last {{ border-top-right-radius: 12px; }}
QTableCornerButton::section {{ background-color: #0b1324; border: none; }}
QTreeWidget::branch {{ background: transparent; }}

/* ---------- scrollbars ---------- */
QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: {SLATE_700}; border-radius: 5px; min-height: 30px; }}
QScrollBar::handle:vertical:hover {{ background: {SLATE_600}; }}
QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 2px; }}
QScrollBar::handle:horizontal {{ background: {SLATE_700}; border-radius: 5px; min-width: 30px; }}
QScrollBar::handle:horizontal:hover {{ background: {SLATE_600}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ width: 0; height: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

/* ---------- menus ---------- */
QMenuBar {{ background-color: {SLATE_900}; color: {SLATE_400}; border-bottom: 1px solid {SLATE_800}; }}
QMenuBar::item {{ padding: 6px 10px; background: transparent; }}
QMenuBar::item:selected {{ background-color: {SLATE_800}; color: {SLATE_200}; }}
QMenu {{ background-color: {SLATE_900}; color: {SLATE_200}; border: 1px solid {SLATE_800}; padding: 4px; }}
QMenu::item {{ padding: 6px 22px; border-radius: 6px; }}
QMenu::item:selected {{ background-color: {BRAND_600}; color: #ffffff; }}

/* ---------- dialog button box ---------- */
QDialogButtonBox QPushButton {{ min-width: 84px; }}

/* ---------- misc ---------- */
QScrollArea {{ border: none; background: transparent; }}
QScrollArea > QWidget > QWidget {{ background: transparent; }}
QWidget#PageContent {{ background-color: {SLATE_950}; }}
QStatusBar {{ background-color: {SLATE_900}; color: {SLATE_400}; border-top: 1px solid {SLATE_800}; }}
QSplitter::handle {{ background-color: {SLATE_800}; }}
QCalendarWidget QWidget {{ background-color: {SLATE_900}; }}
QCalendarWidget QAbstractItemView:enabled {{ color: {SLATE_200}; selection-background-color: {BRAND_600}; }}
"""


def apply_theme(app: QApplication) -> None:
    """Apply the Fusion style, dark palette and stylesheet to the app."""
    app.setStyle("Fusion")

    font = QFont()
    font.setFamilies(["Inter", "Segoe UI", "Helvetica Neue", "Ubuntu", "Arial", "sans-serif"])
    font.setPointSize(10)
    app.setFont(font)

    palette = QPalette()
    palette.setColor(QPalette.ColorRole.Window, QColor(SLATE_950))
    palette.setColor(QPalette.ColorRole.WindowText, QColor(SLATE_200))
    palette.setColor(QPalette.ColorRole.Base, QColor(SLATE_900))
    palette.setColor(QPalette.ColorRole.AlternateBase, QColor("#0b1324"))
    palette.setColor(QPalette.ColorRole.Text, QColor(SLATE_200))
    palette.setColor(QPalette.ColorRole.Button, QColor(SLATE_800))
    palette.setColor(QPalette.ColorRole.ButtonText, QColor(SLATE_200))
    palette.setColor(QPalette.ColorRole.ToolTipBase, QColor(SLATE_800))
    palette.setColor(QPalette.ColorRole.ToolTipText, QColor(SLATE_200))
    palette.setColor(QPalette.ColorRole.Highlight, QColor(BRAND_600))
    palette.setColor(QPalette.ColorRole.HighlightedText, QColor("#ffffff"))
    palette.setColor(QPalette.ColorRole.Link, QColor(BRAND_300))
    palette.setColor(QPalette.ColorRole.PlaceholderText, QColor(SLATE_500))
    app.setPalette(palette)

    app.setStyleSheet(QSS)
