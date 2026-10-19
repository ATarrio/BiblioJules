"""A pill-shaped on/off switch matching the app's dark theme.

Qt has no native switch, so this is a ``QCheckBox`` subclass that paints the
track and knob itself. It keeps all the checkbox behaviour (click, space bar,
``isChecked()``, the ``toggled`` signal), so it drops in wherever a checkbox was
used.
"""

from __future__ import annotations

from PySide6.QtCore import QRectF, QSize, Qt
from PySide6.QtGui import QColor, QPainter, QPaintEvent, QPen
from PySide6.QtWidgets import QCheckBox, QWidget

from .theme import accent, surface

TRACK_WIDTH = 40
TRACK_HEIGHT = 22
KNOB_MARGIN = 3
LABEL_GAP = 10


class Switch(QCheckBox):
    """A checkbox rendered as a sliding switch, with an optional label."""

    def __init__(self, text: str = "", parent: QWidget | None = None) -> None:
        super().__init__(text, parent)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    # -- geometry ----------------------------------------------------------- #
    def sizeHint(self) -> QSize:
        base = super().sizeHint()
        text_width = self.fontMetrics().horizontalAdvance(self.text()) if self.text() else 0
        gap = LABEL_GAP if text_width else 0
        return QSize(TRACK_WIDTH + gap + text_width, max(base.height(), TRACK_HEIGHT))

    # -- painting ----------------------------------------------------------- #
    def paintEvent(self, event: QPaintEvent) -> None:  # noqa: N802 (Qt override)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)

        top = (self.height() - TRACK_HEIGHT) / 2
        track = QRectF(0.0, top, TRACK_WIDTH, TRACK_HEIGHT)
        radius = TRACK_HEIGHT / 2

        if not self.isEnabled():
            track_color = QColor(surface(800))
        elif self.isChecked():
            track_color = QColor(accent(600))
        else:
            track_color = QColor(surface(700))

        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(track_color)
        painter.drawRoundedRect(track, radius, radius)

        if self.hasFocus():
            pen = QPen(QColor(accent(500)))
            pen.setWidth(2)
            painter.setPen(pen)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRoundedRect(track.adjusted(-2, -2, 2, 2), radius + 2, radius + 2)

        knob_diameter = TRACK_HEIGHT - 2 * KNOB_MARGIN
        knob_x = (
            TRACK_WIDTH - KNOB_MARGIN - knob_diameter if self.isChecked() else KNOB_MARGIN
        )
        knob = QRectF(knob_x, top + KNOB_MARGIN, knob_diameter, knob_diameter)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(surface(50)))
        painter.drawEllipse(knob)

        if self.text():
            painter.setPen(QColor(surface(300)))
            text_rect = QRectF(
                TRACK_WIDTH + LABEL_GAP, 0.0, self.width() - TRACK_WIDTH - LABEL_GAP, self.height()
            )
            painter.drawText(
                text_rect,
                Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft,
                self.text(),
            )

        painter.end()
