#!/usr/bin/env python
"""Convenience launcher: ``python run.py`` then open http://127.0.0.1:8000.

For development with auto-reload:

    uvicorn app.main:app --reload
"""

from __future__ import annotations

import uvicorn

if __name__ == "__main__":
    uvicorn.run("app.main:app", host="127.0.0.1", port=8000, reload=False)
