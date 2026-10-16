# 📚 BiblioJules

A friendly, modular catalog for your **home library**. Scan books with a USB
barcode reader (or type an ISBN by hand), let it fetch the metadata online,
and keep track of where every book lives, who borrowed it, and what you still
want to buy.

Built with **FastAPI + SQLAlchemy + Jinja2 + HTMX + Alpine.js + Tailwind CSS**.
SQLite by default, but the database layer is fully abstracted so switching to
**PostgreSQL or MariaDB** later is a one-line change.

---

## Features

- **Scan to add.** A USB barcode reader just types the ISBN and hits Enter.
  The app looks it up on free online services ([Open Library](https://openlibrary.org/developers/api)
  and [Google Books](https://developers.google.com/books)) and prefills
  title, authors, publisher, year, page count, description and cover image.
  Type the ISBN by hand and it works exactly the same.
- **Add by hand.** Any book without an ISBN (or unknown online) can be entered
  manually with the same form.
- **Hierarchical locations.** Model your home as you like — rooms → bookcases
  → shelves → boxes. Pick a location from an indented list when adding a book
  instead of typing it out.
- **Statuses.** Built-in statuses (In library, Reading, Lent out, Wishlist,
  Lost, Donated) that you can rename, recolour, reorder, and extend with your
  own.
- **Lending tracker.** Record who borrowed a book, when, and when you expect it
  back. Overdue loans are highlighted.
- **Wishlist.** The `Wishlist` status doubles as a to-buy list. The **Discover**
  page lets you search the online catalogues by title/author to add wishlist
  books you don't own yet.
- **Filter & search.** Filter by status, location (including everything nested
  underneath), author, publisher, and loan state; search across title, author,
  publisher and ISBN.
- **Sleek & responsive** UI with dark mode, works on phone, tablet and desktop.
- **JSON API** (`/api/...`) and interactive API docs at `/docs`, so a future
  mobile app or SPA can reuse the same backend.

---

## Quick start

```bash
# 1. Create a virtual environment and install dependencies
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 2. (optional) copy the example config
cp .env.example .env

# 3. Run it
python run.py
# or, with auto-reload while developing:
uvicorn app.main:app --reload
```

Open <http://127.0.0.1:8000>. The SQLite database and its folder are created
automatically on first run at `data/library.db`.

> **Note:** the UI loads Tailwind/HTMX/Alpine from a CDN and fetches book data
> from the internet, so the machine running it needs network access. For a
> fully offline setup, vendor those assets locally (see *Customisation*).

---

## Using it

1. **Set up your locations** (`Locations` page): add a room, then nest a
   bookcase and shelves underneath it.
2. **Scan a book**: put the cursor in the scan box (it's focused for you) and
   scan. Review the fetched details, choose a location, and save.
3. **Lend a book**: open it and use the *Lending* panel to record the borrower
   and expected return date.
4. **Build a wishlist**: set a book's status to *Wishlist*, or use **Discover**
   to search online and add books you want to buy.

---

## Project structure

```
.
├── app/
│   ├── main.py            # FastAPI app factory + startup (create tables, seed)
│   ├── config.py          # Settings (DATABASE_URL, timeouts…) via pydantic-settings
│   ├── database.py        # Engine, session, Declarative Base
│   ├── templating.py      # Jinja2 environment + filters
│   ├── schemas.py         # Pydantic request models for the JSON API
│   ├── models/            # SQLAlchemy models (one file per concept)
│   │   ├── book.py  author.py  publisher.py
│   │   ├── location.py  status.py  loan.py
│   │   └── associations.py
│   ├── services/          # Business logic (framework-agnostic)
│   │   ├── library.py     #   CRUD, filtering, loans, locations, statuses
│   │   ├── isbn_lookup.py #   Online ISBN/metadata lookups
│   │   ├── serializers.py #   Model → dict for the JSON API
│   │   └── seed.py        #   Default statuses
│   ├── routers/           # HTTP endpoints (thin, call services)
│   │   ├── pages.py  books.py  locations.py  statuses.py
│   │   ├── lookup.py      #   Discover search / prefill
│   │   └── api.py         #   /api/... JSON API
│   ├── templates/         # Jinja2 templates (+ reusable macros)
│   └── static/            # CSS & JS
├── migrations/            # Alembic migrations (schema evolution)
├── run.py                 # Convenience launcher
├── requirements.txt
└── .env.example
```

**Design idea:** routers are thin. All rules live in `app/services/`, and all
database access goes through SQLAlchemy in `app/models/`. Adding a feature
usually means one model (maybe), one service function, and one route — the
existing code stays untouched. That's what keeps this easy to grow.

---

## Data model (at a glance)

- **Book** — ISBN, title/subtitle, `publisher` (many-to-one), `authors`
  (many-to-many), publication info, description, pages, language, cover URL,
  `location`, `status`, notes, timestamps.
- **Location** — self-referential tree (`parent_id`): rooms → shelves → …
- **Status** — name, colour, emoji, sort order; `is_system` protects the
  built-ins, `is_default` marks the status new books get.
- **Loan** — a period during which a book was out: borrower, lent/due/returned
  dates, notes. An *active* loan has no return date.
- **Author/Publisher** — normalised so you can filter and reuse them.

---

## Switching to PostgreSQL or MariaDB

Because everything goes through SQLAlchemy, only the connection string changes.

```bash
# PostgreSQL
pip install "psycopg[binary]"
export DATABASE_URL="postgresql+psycopg://user:password@localhost:5432/bibliojules"

# MariaDB / MySQL
pip install pymysql
export DATABASE_URL="mysql+pymysql://user:password@localhost:3306/bibliojules"
```

Put it in `.env` to make it permanent. The app creates the tables on startup if
they don't exist.

### Evolving the schema with Alembic

Alembic is already configured (and pointed at the same `DATABASE_URL`). An
initial migration is included.

```bash
alembic upgrade head                              # apply migrations
alembic revision --autogenerate -m "my change"    # after editing models
alembic upgrade head
```

---

## JSON API

The HTML UI uses the same service layer, but a small JSON API is exposed for
scripting or a future front-end:

| Method & path | Purpose |
| --- | --- |
| `GET /api/books` | List/filter books (`search`, `status`, `location`, `author`, `publisher`, `loaned`, `sort`) |
| `GET /api/books/{id}` | One book |
| `POST /api/books` · `PUT /api/books/{id}` · `DELETE /api/books/{id}` | Create / update / delete |
| `POST /api/books/{id}/lend` · `.../return` | Lend or return |
| `GET /api/locations` · `POST /api/locations` | Locations |
| `GET /api/statuses` · `POST /api/statuses` | Statuses |
| `GET /api/lookup/isbn/{isbn}` | Online metadata lookup |
| `GET /api/search?q=` | Online title/author search |
| `GET /api/stats` | Counters for the dashboard |
| `GET /health` | Uptime/liveness check — `200` when the DB answers, `503` otherwise |

Interactive docs: <http://127.0.0.1:8000/docs>

---

## Customisation

- **Theme:** Tailwind is loaded from its Play CDN with a small config in
  `app/templates/base.html` (brand colour, dark mode). Vendored/compiled
  Tailwind can be dropped in `app/static/css/` and the CDN script removed.
- **ISBN sources:** providers live in `app/services/isbn_lookup.py`. The merger
  already fills missing fields from a second source — add a third by writing one
  async function and adding it to the provider list.
- **Statuses like the wishlist** are wired by *slug* (`wishlist`, `lent`,
  `available`…). Renaming them is fine; the slug stays.

---

## Notes

- The app is intended for a trusted home network; it has **no authentication**.
  Don't expose it directly to the internet without adding auth.
- Everything is local: your data lives only in your database file (and the
  online lookups only send the ISBN you scan).
