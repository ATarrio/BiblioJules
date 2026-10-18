**English** · [Español (Latinoamérica)](README.es-419.md)

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
- **Bulk add.** Tick *Keep this form open* and the add form stays up after each
  save: the ISBN details are cleared, while the location, status and notes stay
  put, so a whole shelf can be scanned in one sitting. The desktop app has the
  same option on its add dialog.
- **Hierarchical locations.** Model your home as you like — rooms → bookcases
  → shelves → boxes. Pick a location from an indented list when adding a book
  instead of typing it out.
- **Statuses.** Built-in statuses (In library, Reading, Lent out, Wishlist,
  Lost, Donated) that you can rename, recolour, reorder, and extend with your
  own.
- **Reading metadata.** Record each book's cover type (hardcover, paperback,
  ebook…), reading status (unread, to be read, currently reading, read, DNF), a
  1–5 star score (in half-star steps), and its place in a saga (e.g. *Caliban's
  War* is #2 in *The Expanse*). The catalog can filter by saga; the desktop
  table also shows saga, read status and score as sortable columns, and the web
  cards show the saga and score.
- **Lending tracker.** Record who borrowed a book, when, and when you expect it
  back. Overdue loans are highlighted.
- **Wishlist.** The `Wishlist` status doubles as a to-buy list. The **Discover**
  page lets you search the online catalogues by title/author to add wishlist
  books you don't own yet.
- **Filter & search.** Filter by status, location (including everything nested
  underneath), author, publisher, read status, and loan state; search across
  title, author, publisher and ISBN.
- **Sortable lists.** Click a column header — in the web catalog grid or the
  desktop Catalog, Discover and Statuses tables — to sort by that column, and
  click it again to flip between ascending and descending.
- **Peek at a book.** Click a book tile (or double-click a row in the desktop
  app) for a pop-up with its full details — cover included — plus a one-click
  shortcut to edit them.
- **Sleek & responsive** UI with dark mode, works on phone, tablet and desktop.
- **Multilingual UI.** English is the default; a Latin American Spanish
  (`es-419`) translation ships alongside. Switch language from the sidebar (web)
  or the language picker (desktop) — the choice is remembered. Adding another
  language only means dropping a `app/locales/<code>.json` file (see below).
- **JSON API** (`/api/...`) and interactive API docs at `/docs`, so a future
  mobile app or SPA can reuse the same backend.
- **Accounts & a shared catalog.** Username/password sign-in, with an admin
  panel to add or remove people. Everyone shares the same shelves, so the app
  can be hosted and reached from the web, desktop and phone.

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

## Accounts & sign-in

BiblioJules is a **shared** library: every account sees and edits the same
catalogue. Accounts are access control, not private shelves.

The first administrator has to be created from a terminal (nobody can sign in
yet); after that, everyone else is added from the web UI:

```bash
python -m app.cli create-admin          # prompts for a password
python -m app.cli create-user jane      # an ordinary member
python -m app.cli list-users
python -m app.cli set-password jane
python -m app.cli delete-user jane
```

Then log in at <http://127.0.0.1:8000/login>. **Administrators** get an extra
*Users* page to add accounts, change roles, reset passwords or disable someone.
Members have full run of the catalogue — only user management is restricted.

Sessions last 30 days (see `SESSION_TTL_DAYS`) and live on the server, so
signing out, changing a password or disabling an account takes effect at once.

### Hosting it safely

If you expose the app beyond your home network:

- Serve it over **HTTPS** (behind a reverse proxy) and set `COOKIE_SECURE=true`,
  so the session cookie is only ever sent encrypted.
- Consider `ENABLE_DOCS=false` to hide `/docs` and the OpenAPI schema.
- `/api/*` is bearer-token only: log in with `POST /api/auth/login` to obtain a
  token. The desktop app (remote mode) and the Android app use the same route.

---

## Desktop app (optional, no browser)

There is also a native **Qt (PySide6)** desktop front-end for when you'd rather
not run a browser. It has two modes, chosen from **File → Settings…**:

- **Local database** (the default) — it opens the **same SQLite database** and
  reuses the same service layer as the web app, so you can switch between the
  two freely — no import/export needed (just don't run both against the same DB
  at the same instant).
- **Remote server** — it signs in to a hosted instance over the JSON API and
  keeps **no local database at all**, so a laptop can use the library from
  anywhere. Type the backend URL (e.g. `https://library.example.com`), sign in
  once, and the token is remembered.

```bash
# Install the extra dependency (Qt + the rest)
pip install -r requirements.txt -r requirements-desktop.txt

# Launch it
python desktop.py
```

PySide6 ships prebuilt wheels for **Windows, macOS and Linux** and bundles the
matching Qt runtime, so there's no system Qt to install. The desktop app needs
the same Python as the web app (installed in the same virtual environment).

The window has a sidebar mirroring the web pages — **Dashboard, Catalog,
Locations, Statuses, Discover** — with the same capabilities:

- browse, search and filter the catalog; add/edit/delete books;
- sort any list by clicking its column headers;
- scan-and-lookup an ISBN (or search online and add to the wishlist);
- lend and return books, with loan history;
- manage the nested location tree and the customisable statuses.

The button at the bottom of the sidebar always shows where the data comes from
(the local database, or the account you signed in with) and reopens the settings
dialog when clicked.

In **local mode**, because it opens the database file directly, `DATABASE_URL`
must resolve to the same file for both front-ends. The default
(`data/library.db`, absolute path) does; if you override `DATABASE_URL` in
`.env` with a *relative* path it will resolve against the working directory you
launch from, so prefer an absolute path there.

Either way the choice is written to `data/preferences.json`. In remote mode that
file also holds the sign-in token, so it is created with `0600` permissions —
keep it out of version control (`data/` already is).

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
│   ├── dependencies.py    # Auth (session/bearer) + CSRF guards
│   ├── cli.py             # Admin CLI (create-admin, create-user, …)
│   ├── database.py        # Engine, session, Declarative Base
│   ├── templating.py      # Jinja2 environment + filters
│   ├── i18n.py            # Translation core (gettext-style) + language middleware
│   ├── preferences.py     # Small JSON prefs store (UI language, data source, token)
│   ├── locales/           # Translation catalogs, e.g. es-419.json (English = source)
│   ├── schemas.py         # Pydantic request models for the JSON API
│   ├── models/            # SQLAlchemy models (one file per concept)
│   │   ├── book.py  author.py  publisher.py
│   │   ├── location.py  status.py  loan.py
│   │   ├── user.py  token.py
│   │   └── associations.py
│   ├── services/          # Business logic (framework-agnostic)
│   │   ├── library.py     #   CRUD, filtering, loans, locations, statuses
│   │   ├── auth.py        #   Accounts, password hashing, tokens
│   │   ├── isbn_lookup.py #   Online ISBN/metadata lookups
│   │   ├── serializers.py #   Model → dict for the JSON API
│   │   └── seed.py        #   Default statuses
│   ├── routers/           # HTTP endpoints (thin, call services)
│   │   ├── pages.py  books.py  locations.py  statuses.py
│   │   ├── auth.py        #   /login, /logout, /api/auth/...
│   │   ├── admin.py       #   /admin/users + /api/users
│   │   ├── lookup.py      #   Discover search / prefill
│   │   └── api.py         #   /api/... JSON API
│   ├── templates/         # Jinja2 templates (auth/, admin/, books/, ...)
│   ├── static/            # CSS & JS
│   └── desktop/           # Qt (PySide6) desktop front-end
│       ├── app.py         #   bootstrap: choose local or remote, show the window
│       ├── repo.py        #   data access: LocalRepo (SQLite) / RemoteRepo (HTTP)
│       ├── main_window.py #   sidebar + stacked views
│       ├── settings_dialog.py  # where is the library + sign in
│       ├── dashboard.py  catalog.py  locations_view.py
│       ├── statuses_view.py  discover.py
│       ├── dialogs.py     #   add/edit book, lend, location, status dialogs
│       ├── db.py  workers.py  util.py
│       └── ...
├── migrations/            # Alembic migrations (schema evolution)
├── run.py                 # Web launcher
├── desktop.py             # Desktop launcher
├── requirements.txt
├── requirements-desktop.txt
└── .env.example
```

**Design idea:** routers are thin. All rules live in `app/services/`, and all
database access goes through SQLAlchemy in `app/models/`. Adding a feature
usually means one model (maybe), one service function, and one route — the
existing code stays untouched. That's what keeps this easy to grow.

---

## Data model (at a glance)

- **Book** — ISBN, title/subtitle, `publisher` (many-to-one), `authors`
  (many-to-many), a single **Published** date field (the year is derived from it
  for sorting), description, pages, language, cover URL, cover type, read
  status, a 1–5 star score (half-star steps), saga name + number, `location`,
  `status`, notes, timestamps.
- **Location** — self-referential tree (`parent_id`): rooms → shelves → …
- **Status** — name, colour, emoji, sort order; `is_system` protects the
  built-ins, `is_default` marks the status new books get.
- **Loan** — a period during which a book was out: borrower, lent/due/returned
  dates, notes. An *active* loan has no return date.
- **Author/Publisher** — normalised so you can filter and reuse them. Rows that
  no longer have any book are pruned automatically (on book delete/edit and at
  startup), so the dashboard counts and filter lists stay accurate.

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
they don't exist, and adds any columns that were introduced after the database
was created (a safe, idempotent `ALTER TABLE ADD COLUMN`). A few small one-time
data fix-ups run at the same time — for example, folding a legacy publication
year into the single **Published** field.

### Evolving the schema with Alembic

Alembic is already configured (and pointed at the same `DATABASE_URL`). An
initial migration is included.

> Simple additive changes are applied automatically at startup. Reach for
> Alembic when a change is more involved (renames, type changes, dropped
> columns).

```bash
alembic upgrade head                              # apply migrations
alembic revision --autogenerate -m "my change"    # after editing models
alembic upgrade head
```

---

## JSON API

The HTML UI uses the same service layer, but a small JSON API is exposed for
scripting and for the desktop/mobile clients. Everything under `/api/` requires
a **bearer token**: obtain one with `POST /api/auth/login` and send it as
`Authorization: Bearer <token>`.

| Method & path | Purpose |
| --- | --- |
| `POST /api/auth/login` | Exchange username/password for a token |
| `GET /api/auth/me` · `POST /api/auth/logout` | Current account / revoke the token |
| `GET /api/books` | List/filter books (`search`, `status`, `location`, `author`, `publisher`, `loaned`, `saga`, `read_status`, `sort`, `dir`) |
| `GET /api/books/{id}` | One book |
| `GET /api/books/by-isbn/{isbn}` | One book by ISBN (duplicate checks) |
| `POST /api/books` · `PUT /api/books/{id}` · `DELETE /api/books/{id}` | Create / update / delete |
| `POST /api/books/{id}/lend` · `.../return` | Lend or return |
| `GET /api/books/{id}/loans` | Full loan history |
| `GET /api/locations` · `GET /api/locations/{id}` · `POST /api/locations` · `PUT` · `DELETE` | Locations |
| `GET /api/statuses` · `GET /api/statuses/{id}` · `POST /api/statuses` · `PUT` · `DELETE` | Statuses |
| `GET /api/authors` · `GET /api/publishers` · `GET /api/sagas` | Filter reference data |
| `GET /api/dashboard` · `GET /api/stats` | Dashboard aggregate / counters |
| `GET /api/meta` | Cover types, read statuses, score range, sorts, roles, languages |
| `GET /api/i18n/{lang}` | String catalog for a language |
| `GET /api/lookup/isbn/{isbn}` | Online metadata lookup |
| `GET /api/search?q=` | Online title/author search |
| `GET /api/users` · `POST /api/users` · `PUT /api/users/{id}` · `DELETE /api/users/{id}` | User management (**admin only**) |
| `GET /health` | Uptime/liveness check — `200` when the DB answers, `503` otherwise (public) |

Interactive docs: <http://127.0.0.1:8000/docs>

`PUT` endpoints follow the usual rule: fields you leave **out** are untouched,
and a field you send as `null` is **cleared** — which is how a form-style client
removes a book from its shelf without overwriting the rest of the record.

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

## Languages (i18n)

English is the source language and the default. Translations live in
`app/locales/<code>.json` as simple `{ "English text": "translation" }` maps, so
nothing has to be compiled:

```
app/locales/es-419.json   # Español (Latinoamérica)
```

- **Web:** the language is picked from `?lang=`, the `lang` cookie, or the
  browser's `Accept-Language` header (in that order). Use the selector at the
  bottom of the sidebar (or in the mobile header); the choice is stored in a
  cookie.
- **Desktop:** use the selector at the bottom of the sidebar. The choice is saved
  in `data/preferences.json` (along with the local/remote mode and, in remote
  mode, the sign-in token) and applied on the next launch.
- **Adding a language:** copy `app/locales/es-419.json`, translate the values,
  and add the code + endonym to `SUPPORTED_LANGUAGES` in `app/i18n.py`. A missing
  key simply falls back to the English text written in the code, so a partial
  catalog is fine.
- Plural forms use an object value: `"book": { "one": "libro", "other": "libros" }`.
- The built-in status names (In library, Reading, …) are translated by *slug*;
  if you rename one, your name is shown as-is.

---

## Notes

- The app is meant to be shared by a household. It now ships with accounts, so
  it is safe to host — but do read *Hosting it safely* above before exposing it
  to the internet (HTTPS, `COOKIE_SECURE`, and don't leave `/docs` open).
- Everything is local: your data lives only in your database file (and the
  online lookups only send the ISBN you scan).
