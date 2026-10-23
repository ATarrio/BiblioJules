"""A cover-art label that loads its image from a URL in the background.

Qt's own ``QNetworkAccessManager`` is used so a slow (or unreachable) cover
never blocks the GUI thread: the label shows a placeholder until the download
finishes, then swaps in a rounded, cropped image.
"""

from __future__ import annotations

import html

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QPainter, QPainterPath, QPixmap
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkReply, QNetworkRequest
from PySide6.QtWidgets import QLabel

_RADIUS = 12


class CoverImage(QLabel):
    """Fixed 2:3 cover preview with an async loader and a tasteful fallback."""

    def __init__(self, width: int = 170, parent=None) -> None:
        super().__init__(parent)
        self._width = width
        self._height = round(width * 3 / 2)
        self._title = ""
        self.setFixedSize(self._width, self._height)
        self.setObjectName("CoverImage")
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setWordWrap(True)
        self._manager: QNetworkAccessManager | None = None
        self._reply: QNetworkReply | None = None
        self._seq = 0
        self._show_placeholder()

    # -- public API ----------------------------------------------------- #
    def load(self, url: str | None, title: str = "") -> None:
        """Show the fallback, then swap in ``url``'s image once it downloads."""
        self._title = title
        self._seq += 1
        seq = self._seq
        self._show_placeholder()
        # Reusing a widget for another book must not let the previous cover's
        # slow reply land on top of the new one.
        if self._reply is not None:
            self._reply.abort()
            self._reply.deleteLater()
            self._reply = None
        if self._manager is not None:
            self._manager.deleteLater()
            self._manager = None
        if not url:
            return
        manager = QNetworkAccessManager(self)
        reply = manager.get(QNetworkRequest(QUrl(url)))
        reply.finished.connect(lambda: self._on_finished(reply, seq))
        self._manager = manager  # keep a reference until the reply lands
        self._reply = reply

    # -- internals ------------------------------------------------------ #
    def _show_placeholder(self) -> None:
        self.setPixmap(QPixmap())
        title = html.escape(self._title or "")
        self.setText(
            '<div style="font-size:34px;">📕</div>'
            f'<div style="font-size:12px; color:#64748b;">{title}</div>'
        )

    def _on_finished(self, reply: QNetworkReply, seq: int) -> None:
        if seq != self._seq:
            reply.deleteLater()
            return
        data = reply.readAll()
        pixmap = QPixmap()
        if reply.error() == QNetworkReply.NetworkError.NoError and pixmap.loadFromData(data):
            self._set_cover(pixmap)
        else:
            self._show_placeholder()
        self._reply = None
        if self._manager is not None:
            self._manager.deleteLater()
            self._manager = None
        reply.deleteLater()

    def _set_cover(self, pixmap: QPixmap) -> None:
        self.setText("")
        scaled = pixmap.scaled(
            self._width,
            self._height,
            Qt.AspectRatioMode.KeepAspectRatioByExpanding,
            Qt.TransformationMode.SmoothTransformation,
        )
        x = max(0, (scaled.width() - self._width) // 2)
        y = max(0, (scaled.height() - self._height) // 2)
        cropped = scaled.copy(x, y, self._width, self._height)

        rounded = QPixmap(self._width, self._height)
        rounded.fill(Qt.GlobalColor.transparent)
        painter = QPainter(rounded)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(0, 0, self._width, self._height, _RADIUS, _RADIUS)
        painter.setClipPath(path)
        painter.drawPixmap(0, 0, cropped)
        painter.end()
        self.setPixmap(rounded)
