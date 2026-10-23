"""Uploaded cover images: validation, safe names and cleanup.

Covers are files next to the database (``data/covers``), not rows. Keeping the
path logic in one place means the web router and the JSON API agree about what
a safe ``/covers/<name>`` URL is and always delete the old file when a cover is
replaced.
"""

from __future__ import annotations

import secrets
from pathlib import Path

from ..config import DATA_DIR

MAX_COVER_BYTES = 10 * 1024 * 1024


def covers_dir() -> Path:
    folder = DATA_DIR / "covers"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def sniff_image(content: bytes) -> str | None:
    """Return a safe extension based on the file's own bytes, not its name."""
    if content.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if content.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if len(content) >= 12 and content[:4] == b"RIFF" and content[8:12] == b"WEBP":
        return ".webp"
    return None


def local_cover_path(cover_url: str | None) -> Path | None:
    """Resolve a ``/covers/<name>`` URL without ever escaping its folder."""
    if not cover_url or not cover_url.startswith("/covers/"):
        return None
    name = cover_url[len("/covers/"):]
    # A real cover name is one path segment. Reject separators and dot names
    # outright instead of silently flattening them to a basename.
    if (
        not name
        or name in (".", "..")
        or "/" in name
        or "\\" in name
        or name != Path(name).name
    ):
        return None
    return covers_dir() / name


def new_cover_name(book, suffix: str) -> str:
    """A random, collision-resistant filename tied to the book's sync id."""
    stable = getattr(book, "sync_id", None) or str(getattr(book, "id", "book"))
    return f"book-{stable}-{secrets.token_hex(8)}{suffix}"


def delete_cover(cover_url: str | None) -> None:
    path = local_cover_path(cover_url)
    if path is not None:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
