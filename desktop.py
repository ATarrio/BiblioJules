#!/usr/bin/env python
"""Convenience launcher: ``python desktop.py`` opens the Qt desktop app.

This is the browser-free counterpart to ``run.py``. It reuses the same SQLite
database and service layer as the web app, so you can switch between the two
without migrating anything.

Requirements: ``pip install -r requirements-desktop.txt``
"""

from __future__ import annotations

from app.desktop import main

if __name__ == "__main__":
    raise SystemExit(main())
