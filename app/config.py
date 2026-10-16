"""Application configuration.

Everything that may change between environments (or between SQLite today and
PostgreSQL/MariaDB tomorrow) lives here. Values can be overridden with a local
``.env`` file or with real environment variables.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# Project root (the folder that contains the ``app`` package).
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"


class Settings(BaseSettings):
    """Runtime settings, read from the environment / ``.env``."""

    model_config = SettingsConfigDict(
        env_file=BASE_DIR / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_name: str = "BiblioJules"
    app_description: str = "A catalog for your home library."

    # --- Database -----------------------------------------------------------
    # Any SQLAlchemy URL works. SQLite by default; swap for
    # `postgresql+psycopg://...` or `mysql+pymysql://...` later.
    database_url: str = f"sqlite:///{DATA_DIR / 'library.db'}"
    sql_echo: bool = False

    # --- Online ISBN lookup -------------------------------------------------
    isbn_lookup_timeout: float = 10.0
    app_contact: str = "bibliophile@example.com"

    @property
    def user_agent(self) -> str:
        return f"BiblioJules/0.1 (home library catalog; {self.app_contact})"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()

# Make sure the data directory exists for the default SQLite database.
DATA_DIR.mkdir(parents=True, exist_ok=True)
