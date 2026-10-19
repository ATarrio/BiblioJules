**English** · [Español (Latinoamérica)](README.es-419.md)

# 📚 BiblioJules

A friendly, modular catalog for your **home library**. Scan books with a USB
barcode reader (or type an ISBN by hand), let it fetch the metadata online,
and keep track of where every book lives, who borrowed it, and what you still
want to buy.

Built with **FastAPI + SQLAlchemy + Jinja2 + HTMX + Alpine.js + Tailwind CSS**.
SQLite by default, but the database layer is fully abstracted so switching to
**PostgreSQL or MariaDB** later is a one-line change.

Host it once and reach it from anywhere: there is a **web app**, a native
**desktop app** (Qt/PySide6) and a native **Android app** (Flutter) — all three
talk to the same account-protected catalog. The phone can also keep a library of
its own and work with **no server at all**.

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
- **Sleek & responsive** UI with dark mode and eight colour themes that repaint
  the accents and the surfaces alike, on phone, tablet and desktop.
- **Offline on the phone.** The Android app can hold the entire catalogue in a
  file on the device — no account, no server, no network — and still give you the
  dashboard, search, filters, shelves, statuses and lending. Only the online
  lookups need a connection. See [*Android app*](#android-app-optional) below.
- **Multilingual UI.** English is the default; a Latin American Spanish
  (`es-419`) translation ships alongside. Switch language from the sidebar (web),
  the language picker (desktop) or Settings (Android) — the choice is
  remembered. Adding another language only means dropping an
  `app/locales/<code>.json` file (see below).
- **JSON API** (`/api/...`) and interactive API docs at `/docs`. The desktop app
  (remote mode) and the Android app are built on it.
- **Accounts & a shared catalog.** Username/password sign-in, with an admin
  panel to add or remove people. Everyone shares the same shelves, so the app
  can be hosted and reached from the web, desktop and phone.
- **Three front-ends, one library.** Browser, a native desktop window with
  local-database and remote modes, and a native Android app that can keep its
  own library on the phone (fully offline) or talk to a hosted one.
- **Share that library across devices, without a server.** Point the web admin
  page, the desktop app and the Android app at the same folder — Google Drive,
  Dropbox, Syncthing, a USB stick — and they exchange snapshots of the library:
  the newest edit of each row wins, deletions travel too, and nothing but whole
  files ever lands in the folder. See
  [*The same library on every device*](#the-same-library-on-every-device-optional-no-server).

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

## Deploy with Docker

A `Dockerfile` and a `docker-compose.yml` are included, so a hosted instance —
the web app *and* the JSON API the desktop and Android apps talk to — is:

```bash
docker compose up -d --build
docker compose run --rm web python -m app.cli create-admin alice
```

Then open <http://localhost:8000> and sign in. Your library lives in the
`bibliojules-data` volume, so rebuilding, replacing or upgrading the container
never touches it. The image runs as an unprivileged user and ships a
`HEALTHCHECK` that asks `/health`, which reports `503` when the database is
unreachable.

Worth choosing before you expose it (set them in `docker-compose.yml`, or in a
`.env` file next to it — compose reads `${VAR}` from there):

| Setting | Why |
| --- | --- |
| `APP_CONTACT` | Open Library asks callers to identify themselves |
| `COOKIE_SECURE=true` | send the session cookie over HTTPS only |
| `ENABLE_DOCS=false` | hide `/docs` on a public instance |
| `SESSION_TTL_DAYS` | how long a sign-in lasts (30 by default) |
| `SYNC_FILE` | the shared folder this instance exchanges snapshots through (see [*The same library on every device*](#the-same-library-on-every-device-optional-no-server)) |
| `SYNC_ON_START=true` | sync once when the app starts |

**HTTPS.** Terminate TLS in front of the app. The compose file has a
ready-to-uncomment **Caddy** service that fetches a certificate for you:

```bash
# 1. point library.example.com at this machine
# 2. uncomment the `caddy` service in docker-compose.yml
COOKIE_SECURE=true docker compose --profile tls up -d
```

Once that works, stop publishing port `8000` to the outside world — Caddy reaches
the app over the compose network. Any other reverse proxy (nginx, Traefik, one
you already run) is the same idea: forward to `web:8000` and set
`COOKIE_SECURE=true`.

**Backups.** Everything is in one volume, and SQLite has a safe online-backup
call, so no downtime is needed:

```bash
docker compose exec web python -c "import sqlite3; sqlite3.connect('/app/data/library.db').backup(sqlite3.connect('/app/data/backup.db'))"
docker compose cp web:/app/data/backup.db ./library-backup.db
```

**PostgreSQL or MariaDB instead of SQLite.** Set `DATABASE_URL` (e.g.
`postgresql+psycopg://user:password@db:5432/bibliojules`), add the matching
driver to `requirements.txt` (`psycopg[binary]` or `pymysql`), and add the
database service to the compose file. Nothing else in the codebase changes.

**Managing the instance.** The image ships the same admin CLI, so accounts can be
handled inside the container — `docker compose exec web python -m app.cli
list-users`, `set-password alice`, `create-user bob` — and Alembic is available
for schema changes (see *Evolving the schema with Alembic* for the one-time
`alembic stamp head` an existing library needs).

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

In **local mode** that dialog also has a *Shared library* group: point it at a
folder that syncs itself (Google Drive, Syncthing, a USB stick) and it keeps the
desktop, the browser and your phone on the same library — see
[*The same library on every device*](#the-same-library-on-every-device-optional-no-server).
**File → Sync library now…** (`Ctrl+Shift+S`) syncs on demand, and *Sync when
the app starts* does it at launch.

In **local mode**, because it opens the database file directly, `DATABASE_URL`
must resolve to the same file for both front-ends. The default
(`data/library.db`, absolute path) does; if you override `DATABASE_URL` in
`.env` with a *relative* path it will resolve against the working directory you
launch from, so prefer an absolute path there.

Either way the choice is written to `data/preferences.json`. In remote mode that
file also holds the sign-in token, so it is created with `0600` permissions —
keep it out of version control (`data/` already is).

---

## Android app (optional)

There is also a native **Android** app (Flutter) for the phone in your pocket.
It runs in either of two modes, picked on the sign-in screen and changed
whenever you like in **Settings**:

- **A library on this phone** — the *offline* mode. The whole collection lives in
  a single SQLite file in the app's own storage: no account, no server, no
  network, so the dashboard, search, filters, shelves, statuses and lending all
  work on a plane. Only **Discover** and ISBN lookups need a connection, and they
  ask Open Library and Google Books directly.
- **A server** — a thin client for a hosted library: no database of its own,
  every screen reads and writes through the JSON API, and a loan recorded here
  shows up in the browser immediately.

Switching modes keeps both: the file stays on the phone and the server token
stays in the keystore, so going back and forth needs no re-signing-in.

```bash
cd mobile
flutter pub get
flutter run --release      # or: flutter build apk --split-per-abi
```

Both modes have the same features as the web and desktop front-ends — dashboard,
searchable/filterable catalog, ISBN scanning, locations, statuses, lending,
loans history, online discovery — everything except user management, which
stays admin-only on the web.

### Moving a library between the phone and a server

The local section of **Settings** can **export** the phone's library and
**import** another one. Both go through Android's own file picker, so the
destination can be Downloads, a USB stick, or a **Google Drive** folder, with no
extra setup.

- **Export** writes one self-contained `.sqlite` file. Drop it into a hosted
  instance's `data/` directory and the server has the collection.
- **Import** takes a file — a phone export, or a server's `data/library.db`,
  accounts and all — and makes it this phone's library. Nothing is merged: the
  current library is replaced.

Export and import are a one-way move. To keep several devices in step instead —
the phone, the browser, the desktop app — point them all at one shared folder;
see [*The same library on every device*](#the-same-library-on-every-device-optional-no-server).

- **Emulator:** use `http://10.0.2.2:8000` as the backend URL to reach a server
  on the host machine.
- **Phone:** use the computer's LAN address (`http://192.168.1.20:8000`) or a
  hosted instance over **HTTPS**.
- **Release builds only allow HTTPS.** Cleartext HTTP is enabled for debug
  builds alone, so you can develop against a local server without weakening the
  real app.

Requires the **Flutter 3.47+ SDK** plus the Android SDK — no Python on the
phone. See [`mobile/README.md`](mobile/README.md) for details.

---

## The same library on every device (optional, no server)

A household usually has the browser open on the kitchen laptop, the desktop app
on the study computer and a phone in a pocket. All three can work on **one**
library without hosting anything, by leaving a **snapshot** of it in a folder
that already syncs itself — Google Drive, Dropbox, Syncthing, a NAS, a USB
stick; anything that copies a file.

Every device keeps its own live database and never opens the shared one in
place. A sync, in that order:

1. reads the snapshot in the folder and merges it into the local library;
2. writes a **new** snapshot back — but only when the local library has
   something the snapshot did not, so two idle devices cannot ping-pong files
   at each other;
3. keeps a timestamped backup of the local library (the last ten) first, so a
   bad merge is never final.

The snapshot is a normal BiblioJules database, openable by hand with any SQLite
tool. It is called `bibliojules-library.sqlite`, holds no accounts, and carries
a small `sync_meta` header (format, generation, snapshot id, and the device that
wrote it) so a half-copied file is refused instead of merged.

### What wins when two devices disagree

| Situation | Result |
| --- | --- |
| The same row was edited on both | The **newest edit** wins. Equal timestamps are settled by the row's internal id, so every device picks the same winner. |
| A row exists on both devices but was created independently | They are married on first contact: statuses by slug, authors and publishers by name, books by ISBN. |
| A book was deleted on one device and edited on the other | The newer of the two wins — an edit made *after* the delete brings the book back. |
| A shelf was deleted | The whole subtree goes with it; the books on those shelves are simply unshelved. |
| Both devices edited the same row since their last sync | The winner is kept and the loser is listed in the sync report, so nothing disappears silently. |

Loans travel with their book, statuses are never left dangling (books fall back
to *In library*), and every merge ends with a consistency check before it is
committed. If anything is wrong, the merge is rolled back and the library is
left exactly as it was.

### Setting it up

- **Web / server:** *Shared library* in the admin sidebar (`/admin/sync`), or
  `python -m app.cli sync --file "/path/to/folder"`. Add `SYNC_ON_START=true`
  to sync once at start-up.
- **Desktop:** *Settings → Shared library*, then **File → Sync library now…**
  (`Ctrl+Shift+S`) whenever you want. Tick *Sync when the app starts* to sync at
  launch.
- **Android:** *Settings → Shared library → Choose folder…*. The folder is chosen
  with Android's own picker (Drive is one of the places it offers) and the grant
  is remembered across restarts, so *Sync when the app starts* works unattended.

There is nothing to install on the folder's side and no account to create: the
shared folder is the only moving part, and it must be the **same folder** for
every device. Sync needs the SQLite backend (the default); PostgreSQL and MariaDB
are not supported.

Sync is not real time. Two devices agree once each of them has synced — on
start-up, or when you press the button.

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
│   ├── themes.json        # The eight themes: accents + surface ramps (shared)
│   ├── themes.py          # Loads them: defaults, validation, cookie name
│   ├── preferences.py     # Small JSON prefs store (UI language, accent, data source, token)
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
│   │   ├── sync.py        #   Snapshots + the cross-device merge
│   │   ├── tombstones.py  #   Deletions that have to travel
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
├── mobile/                # Flutter Android app (its own library, or a server)
│   ├── lib/
│   │   ├── main.dart      #   open the library + load prefs/catalogues, then run
│   │   └── src/
│   │       ├── app.dart   #   router + sign-in guard
│   │       ├── core/      #   api client, providers, models, l10n
│   │       ├── widgets/   #   app bar, book tile, form fields…
│   │       └── features/  #   one file per screen
│   ├── assets/locales/    #   copies of the server's catalogues
│   └── test/
├── Dockerfile             # Container image for the web app + JSON API
├── docker-compose.yml     # One-command deploy (library lives in a volume)
├── .dockerignore
├── migrations/            # Alembic migrations (schema evolution)
├── run.py                 # Web launcher
├── desktop.py             # Desktop launcher
├── dump_schema.py         # Dumps the server schema for the Android app's check
├── generate_theme_surfaces.py  # Recomputes each theme's surface ramp from its accent
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

A database the app created has every table but no `alembic_version` row, so the
first Alembic run must be told that the schema already *is* the initial
migration. Do this once per existing library:

```bash
alembic stamp head                                # once, on a database the app created
```

From then on (and on a brand-new database, where no stamp is needed):

```bash
alembic upgrade head                              # apply migrations
alembic revision --autogenerate -m "my change"    # after editing models
alembic upgrade head
```

Skipping the stamp is what produces `table authors already exists` on an
existing library.

> The Android app keeps its own copy of this schema
> (`mobile/lib/src/local/schema.dart`) so it can run with no server at all.
> After editing anything in `app/models/`, refresh the fixture it is checked
> against:
>
> ```bash
> python dump_schema.py
> ```
>
> `mobile/test/schema_parity_test.dart` then fails if the phone's copy has
> drifted — the two schemas have to stay interchangeable, since an exported
> file moves between them.

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

- **Theme:** `app/themes.json` holds eight palettes (red, orange, yellow,
  green, blue, purple, pink, gray), each with a ten-shade accent *and* an
  eleven-step surface ramp. The web app turns them into Tailwind's `brand` scale
  and a set of `--surface-*` variables at render time (see `_palette.html`).
  Tailwind itself is loaded from its Play CDN with a small config there (dark
  mode). Vendored/compiled Tailwind can be dropped in `app/static/css/` and the
  CDN script removed.
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

## Themes

Every client offers the same eight colours: red, orange, yellow, green, blue
(the default), purple, pink and gray. A theme is more than an accent — the
surfaces move with it, so a green library has deep green-black panels in dark
mode and a faintly mint page in light mode, while a pink one is wine-dark or
rose-tinted.

The palettes live once in `app/themes.json`. Each theme has:

- an **accent**, a Tailwind-style `50`…`900` scale, plus an `ink` for text drawn
  *on* the accent (white everywhere except yellow, where it is dark enough to
  read);
- a **surface ramp**: Tailwind slate's eleven steps with the accent's hue. Every
  step keeps slate's *lightness*, so body text, muted text and borders keep
  exactly the contrast they were designed with — the ramp only changes the
  colour cast. A `card` entry is the light-mode panel colour (near-white, tinted).

The web turns the ramp into CSS variables (`bg-slate-900` becomes a themed
panel), the desktop app builds its stylesheet and Qt palette from it, and Android
paints `scaffoldBackgroundColor`, cards, inputs, menus and borders with it.

The web and desktop apps read that file directly. Android cannot read the
server's files, so it keeps a mirror in `mobile/lib/src/theme.dart`;
`mobile/test/theme_sync_test.dart` fails if the mirror and the JSON ever
disagree.

The choice is per device, like the language:

- **Web:** the Settings page (`/settings`) stores the slug in a `color_theme`
  cookie.
- **Desktop:** File → Settings → Appearance saves it in `data/preferences.json`
  and re-colours the window as soon as you save.
- **Android:** Settings → Theme stores it in the app's preferences.

To add a colour, add the slug, label, ink and accent scale to
`app/themes.json`, run `python generate_theme_surfaces.py` to derive its surface
ramp, then mirror the theme in `theme.dart`. The pickers, the Tailwind scale,
the CSS variables and the desktop stylesheet all pick it up.

---

## Notes

- The app is meant to be shared by a household. It now ships with accounts, so
  it is safe to host — but do read *Hosting it safely* above before exposing it
  to the internet (HTTPS, `COOKIE_SECURE`, and don't leave `/docs` open).
- Everything is local: your data lives only in your database file (on the phone,
  in the library file in the app's private storage). The online lookups only
  ever send the ISBN you scan or the words you search for.
