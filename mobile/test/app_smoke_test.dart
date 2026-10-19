/// Renders the real widget tree against a fake server.
///
/// The unit tests cover the data layer and the translations; this one covers
/// the wiring between them — router, shell, providers, theme and layout — so a
/// mistake there (a missing override, an unbounded box) fails here instead of on
/// a phone.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bibliojules_mobile/src/app.dart';
import 'package:bibliojules_mobile/src/core/api_client.dart';
import 'package:bibliojules_mobile/src/core/l10n.dart';
import 'package:bibliojules_mobile/src/core/models/models.dart';
import 'package:bibliojules_mobile/src/core/prefs.dart';
import 'package:bibliojules_mobile/src/core/providers.dart';
import 'package:bibliojules_mobile/src/theme.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = 'https://shelf.example.org';

const _dune = {
  'id': 1,
  'title': 'Dune',
  'authors': ['Frank Herbert'],
  'isbn': '9780441013593',
  'published_date': '1965',
  'read_status': 'read',
  'score': 4.5,
  'saga': 'Dune',
  'saga_number': 1,
};

const _available = {
  'id': 1,
  'name': 'Available',
  'slug': 'available',
  'color': '#22c55e',
  'is_default': true,
};

/// A server that answers just enough for the screens to draw themselves.
class _FakeServer implements HttpClientAdapter {
  _FakeServer();

  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.path);
    final path = options.path;
    Object? body;
    if (path == '/api/books') {
      body = {
        'items': [_dune],
      };
    } else if (path == '/api/books/1') {
      body = _dune;
    } else if (path == '/api/books/1/loans') {
      body = <Object>[];
    } else if (path == '/api/statuses') {
      body = [_available];
    } else if (path == '/api/sagas') {
      body = ['Dune'];
    } else if (path == '/api/authors') {
      body = [
        {'id': 1, 'name': 'Frank Herbert'},
      ];
    } else if (path == '/api/publishers') {
      body = [
        {'id': 1, 'name': 'Ace'},
      ];
    } else if (path == '/api/locations') {
      body = <Object>[];
    } else if (path == '/api/dashboard') {
      body = {
        'stats': {'total': 1, 'authors': 1, 'publishers': 1, 'loans': 0, 'wishlist': 0},
        'status_counts': [
          {'status': _available, 'count': 1},
        ],
        'recent': [_dune],
        'active_loans': <Object>[],
      };
    }
    return ResponseBody.fromString(
      json.encode(body ?? {'detail': 'Not found.'}),
      body == null ? 404 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Boots the app's start-up graph (preferences, catalogues, client, session)
/// the same way ``main()`` does, but against [_FakeServer].
///
/// The catalogues come from the bundled assets, so this also proves the
/// ``assets/locales/`` declaration in pubspec.yaml still points at real files.
/// Reading an asset needs real async I/O, hence [WidgetTester.runAsync].
Future<ProviderContainer> _boot(
  WidgetTester tester, {
  required bool signedIn,
  required _FakeServer server,
}) async {
  SharedPreferences.setMockInitialValues({
    'backend_url': _server,
    'account_username': 'ana',
  });
  final loaded = await tester.runAsync(() async {
    final prefs = await AppPrefs.load();
    final catalog = await CatalogCache.preload();
    return (prefs, catalog);
  });
  final (prefs, catalog) = loaded!;
  final dio = Dio()..httpClientAdapter = server;
  final api = ApiClient(baseUrl: _server, token: signedIn ? 'bj_test' : null, dio: dio);
  return ProviderContainer.test(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      catalogCacheProvider.overrideWithValue(catalog),
      apiClientProvider.overrideWithValue(api),
      bootSessionProvider.overrideWithValue(
        SessionState(
          baseUrl: _server,
          token: signedIn ? 'bj_test' : null,
          user: signedIn
              ? const User(id: 1, username: 'ana', role: 'admin', isAdmin: true)
              : null,
        ),
      ),
    ],
  );
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const BiblioJulesApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('signed out, the app asks which library to use', (tester) async {
    final container = await _boot(tester, signedIn: false, server: _FakeServer());
    await _pumpApp(tester, container);

    expect(find.text('Sign in to your library'), findsOneWidget);
    expect(find.text('Backend URL'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    // The address saved in preferences is prefilled.
    expect(find.text(_server), findsOneWidget);
    // No bottom navigation until there is a session.
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('signed in, the catalog lists what the server has', (tester) async {
    final server = _FakeServer();
    final container = await _boot(tester, signedIn: true, server: server);
    await _pumpApp(tester, container);

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Frank Herbert'), findsOneWidget);
    expect(server.requested, contains('/api/books'));
  });

  testWidgets('the bottom bar reaches every section', (tester) async {
    final server = _FakeServer();
    final container = await _boot(tester, signedIn: true, server: server);
    await _pumpApp(tester, container);

    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pumpAndSettle();
    expect(find.text('RECENTLY ADDED'), findsOneWidget);
    expect(find.text('BY STATUS'), findsOneWidget);
    expect(server.requested, contains('/api/dashboard'));

    await tester.tap(find.byIcon(Icons.warehouse_outlined));
    await tester.pumpAndSettle();
    expect(find.text('No locations yet.'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.label_outline));
    await tester.pumpAndSettle();
    expect(find.text('Available'), findsWidgets);

    await tester.tap(find.byIcon(Icons.menu_book_outlined));
    await tester.pumpAndSettle();
    // The dashboard branch stays mounted in the shell's stack, so its recent
    // list and the catalogue both show "Dune" now.
    expect(find.text('Dune'), findsWidgets);
  });

  testWidgets('a book opens its detail page', (tester) async {
    final container = await _boot(tester, signedIn: true, server: _FakeServer());
    await _pumpApp(tester, container);

    await tester.tap(find.text('Dune'));
    await tester.pumpAndSettle();

    expect(find.text('ISBN'), findsOneWidget);
    expect(find.text('9780441013593'), findsOneWidget);
    expect(find.text('Read status'), findsOneWidget);
    expect(find.text('LOAN HISTORY'), findsOneWidget);
    expect(find.text('Never lent out.'), findsOneWidget);
  });

  testWidgets('the language switcher re-renders the whole app in Spanish', (tester) async {
    final container = await _boot(tester, signedIn: true, server: _FakeServer());
    await _pumpApp(tester, container);

    await container.read(languageProvider.notifier).set('es-419');
    await tester.pumpAndSettle();

    // The bottom bar, the app bar and the book tiles all read from the shared
    // catalogue, so one switch relabels the whole tree.
    expect(find.text('Descubrir'), findsOneWidget);
    expect(find.text('Ubicaciones'), findsOneWidget);
    expect(find.text('Catálogo'), findsWidgets);
    expect(find.text('Sign in to your library'), findsNothing);
  });

  testWidgets('the settings screen re-themes the whole app', (tester) async {
    final container = await _boot(tester, signedIn: true, server: _FakeServer());
    await _pumpApp(tester, container);

    ThemeData appTheme() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;

    // A fresh install is blue.
    expect(container.read(colorThemeProvider), 'blue');
    expect(appTheme().colorScheme.primary, themeBySlug('blue').accent);

    // Open the configuration screen — the overflow menu pushes this same route.
    container.read(routerProvider).push('/settings');
    await tester.pumpAndSettle();

    // The theme picker sits near the bottom of the settings list.
    final themeHeader = find.text('THEME');
    await tester.dragUntilVisible(themeHeader, find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(themeHeader, findsOneWidget);

    final pink = find.text('Pink');
    await tester.dragUntilVisible(pink, find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(pink);
    await tester.pumpAndSettle();

    // The provider, the MaterialApp and the saved preference all follow.
    expect(container.read(colorThemeProvider), 'pink');
    expect(container.read(paletteProvider).slug, 'pink');
    expect(appTheme().colorScheme.primary, themeBySlug('pink').accent);
    expect(appTheme().colorScheme.onPrimary, themeBySlug('pink').ink);
    expect(container.read(prefsProvider).colorTheme, 'pink');
  });

  testWidgets('a yellow theme draws dark text on its buttons', (tester) async {
    final container = await _boot(tester, signedIn: true, server: _FakeServer());
    await _pumpApp(tester, container);

    await container.read(colorThemeProvider.notifier).set('yellow');
    await tester.pumpAndSettle();

    final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    expect(theme.colorScheme.primary, themeBySlug('yellow').accent);
    expect(theme.colorScheme.onPrimary, themeBySlug('yellow').ink);
    expect(theme.filledButtonTheme.style!.foregroundColor!.resolve({}), themeBySlug('yellow').ink);
  });
}
