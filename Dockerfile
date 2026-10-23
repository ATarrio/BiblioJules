# BiblioJules in a container: the web app *and* the JSON API that the desktop
# and Android clients sign in to. The SQLite database lives on a volume, so
# replacing the container never touches your library.
#
#   docker build -t bibliojules .
#   docker run -d -p 8000:8000 -v bibliojules-data:/app/data bibliojules
#
# …or, more comfortably, with the bundled compose file (see README.md).

# Pin to a specific safe Python 3.13 patch release (3.13.16, Oct 2026).
# Avoid the floating "3.13-slim" tag so rebuilds don't silently pull older,
# vulnerable Python versions.
FROM python:3.13.16-slim

# No .pyc files, and logs appear immediately instead of being buffered.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencies first: this layer stays cached until requirements.txt changes.
# Pin pip to a safe version (CVE-2025-8869 affects pip <= 25.2).
RUN python -m pip install --no-cache-dir --upgrade pip==26.2.2 \
    && pip install --no-cache-dir -r requirements.txt

# The application itself, plus the migration tooling so Alembic can also be run
# inside the container (see "Evolving the schema with Alembic" in README.md).
COPY app ./app
COPY migrations ./migrations
COPY alembic.ini run.py ./

# Run as an unprivileged user. The data directory is created (and owned by that
# user) here so a fresh named volume mounted over it inherits the right
# permissions, which SQLite needs to create its journal/WAL files.
RUN useradd --create-home --uid 10001 bibliojules \
    && mkdir -p /app/data \
    && chown -R bibliojules:bibliojules /app
USER bibliojules

# Where the library lives inside the image. Override it for PostgreSQL/MariaDB.
ENV DATABASE_URL=sqlite:////app/data/library.db

EXPOSE 8000

# The image has no curl, but Python is right there and can ask the app itself.
# /health answers 503 when the database is unreachable, so this checks more than
# "the process is running".
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"]

# 0.0.0.0 rather than run.py's 127.0.0.1: the container has to accept
# connections from outside itself.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
