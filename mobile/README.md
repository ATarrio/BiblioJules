# BiblioJules for Android

The **Flutter** app that turns a hosted BiblioJules library into a phone app.

It is a thin client: it keeps **no database and no copies of your books**. Every
screen reads and writes through the same JSON API the web and desktop apps use,
so what you see on the phone is the same collection everyone else sees — and a
loan you record here shows up in the browser immediately.

```
📱 app  ──HTTPS──▶  🌐 BiblioJules server  ──▶  🗄️ database
                     (web app + JSON API)
```

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
- **Settings** — server address, account, language, sign out.

Everything except user management (which stays admin-only, on the web) works
here, exactly as in the browser.

---

## Requirements

- **Flutter 3.47+** (Dart 3.13+) — <https://docs.flutter.dev/get-started/install>
- **Android SDK** with a device or emulator (the build targets Android 7.0+,
  `minSdk 24`).
- A **running BiblioJules server** to point the app at (see the main README).

No database files, no `.env`, no Python — none of that is needed on the phone.

---

## Running it

```bash
cd mobile
flutter pub get
flutter run                 # debug build onto the connected device/emulator
```

The first build downloads the Android Gradle plugin and Kotlin, so it takes a
few minutes; afterwards it is incremental.

To produce an installable APK:

```bash
flutter build apk            # release, needs a signing config
flutter build apk --debug    # a debug APK, no signing needed
```

The output lands in `build/app/outputs/flutter-apk/`.

### Pointing it at your server

Open the app; the sign-in screen asks for a **Backend URL**, a username and a
password. The same three fields live in **Settings** afterwards.

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
arrive in the language chosen in Settings.

---

## Tests

```bash
cd mobile
flutter analyze
flutter test
```

The suite has four layers:

- `catalog_coverage_test.dart` — every label has a translation.
- `locale_sync_test.dart` — the bundled catalogue matches the server's.
- `unit tests` — the api client (against a fake adapter), the models, the
  helpers and the translation lookup.
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
│   ├── main.dart              # load prefs + catalogues + token, then run
│   └── src/
│       ├── app.dart           # MaterialApp.router, routes, sign-in guard
│       ├── theme.dart         # the same slate/brand palette as the desktop app
│       ├── core/
│       │   ├── api_client.dart    # every endpoint, in one place
│       │   ├── providers.dart     # session, query and cached server data
│       │   ├── models/            # the server's JSON shapes
│       │   ├── l10n.dart          # catalogue lookup by English source
│       │   └── prefs.dart         # server URL, language, last sort
│       ├── widgets/           # app bar, book tile, cover, form fields…
│       └── features/          # one file per screen
├── assets/locales/            # a copy of the server's catalogues
└── test/
```
