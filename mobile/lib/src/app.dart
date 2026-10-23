/// The MaterialApp, and the router that guards it behind the sign-in screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/l10n.dart';
import 'core/models/models.dart';
import 'core/providers.dart';
import 'features/about_screen.dart';
import 'features/book/book_detail_screen.dart';
import 'features/book/book_form_screen.dart';
import 'features/book/book_loan_screen.dart';
import 'features/catalog_screen.dart';
import 'features/dashboard_screen.dart';
import 'features/discover_screen.dart';
import 'features/home_shell.dart';
import 'features/locations_screen.dart';
import 'features/login_screen.dart';
import 'features/reading/import_screen.dart';
import 'features/reading/reading_screen.dart';
import 'features/scan_screen.dart';
import 'features/settings_screen.dart';
import 'features/statuses_screen.dart';
import 'theme.dart';
import 'widgets/l10n_scope.dart';

int _intParam(GoRouterState state, String name) =>
    int.tryParse(state.pathParameters[name] ?? '') ?? 0;

final routerProvider = Provider<GoRouter>((ref) {
  // go_router only re-runs ``redirect`` when a Listenable it owns changes, so
  // we ping one whenever the session (sign-in/sign-out, new server) changes.
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (previous, next) {
    if (previous?.token != next.token ||
        previous?.baseUrl != next.baseUrl ||
        previous?.isLocal != next.isLocal ||
        previous?.localLibraryName != next.localLibraryName) {
      refresh.value++;
    }
  });
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/catalog',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final atLogin = state.matchedLocation == '/login';
      if (!session.signedIn) return atLogin ? null : '/login';
      return atLogin ? '/catalog' : null;
    },
    routes: [
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/about',
        name: 'about',
        builder: (context, state) => const AboutScreen(),
      ),
      GoRoute(
        path: '/scan',
        name: 'scan',
        builder: (context, state) => const ScanScreen(),
      ),
      GoRoute(
        path: '/import-csv',
        name: 'import-csv',
        builder: (context, state) => const ImportScreen(),
      ),
      GoRoute(
        path: '/book/new',
        name: 'book-new',
        builder: (context, state) => BookFormScreen(
          initialIsbn: state.uri.queryParameters['isbn'],
          initialData: state.extra is SearchResult
              ? state.extra as SearchResult
              : null,
        ),
      ),
      GoRoute(
        path: '/book/:id',
        name: 'book',
        builder: (context, state) =>
            BookDetailScreen(bookId: _intParam(state, 'id')),
        routes: [
          GoRoute(
            path: 'edit',
            name: 'book-edit',
            builder: (context, state) =>
                BookFormScreen(bookId: _intParam(state, 'id')),
          ),
          GoRoute(
            path: 'loan',
            name: 'book-loan',
            builder: (context, state) =>
                BookLoanScreen(bookId: _intParam(state, 'id')),
          ),
        ],
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                name: 'dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/catalog',
                name: 'catalog',
                builder: (context, state) => const CatalogScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/discover',
                name: 'discover',
                builder: (context, state) => const DiscoverScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/reading',
                name: 'reading',
                builder: (context, state) => const ReadingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/locations',
                name: 'locations',
                builder: (context, state) => const LocationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/statuses',
                name: 'statuses',
                builder: (context, state) => const StatusesScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class BiblioJulesApp extends ConsumerStatefulWidget {
  const BiblioJulesApp({super.key});

  @override
  ConsumerState<BiblioJulesApp> createState() => _BiblioJulesAppState();
}

class _BiblioJulesAppState extends ConsumerState<BiblioJulesApp> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so the screens are up and the merge can close and
    // reopen the database underneath them.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOnStart());
  }

  /// One sync per launch, when the user asked for it.
  ///
  /// A failure is only logged: a phone that has been offline, or a folder whose
  /// grant has lapsed, must never stop the library from opening. The user can
  /// retry from Settings, where the real message is shown.
  Future<void> _syncOnStart() async {
    final prefs = ref.read(prefsProvider);
    if (!prefs.syncOnStart || prefs.syncFolderUri == null) return;
    if (!ref.read(sessionProvider).isLocal) return;
    try {
      await ref.read(librarySyncProvider)?.run();
      if (!mounted) return;
      refreshEverything(ref);
    } on Object catch (error) {
      debugPrint('Shared library sync at start-up failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final palette = ref.watch(paletteProvider);
    final router = ref.watch(routerProvider);
    return L10nScope(
      l10n: l10n,
      child: MaterialApp.router(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(palette),
        routerConfig: router,
        locale: localeFor(l10n.language),
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
  }
}
