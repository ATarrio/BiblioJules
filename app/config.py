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

    # --- Authentication -----------------------------------------------------
    # Logins are opaque random tokens stored (hashed) in the database, so there
    # is no signing secret to configure: revoking a session is a database write
    # and survives a restart without one.

    # How long a login lasts before it must be repeated.
    session_ttl_days: int = 30
    # Send the session cookie only over HTTPS. Turn this on when hosting behind
    # a TLS reverse proxy; leave off for local ``http://127.0.0.1`` development.
    cookie_secure: bool = False

    # Extra browser origins allowed to call the JSON API (comma separated).
    # Native desktop/mobile clients do not need this.
    cors_origins: str = ""

    # --- Shared library (sync) ----------------------------------------------
    # The folder (or exact .sqlite file) that holds the shared snapshot. Point
    # this at a Google Drive folder, a Syncthing folder, a USB stick… Leave it
    # empty to keep the library local. Can also be set from the admin page.
    sync_file: str = ""
    # Merge the shared snapshot once at start-up (never on shutdown: a merge
    # can change data, and that deserves the user watching).
    sync_on_start: bool = False

    # Expose FastAPI's interactive docs (``/docs``) and the OpenAPI schema.
    # Convenient in development; consider disabling on a public instance.
    enable_docs: bool = True

    @property
    def user_agent(self) -> str:
        return f"BiblioJules/0.1 (home library catalog; {self.app_contact})"

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()

# Make sure the data directory exists for the default SQLite database.
DATA_DIR.mkdir(parents=True, exist_ok=True)
