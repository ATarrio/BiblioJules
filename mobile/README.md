# BiblioJules for Android

The **Flutter** app that puts BiblioJules in your pocket.

It runs in one of two modes, picked on the sign-in screen and changed whenever
you like in **Settings**:

```
📱 a library on this phone  ──▶  🗄️ one SQLite file, private to the app
     (offline: no account, no server)

📱 a server                ──HTTPS──▶  🌐 BiblioJules server  ──▶  🗄️ database
     (the web app + JSON API)
```

- **A library on this phone** — the *offline* mode: the whole collection lives in
  a single SQLite file in the app's own storage. No account, no server, no
  network: dashboard, search, filters, shelves, statuses and lending all work on
  a plane. Only **Discover** and ISBN lookups need a connection, and they ask
  Open Library and Google Books directly.
- **A server** — a thin client for a hosted library: no database of its own,
  every screen reads and writes through the same JSON API the web and desktop
  apps use, so a loan you record here shows up in the browser immediately.

Switching modes keeps both: the file stays on the phone and the server token
stays in the keystore, so going back and forth needs no re-signing-in.

---

## What it does

- **Dashboard** — headline counters, books per status, what's currently lent out,
  recent additions.
- **Catalog** — search, filter (status, shelf, saga, read status, on loan),
  sortable, with pull-to-refresh.
- **Discover** — search Open Library / Google Books, and add a book by ISBN.
- **Scan** — read an ISBN barcode with the camera and prefill the book form.
- **Locations** and **Statuses** — the same nested shelf tree and custom labels
  as the web app.
- **Books** — add/edit/delete, lend and return, with loan history.
- **Settings** — which library to use, rename, export, import, language, sign out.

Everything except user management (which stays admin-only, on the web) works
here, exactly as in the browser.

---

## Requirements

- **Flutter 3.47+** (Dart 3.13+) — <https://docs.flutter.dev/get-started/install>
- **Android SDK** with a device or emulator (the build targets Android 7.0+,
  `minSdk 24`).
- A **running BiblioJules server** — only if you want the server mode.

No Python and no `.env` on the phone.

---

## Running it

```bash
cd mobile
flutter pub get
flutter run                 # debug build onto the connected device/emulator
```

The first build downloads the Android Gradle plugin and Kotlin, so it takes a
few minutes; afterwards it is incremental.

To produce installable APKs:

```bash
flutter build apk --split-per-abi --release   # needs a signing config
flutter build apk --split-per-abi --debug     # no signing needed
```

`--split-per-abi` writes one APK per architecture — a third the size of the
universal build, and the right way to hand the app to a phone. The output lands
in `build/app/outputs/flutter-apk/`.

