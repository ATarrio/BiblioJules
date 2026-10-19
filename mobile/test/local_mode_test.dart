/// Drives the real widget tree against an on-device library.
///
/// Where ``app_smoke_test.dart`` checks the wiring against a fake server, this
/// checks the *other* mode end to end: no server at all, the catalogue coming
/// straight out of a SQLite file, and the sign-in screen offering a way in for
/// somebody who does not host anything.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/app.dart';
import 'package:bibliojules_mobile/src/core/api_client.dart';
import 'package:bibliojules_mobile/src/core/l10n.dart';
import 'package:bibliojules_mobile/src/core/prefs.dart';
import 'package:bibliojules_mobile/src/core/providers.dart';
import 'package:bibliojules_mobile/src/local/local_repo.dart';
import 'package:bibliojules_mobile/src/local/transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Boot the app with [repo] as the catalogue and no server to talk to.
Future<ProviderContainer> _bootLocal(
  WidgetTester tester,
  LocalRepo repo, {
  required bool signedIn,
  Directory? scratch,
}) async {
  SharedPreferences.setMockInitialValues({'library_mode': 'local'});
  final loaded = await tester.runAsync(() async {
    final prefs = await AppPrefs.load();
    final catalog = await CatalogCache.preload();
    return (prefs, catalog);
  });
  final (prefs, catalog) = loaded!;
  return ProviderContainer.test(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      catalogCacheProvider.overrideWithValue(catalog),
      // Present but unused: nothing in local mode should reach the network.
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: '')),
      localRepoProvider.overrideWithValue(repo),
      // ``path_provider`` has no platform channel under ``flutter test``, so the
      // transfer writes its scratch files to a directory we hand it.
      if (scratch != null)
        libraryTransferProvider.overrideWithValue(
          LibraryTransfer(repo: repo, scratchDirectory: () async => scratch),
        ),
      bootSessionProvider.overrideWithValue(
        signedIn
            ? const SessionState(isLocal: true, localLibraryName: 'My library')
            : const SessionState(),
      ),
    ],
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // The widget tree is pumped under fake async, where a background isolate's
    // replies never arrive; running SQLite in this isolate keeps every step
    // inside a `pumpAndSettle`.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Directory dir;
  late Directory scratch;
  late LocalRepo repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bibliojules_mode');
    scratch = await Directory.systemTemp.createTemp('bibliojules_mode_scratch');
    repo = LocalRepo(documentsDirectory: () async => dir);
    await repo.open('My library');
  });

  tearDown(() async {
    await repo.dispose();
    for (final folder in [dir, scratch]) {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    }
  });

  testWidgets('the catalog shows what the local file holds', (tester) async {
    await tester.runAsync(() async {
      await repo.createBook({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'read_status': 'read',
      });
    });
    final container = await _bootLocal(tester, repo, signedIn: true);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BiblioJulesApp()),
    );
    await tester.pumpAndSettle();

    // Straight to the catalog: a local library needs no sign-in.
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Frank Herbert'), findsOneWidget);
  });

  testWidgets('the dashboard counts what is in the local file', (tester) async {
    await tester.runAsync(() async {
      await repo.createBook({'title': 'Dune'});
      await repo.createBook({'title': 'Ubik'});
    });
    final container = await _bootLocal(tester, repo, signedIn: true);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BiblioJulesApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dashboard'));
    await tester.pumpAndSettle();

    expect(find.text('BY STATUS'), findsOneWidget);
    // The recent list sits below the fold of the test surface, so check the
    // data the screen was handed rather than the pixels.
    final data = await tester.runAsync(
      () => container.read(dashboardProvider.future),
    );
    expect(data!.stats.total, 2);
    expect(data.recent.map((book) => book.title), containsAll(['Dune', 'Ubik']));
  });

  testWidgets('a book saved from the app lands in the local file',
      (tester) async {
    final container = await _bootLocal(tester, repo, signedIn: true);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BiblioJulesApp()),
    );
    await tester.pumpAndSettle();

    // Go to Discover-free path: the catalog's add button opens the form.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Neuromancer');
    // The form's Save lives in the app bar; the one at the bottom of the form
    // is below the fold and therefore never built.
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    // The write reaches the file, not a server.
    final stored = await tester.runAsync(() => repo.listBooks());
    expect(stored!.map((book) => book.title), contains('Neuromancer'));
  });

  testWidgets('signed out, the app offers to keep the library on the phone',
      (tester) async {
    final container = await _bootLocal(tester, repo, signedIn: false);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BiblioJulesApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Use a library on this phone'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('the settings screen names the library and offers a rename',
      (tester) async {
    final container = await _bootLocal(tester, repo, signedIn: true);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BiblioJulesApp()),
    );
    await tester.pumpAndSettle();
    // Settings lives behind the overflow menu.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('My library'), findsOneWidget);
    expect(find.text('Stored on this device only'), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets('the settings screen exports the library to the file picker',
      (tester) async {
    await tester.runAsync(() async => repo.createBook({'title': 'Dune'}));
    final container = await _bootLocal(tester, repo, signedIn: true, scratch: scratch);
    addTearDown(container.dispose);

    // Stand in for Android: accept what Dart offers and say what was saved.
    Map<Object?, Object?>? exportCall;
    const channel = MethodChannel(kFilesChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'export');
      exportCall = call.arguments as Map<Object?, Object?>;
      return 'Dune library.sqlite';
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const BiblioJulesApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export…'));
    await tester.pumpAndSettle();

    // The usual button → provider → repo → channel path, so this is the whole
    // feature: a real snapshot of a real library went past the picker.
    expect(exportCall, isNotNull);
    expect(exportCall!['name'], startsWith('my-library-'));
    expect(find.text('Library exported as Dune library.sqlite.'), findsOneWidget);
    // Nothing is left behind in the scratch directory.
    expect(scratch.listSync(), isEmpty);
  });
}
