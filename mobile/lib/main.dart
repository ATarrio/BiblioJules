/// BiblioJules for Android.
///
/// A thin client for a hosted BiblioJules library: it keeps no database of its
/// own, it just talks to the web app's JSON API over the network. Everything
/// that needs a connection to resolve (preferences, the string catalogues, the
/// stored token) is loaded here, before the first frame, so the rest of the app
/// can read it synchronously.
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

  var token = await store.readToken();
  User? user;
  String? notice;

  if (token != null && baseUrl.isEmpty) {
    // A token without a server address is meaningless.
    await store.writeToken(null);
    token = null;
  } else if (token != null) {
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
  }

  runApp(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        catalogCacheProvider.overrideWithValue(catalogs),
        apiClientProvider.overrideWithValue(api),
        bootSessionProvider.overrideWithValue(
          SessionState(baseUrl: baseUrl, token: token, user: user, notice: notice),
        ),
      ],
      child: const BiblioJulesApp(),
    ),
  );
}
