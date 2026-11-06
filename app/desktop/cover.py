"""A cover-art label that loads its image from a URL in the background.

Qt's own ``QNetworkAccessManager`` is used so a slow (or unreachable) cover
never blocks the GUI thread: the label shows a placeholder until the download
finishes, then swaps in a rounded, cropped image.

Decoded covers live in a small module-level cache: the catalog repaints its
rows on every filter or sort change, and without it a full shelf would mean a
full shelf of image requests every time.
"""

from __future__ import annotations

import html

from PySide6.QtCore import Qt, QUrl
from PySide6.QtGui import QPainter, QPainterPath, QPixmap
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkReply, QNetworkRequest
from PySide6.QtWidgets import QLabel

from ..services import covers

_RADIUS = 12

#: Largest cover the desktop draws (the book-details dialog). Downloads are
#: shrunk to fit this box before they are cached, so a long list costs memory
#: instead of another round trip per row.
_CACHE_FIT = (170, 255)
_CACHE_LIMIT = 200

#: cover URL -> decoded image, least recently used first
_decoded: dict[str, QPixmap] = {}


def cover_source(url: str | None, base_url: str | None = None) -> str | None:
    """Absolute URL Qt can fetch for a stored ``cover_url``, or None.

    Covers uploaded to the library are kept as the relative ``/covers/<name>``
    the web app serves: against a hosted server that is a path on that host,
    against a local library it is a file in ``data/covers``.
    """
    if not url:
        return None
    if url.startswith(("http://", "https://")):
        return url
    if url.startswith("/covers/"):
        path = covers.local_cover_path(url)
        if path is not None and path.is_file():
            return QUrl.fromLocalFile(str(path)).toString()
        if base_url:
            return base_url + url
    return None



def _recall(url: str) -> QPixmap | None:
    """Cached image for ``url``, marked as the most recently used."""
    pixmap = _decoded.pop(url, None)
    if pixmap is None:
        return None
    _decoded[url] = pixmap
    return pixmap


def _remember(url: str, pixmap: QPixmap) -> None:
    """Cache a decoded cover, shrunk to the largest size it will be shown at."""
    _decoded[url] = pixmap.scaled(
        _CACHE_FIT[0],
        _CACHE_FIT[1],
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    while len(_decoded) > _CACHE_LIMIT:
        del _decoded[next(iter(_decoded))]


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
        self._source: str | None = None
        self._seq = 0
        self._gone = False
        # A table row that is repainted destroys its old cell widget, so a
        # download still in flight must not try to paint on it afterwards.
        self.destroyed.connect(self._drop_pending)
        self._show_placeholder()

    # -- public API ----------------------------------------------------- #
    def load(self, url: str | None, title: str = "") -> None:
        """Show the fallback, then swap in ``url``'s image once it downloads."""
        self._title = title
        self._seq += 1
        seq = self._seq
        self._show_placeholder()
        self._source = None
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
        cached = _recall(url)
        if cached is not None:
            # Already decoded: paint it without another round trip.
            self._set_cover(cached)
            return
        manager = QNetworkAccessManager(self)
        reply = manager.get(QNetworkRequest(QUrl(url)))
        reply.finished.connect(lambda: self._on_finished(reply, seq))
        self._manager = manager  # keep a reference until the reply lands
        self._reply = reply
        self._source = url

    # -- internals ------------------------------------------------------ #
    def _drop_pending(self) -> None:
        """Qt is tearing this label down: abandon any download still running."""
        self._gone = True
        if self._reply is not None:
            self._reply.abort()
            self._reply.deleteLater()
            self._reply = None
        if self._manager is not None:
            self._manager.deleteLater()
            self._manager = None

    def _show_placeholder(self) -> None:
        self.setPixmap(QPixmap())
        emoji = max(10, self._width // 3)
        parts = [f'<div style="font-size:{emoji}px;">📕</div>']
        title = html.escape(self._title or "")
        # Small thumbnails (catalog rows, dashboard cards) print the title
        # beside them; only a big cover can carry it without crowding.
        if title and self._width >= 120:
            parts.append(f'<div style="font-size:12px; color:#64748b;">{title}</div>')
        self.setText("".join(parts))

    def _on_finished(self, reply: QNetworkReply, seq: int) -> None:
        if self._gone or seq != self._seq:
            reply.deleteLater()
            return
        data = reply.readAll()
        pixmap = QPixmap()
        if reply.error() == QNetworkReply.NetworkError.NoError and pixmap.loadFromData(data):
            if self._source is not None:
                _remember(self._source, pixmap)
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
