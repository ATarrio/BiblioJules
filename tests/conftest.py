"""Shared pytest fixtures."""

from __future__ import annotations

import sys
from pathlib import Path

# Plain `pytest` does not put the repo root on sys.path; do it explicitly so
# `import app` works from wherever the suite is launched.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import models  # noqa: F401  (registers every model on Base.metadata)
from app.database import Base
from app.services.seed import seed_defaults


@pytest.fixture()
def db():
    """A fresh in-memory library, seeded with the built-in statuses."""
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    session = sessionmaker(bind=engine, expire_on_commit=False)()
    seed_defaults(session)
    try:
        yield session
    finally:
        session.close()
        engine.dispose()