Release builds are minified by R8, which Flutter turns on for them. Anything a
plugin only reaches *by name* has to be kept explicitly, so
`android/app/proguard-rules.pro` holds those keep rules. Today they are the
Kotlin runtime classes that the JNI bindings of `shared_preferences_android` and
`path_provider_android` look up: without them R8 renames the classes, the
descriptors the Dart side calls stop existing, and the app dies before the first
frame — an endless black screen that only ever happens in release
(<https://github.com/flutter/flutter/issues/194649>). The rules can be dropped
once `jni` keeps those classes itself.

### Using a library on this phone

The phone works **offline** in this mode: nothing here needs a network, an
account, or a server anywhere.

On the sign-in screen, tap **Use a library on this phone** and give it a name.
That is the whole setup: the app creates the file, seeds the six standard
statuses (`In library`, `Lent out`, …) and you are in the catalog.

The file lives at:

```
<app documents>/libraries/<slug>.sqlite
```

The slug comes from the name, so `Mi biblioteca` becomes `mi-biblioteca.sqlite`.
That directory is private to the app, which is why local mode needs **no storage
permission at all** — getting a copy *out* is a separate, deliberate step
(export, below).

The library can be renamed in **Settings**; the file follows the name.

### Pointing it at your server

The sign-in screen (and **Settings**) also ask for a **Backend URL**, a username
and a password.

| Where the server runs | What to type |
| --- | --- |
| Android emulator, server on this computer | `http://10.0.2.2:8000` |
| A phone on the same Wi-Fi | `http://192.168.1.20:8000` (your computer's LAN IP) |
| A hosted instance | `https://library.example.com` |

Typing a bare hostname works: the app adds `http://` for loopback, private and
`10.0.2.2` addresses, and `https://` for anything public.

You need an account on that server. The first administrator is created from the
command line on the server (see the main README):

```bash
python -m app.cli create-admin <username> --password <password>
```

The token the app gets back is stored in the **Android keystore**
(`flutter_secure_storage`), not in plain preferences, and the server can revoke
it. Sessions last about 30 days; signing out forgets the token on the device.

### HTTPS

Release builds refuse plain HTTP: `android:usesCleartextTraffic="false"` is set
in `android/app/src/main/AndroidManifest.xml`, and only the **debug** manifest
(`src/debug/...`) allows cleartext so you can talk to a development server over
the LAN. Put the server behind HTTPS (a reverse proxy) for real use.

---

## Moving a library in and out

The local section of **Settings** has **Export…** and **Import…**. Both go
through Android's own file picker, so the other end can be Downloads, a USB
stick, or a **Google Drive** folder — Drive appears in the picker as just another
place, and the app needs no Drive code of its own.

**Export** writes one self-contained `.sqlite` file, named
`<slug>-YYYY-MM-DD.sqlite`. A plain file copy would not do — the newest writes
are still in the SQLite write-ahead log — so the log is folded back into the
file (`PRAGMA wal_checkpoint(TRUNCATE)`) and then `VACUUM INTO` writes a compact
copy. Old Android builds, where SQLite predates `VACUUM INTO`, fall back to
copying the checkpointed file.

**Import** takes a file and makes it this phone's library. It is validated first:

- it must be a real SQLite database, with every table the app needs;
- it must not claim a schema version newer than this build understands;
- extra tables are fine — a server's `data/library.db` carries `users` and
  `tokens` and has never been stamped with a schema version, so both are
  handled. The version is stamped on import, because sqflite treats
  `user_version = 0` as "brand new" and would otherwise try to create tables
  that are already there.

The swap is written next to the current file and only moved into place once the
new one is complete, so a bad file (or a full disk) leaves the library as it was.
Nothing is merged: importing replaces the current library, and the confirmation
says so.

There is deliberately **no sync**. Export and import are the transfer path,
because two copies of a library that quietly drift apart are worse than an
explicit move. A file exported here can be dropped into a hosted instance's
`data/` directory, and a server's `data/library.db` can be imported here.

### How the picker is wired

Android never hands an app a path to where the user picked something: the answer
is a `content://` URI owned by another app. So the byte-shuffling is done in
Kotlin — `android/app/src/main/kotlin/com/bibliojules/mobile/MainActivity.kt`,
which sets up an `ACTION_CREATE_DOCUMENT` / `ACTION_OPEN_DOCUMENT` intent and
copies through the `ContentResolver` — while every decision stays in Dart
(`lib/src/local/transfer.dart`). There is no plugin dependency for this.
`FlutterActivity` extends plain `Activity`, not `ComponentActivity`, so the
modern `registerForActivityResult` is unavailable and `startActivityForResult`
does the job.

---

## The local database

Local mode is not a stripped-down copy of the app. It is the second
implementation of the same interface the HTTP client implements
(`core/library_repo.dart`), so every screen is written against one contract and
cannot tell the modes apart:

- **Reads return API-shaped JSON maps**, built by `local/converters.dart` and
  parsed by the very same `Book.fromJson` the HTTP client uses. A serialisation
  bug therefore shows up in both modes, and no widget or model knows about
  SQLite.
- **Errors are `ApiException`s**, so the screens have a single error path.
- **The schema is the server's schema**, table for table and column for column,
  minus `users` and `tokens`. See below.
- **`NULLS LAST` is emulated** as `ORDER BY (col IS NULL), col`, because SQLite
  only learned `NULLS LAST` in 3.30 and Android 10 ships 3.28. A phone must not
  sort differently from a laptop.

`test/schema_parity_test.dart` is the guard for the last point. It parses the
`CREATE TABLE` statements in `lib/src/local/schema.dart` and compares the tables
and columns against `test/fixtures/server_schema.json`, which is generated from
the server's SQLAlchemy metadata:

```bash
cd ..                    # the repository root
python dump_schema.py    # after editing anything in app/models/
```

Add a column to a model without copying it into `schema.dart` and the mobile
suite fails.

---

## Translations

The app reuses the web app's catalogues verbatim. `app/locales/es-419.json` is
the source of truth and `assets/locales/es-419.json` is the copy that ships in
the APK. Strings are looked up by their **English source text** — the same
convention as the Python `_()` helper — so there is nothing to compile.

After changing the catalogue on the server side, copy it across:

```bash
cp ../app/locales/es-419.json assets/locales/
```

`test/locale_sync_test.dart` fails if the copy drifts, and
`test/catalog_coverage_test.dart` fails if a screen shows a string the catalogue
does not have.

The app also sends `Accept-Language`, so error messages the *server* produces
arrive in the language chosen in Settings. In local mode the messages come from
the phone's copy of the catalogue instead.

---

## Tests

```bash
cd mobile
flutter analyze
flutter test
```

The suite has several layers:

- `catalog_coverage_test.dart` — every label has a translation.
- `locale_sync_test.dart` — the bundled catalogue matches the server's.
- `unit tests` — the api client (against a fake adapter), the models, the
  helpers and the translation lookup.
- `local_repo_test.dart` — the local store, against real SQLite (via
  `sqflite_common_ffi`): seeding, the full field round trip, vocabulary rules,
  filtering, sorting, loans, the location tree, statuses, statistics.
- `library_transfer_test.dart` — export and import, including a server-shaped
  database and, when the working copy is present, the real `data/library.db`.
- `lookup_test.dart` — the direct Open Library / Google Books lookup local mode
  uses, against a fake adapter: the provider order, what wins in a merge, and
  what happens when one of them is down.
- `local_mode_test.dart` — the app itself running on a local library: no
  sign-in, the local book in the catalog, the settings screen, an export from
  the button through to the channel.
- `schema_parity_test.dart` — the schema, against the server's.
- `app_smoke_test.dart` — renders the real widget tree against a fake server:
  sign-in screen, catalog, dashboard, book detail, language switch.
- `api_integration_test.dart` — boots the **real** FastAPI server (from the
  repository this package sits in) on a throwaway SQLite database and drives it
  through the app's own `ApiClient`: sign in, add a book, lend and return it,
  filters, locations, statuses, sign out. It skips itself when `../.venv` is not
  present.

---

## Layout

```
mobile/
├── lib/
│   ├── main.dart              # load prefs + catalogues, open the local library, then run
│   └── src/
│       ├── app.dart           # MaterialApp.router, routes, sign-in guard
│       ├── theme.dart         # the same slate/brand palette as the desktop app
│       ├── core/
│       │   ├── api_client.dart    # every endpoint, in one place
│       │   ├── library_repo.dart  # the interface both modes implement
│       │   ├── providers.dart     # session, query and cached data (either source)
│       │   ├── models/            # the server's JSON shapes
│       │   ├── l10n.dart          # catalogue lookup by English source
│       │   └── prefs.dart         # mode, library name, server URL, language, sort
│       ├── local/
│       │   ├── schema.dart        # the server's schema, copied column for column
│       │   ├── local_repo.dart    # LibraryRepo on SQLite
│       │   ├── converters.dart    # rows → the API's JSON
│       │   ├── library_files.dart # where a library file lives, and its name
│       │   ├── transfer.dart      # export/import over the system file picker
│       │   └── lookup.dart        # Open Library + Google Books, directly
│       ├── widgets/           # app bar, book tile, cover, form fields…
│       └── features/          # one file per screen
├── android/app/src/main/kotlin/com/bibliojules/mobile/
│   └── MainActivity.kt        # the file-picker channel
├── assets/locales/            # a copy of the server's catalogues
└── test/                      # see above; test/fixtures/ holds the server schema
```
