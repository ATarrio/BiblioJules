/// BiblioJules for Android.
///
/// The app can read the library from two places: a hosted BiblioJules server
/// (over its JSON API) or a SQLite file on the phone itself. Everything that
/// needs a connection to resolve (preferences, the string catalogues, the
/// stored token, and the local library file) is loaded here, before the first
/// frame, so the rest of the app can read it synchronously.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'src/app.dart';
import 'src/core/api_client.dart';
import 'src/core/api_exception.dart';
import 'src/core/l10n.dart';
import 'src/core/models/user.dart';
import 'src/core/prefs.dart';
import 'src/core/providers.dart';
import 'src/core/secure_store.dart';
import 'src/local/library_files.dart';
import 'src/local/local_repo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dates are rendered in the user's language by ``intl``.
  await initializeDateFormatting();

  final prefs = await AppPrefs.load();
  final catalogs = await CatalogCache.preload();

  final store = SecureStore();
  final baseUrl = normalizeBaseUrl(prefs.baseUrl ?? '');
  final api = ApiClient(baseUrl: baseUrl);
  // From the very first request, ask the server for messages in the app's
  // language, so even a rejection at sign-in reads naturally.
  api.setLanguage(prefs.effectiveLanguage);

  final local = prefs.mode == LibraryMode.local;
  final libraryName = prefs.localLibraryName ?? kDefaultLibraryName;

  // The on-device store, ready to be used (and used right away in local mode).
  final repo = LocalRepo();
  repo.useMessages(catalogs.forLanguage(prefs.effectiveLanguage));

  var token = await store.readToken();
  User? user;
  String? notice;

  if (token != null && baseUrl.isEmpty) {
    // A token without a server address is meaningless.
    await store.writeToken(null);
    token = null;
  } else if (token != null && !local) {
    api.setToken(token);
    try {
      // Confirm the stored token is still good, so a revoked session lands on
      // the sign-in screen instead of a wall of 401s.
      user = await api.me();
    } on ApiAuthException catch (error) {
      await store.writeToken(null);
      token = null;
      notice = error.message;
    } on ApiException {
      // Server unreachable right now: stay signed in and let screens retry.
      token = api.hasToken ? token : null;
    }
  } else if (token != null) {
    // Local mode: keep the token (so switching back to the server needs no new
    // sign-in) but do not ask the server about it now.
    api.setToken(token);
  }

  var session = SessionState(
    baseUrl: baseUrl,
    token: token,
    user: user,
    notice: notice,
    isLocal: local,
    localLibraryName: local ? libraryName : null,
  );

  if (local) {
    try {
      // Open the file now: a damaged library should be reported on the sign-in
      // screen, not as a broken catalog a moment later.
      await repo.open(libraryName);
    } on Object catch (error) {
      session = SessionState(baseUrl: baseUrl, token: token, notice: describeLocalError(error));
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        catalogCacheProvider.overrideWithValue(catalogs),
        apiClientProvider.overrideWithValue(api),
        localRepoProvider.overrideWithValue(repo),
        bootSessionProvider.overrideWithValue(session),
      ],
      child: const BiblioJulesApp(),
    ),
  );
}
