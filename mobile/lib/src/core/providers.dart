/// Application-wide state: the session, the current catalogue query and every
/// cached piece of server data.
///
/// Provider values that come from start-up (preferences, the loaded string
/// catalogue, the HTTP client, the restored session) are declared here and
/// overridden in ``main()``, which keeps lookups synchronous everywhere else.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local/library_files.dart';
import '../local/local_repo.dart';
import '../local/sync.dart';
import '../local/transfer.dart';
import '../theme.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'l10n.dart';
import 'library_repo.dart';
import 'models/models.dart';
import 'prefs.dart';
import 'secure_store.dart';

const String kAppName = 'BiblioJules';
const String kAppVersion = '0.1.0';

/// Automatic retries would make an unreachable server flip between "error" and
/// "loading" forever; screens offer an explicit Retry instead.
Duration? _noRetry(int retryCount, Object error) => null;

// --------------------------------------------------------------------------- //
// Booted once in main()
// --------------------------------------------------------------------------- //
final prefsProvider = Provider<AppPrefs>(
  (ref) => throw UnimplementedError('prefsProvider must be overridden in main()'),
);

final catalogCacheProvider = Provider<CatalogCache>(
  (ref) => throw UnimplementedError('catalogCacheProvider must be overridden in main()'),
);

final apiClientProvider = Provider<ApiClient>(
  (ref) => throw UnimplementedError('apiClientProvider must be overridden in main()'),
);

/// Where every screen reads and writes its data.
///
/// Sign-in, the token and the server address stay on [apiClientProvider]: those
/// only exist in server mode, whereas this provider is the *catalogue* that
/// both modes can serve.
final repoProvider = Provider<LibraryRepo>((ref) {
  final session = ref.watch(sessionProvider);
  if (session.isLocal) return ref.watch(localRepoProvider);
  return ref.watch(apiClientProvider);
});

/// The library kept on the device itself.
///
/// Created once and reused, because it owns an open SQLite connection;
/// ``main()`` builds the instance (so the file is open before the first frame)
/// and overrides this provider with it. Whether it is *used* is the session's
/// decision, and [LocalRepo.open]/[LocalRepo.close] decide which file it points
/// at.
final localRepoProvider = Provider<LocalRepo>((ref) => LocalRepo());

/// Moves the on-device library in and out of the app's private storage, via the
/// system file picker (where Google Drive shows up as just another place).
final libraryTransferProvider = Provider<LibraryTransfer>(
  (ref) => LibraryTransfer(repo: ref.watch(localRepoProvider)),
);

/// The folder picker and the questions about a folder grant, on the other side
/// of the same channel the transfer uses. Separate so a test can hand it a
/// mocked channel without touching export/import.
final sharedFolderProvider = Provider<SharedFolder>((ref) => SharedFolder());

/// A sync run against the folder the user chose, or ``null`` when there is
/// nothing to sync with yet (no folder, or the library lives on a server).
final librarySyncProvider = Provider<LibrarySync?>((ref) {
  final prefs = ref.watch(prefsProvider);
  final uri = prefs.syncFolderUri;
  if (uri == null) return null;
  // Only a library kept on the device has a shared folder of its own.
  if (!ref.watch(sessionProvider).isLocal) return null;
  return LibrarySync(
    repo: ref.watch(localRepoProvider),
    transport: SafSyncTransport(folderUri: uri),
  );
});

/// The session restored from disk before the first frame.
final bootSessionProvider = Provider<SessionState>(
  (ref) => throw UnimplementedError('bootSessionProvider must be overridden in main()'),
);

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

// --------------------------------------------------------------------------- //
// Session
// --------------------------------------------------------------------------- //
class SessionState {
  const SessionState({
    this.baseUrl = '',
    this.token,
    this.user,
    this.busy = false,
    this.error,
    this.notice,
    this.isLocal = false,
    this.localLibraryName,
  });

  /// The library server, already normalised (``https://host``, no trailing /).
  final String baseUrl;

  /// The bearer token, or ``null`` when signed out.
  final String? token;
  final User? user;

  /// True while a sign-in/out or server change is in flight.
  final bool busy;

  /// Last sign-in error, shown on the login screen.
  final String? error;

  /// A one-off message to show on the login screen (e.g. an expired session).
  final String? notice;

  /// True when the catalogue lives on this device instead of on a server.
  final bool isLocal;

  /// The on-device library's name (only meaningful when [isLocal]).
  final String? localLibraryName;

  /// There is a catalogue to read: either an account somewhere, or a local
  /// library that needs no account at all.
  bool get signedIn => isLocal || (token != null && token!.isNotEmpty);

  /// True once a server address has been entered, signed in or not.
  bool get configured => baseUrl.isNotEmpty || isLocal;

  SessionState copyWith({
    String? baseUrl,
    String? token,
    User? user,
    bool? busy,
    String? error,
    String? notice,
    bool? isLocal,
    String? localLibraryName,
    bool clearToken = false,
    bool clearUser = false,
    bool clearError = false,
    bool clearNotice = false,
  }) {
    return SessionState(
      baseUrl: baseUrl ?? this.baseUrl,
      token: clearToken ? null : (token ?? this.token),
      user: clearUser ? null : (user ?? this.user),
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      notice: clearNotice ? null : (notice ?? this.notice),
      isLocal: isLocal ?? this.isLocal,
      localLibraryName: localLibraryName ?? this.localLibraryName,
    );
  }
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => ref.watch(bootSessionProvider);

  ApiClient get _api => ref.read(apiClientProvider);
  LocalRepo get _local => ref.read(localRepoProvider);
  AppPrefs get _prefs => ref.read(prefsProvider);
  SecureStore get _store => ref.read(secureStoreProvider);

  /// Sign in against [baseUrl] and remember the token.
  Future<bool> signIn({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final url = normalizeBaseUrl(baseUrl);
    if (!isValidBaseUrl(url)) {
      state = state.copyWith(error: 'Enter the address of your library server.');
      return false;
    }
    _api.setBaseUrl(url);
    _api.setToken(null);
    state = state.copyWith(baseUrl: url, busy: true, clearError: true, clearNotice: true);
    try {
      final result = await _api.login(username: username, password: password);
      _api.setToken(result.token);
      await _store.writeToken(result.token);
      await _prefs.setBaseUrl(url);
      await _prefs.setUsername(username);
      // Signing in commits to the server, so it becomes the library. (Reached
      // only when the device library is *not* the one in use: local mode is
      // already "signed in" and never shows this form. This matters after a
      // local library failed to open, when the mode preference is still local.)
      await _prefs.setMode(LibraryMode.server);
      state = SessionState(baseUrl: url, token: result.token, user: result.user);
      return true;
    } on ApiException catch (error) {
      _api.setToken(null);
      state = state.copyWith(busy: false, error: error.message);
      return false;
    }
  }

  /// Forget the token locally and ask the server to revoke it.
  Future<void> signOut() async {
    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    if (_api.hasToken) {
      try {
        await _api.logout();
      } on ApiException {
        // A revoked/expired token is exactly what we wanted gone anyway.
      }
    }
    _api.setToken(null);
    await _store.writeToken(null);
    // A device library has no account to sign out of, so it stays in use.
    state = SessionState(
      baseUrl: state.baseUrl,
      isLocal: state.isLocal,
      localLibraryName: state.localLibraryName,
    );
  }

  /// The server rejected our token mid-session: drop it and say so.
  Future<void> handleRejectedToken([String? message]) async {
    // A library on this device has no token to reject.
    if (state.isLocal) return;
    if (!state.signedIn) return;
    _api.setToken(null);
    await _store.writeToken(null);
    state = SessionState(
      baseUrl: state.baseUrl,
      notice: message ?? 'Your session has expired. Please sign in again.',
    );
  }

  /// Point the app at another server. Tokens are per-server, so this signs out.
  Future<void> changeServer(String rawUrl) async {
    final url = normalizeBaseUrl(rawUrl);
    if (url == state.baseUrl) return;
    if (state.signedIn) {
      await signOut();
    }
    _api.setBaseUrl(url);
    await _prefs.setBaseUrl(url);
    state = SessionState(baseUrl: url);
  }

  /// Refresh the cached account after a settings change elsewhere.
  Future<void> refreshAccount() async {
    // In local mode there is no account to refresh, and no server to ask.
    if (!state.signedIn || state.isLocal) return;
    try {
      final user = await _api.me();
      state = state.copyWith(user: user);
    } on ApiAuthException {
      await handleRejectedToken();
    } on ApiException {
      // Offline: keep what we had.
    }
  }

  // --- local mode --------------------------------------------------------- //

  /// Switch to the library kept on this device, creating [name] if it is new.
  ///
  /// Any server token is *kept* rather than revoked, so switching back to the
  /// hosted library does not mean signing in again.
  Future<bool> useLocalLibrary(String name) async {
    final label = name.trim().isEmpty ? kDefaultLibraryName : name.trim();
    state = state.copyWith(busy: true, clearError: true, clearNotice: true);
    try {
      await _local.open(label);
    } on Object catch (error) {
      state = state.copyWith(busy: false, error: describeLocalError(error));
      return false;
    }
    await _prefs.setMode(LibraryMode.local);
    await _prefs.setLocalLibraryName(label);
    state = SessionState(
      baseUrl: state.baseUrl,
      token: state.token,
      user: state.user,
      isLocal: true,
      localLibraryName: label,
    );
    return true;
  }

  /// Go back to the hosted library, closing the file on this device.
  Future<void> useServerLibrary() async {
    if (!state.isLocal) return;
    await _local.close();
    await _prefs.setMode(LibraryMode.server);
    state = SessionState(
      baseUrl: state.baseUrl,
      token: state.token,
      user: state.user,
    );
  }

  /// Rename the on-device library, moving its file when the slug changes.
  Future<bool> renameLocalLibrary(String name) async {
    final label = name.trim();
    if (label.isEmpty || label == state.localLibraryName) return true;
    try {
      await _local.renameTo(label);
    } on ApiException catch (error) {
      state = state.copyWith(error: error.message);
      return false;
    }
    await _prefs.setLocalLibraryName(label);
    state = state.copyWith(localLibraryName: label, clearError: true);
    return true;
  }

  void clearNotice() => state = state.copyWith(clearNotice: true);
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

/// Changes whenever the identity or the server changes, so cached data is
/// dropped on sign-in/sign-out, when the app is pointed elsewhere, and when it
/// switches between the device and a server.
final sessionKeyProvider = Provider<String>((ref) {
  final session = ref.watch(sessionProvider);
  if (session.isLocal) return 'local|${session.localLibraryName ?? ''}';
  return 'server|${session.baseUrl}|${session.token ?? ''}';
});

/// A message for a failure to open or move a library file.
///
/// The technical detail is kept: a mangled SQLite file is something the user
/// needs to be able to report.
String describeLocalError(Object error) => error is ApiException
    ? error.message
    : 'That library could not be opened: $error';

// --------------------------------------------------------------------------- //
// Language
// --------------------------------------------------------------------------- //
class LanguageController extends Notifier<String> {
  @override
  String build() => ref.watch(prefsProvider).effectiveLanguage;

  Future<void> set(String code) async {
    final language = normalizeLanguage(code);
    await ref.read(prefsProvider).setLanguage(language);
    // The server writes its own messages in the language the app asks for.
    ref.read(apiClientProvider).setLanguage(language);
    // So does the on-device store, for the few messages it writes itself.
    ref
        .read(localRepoProvider)
        .useMessages(ref.read(catalogCacheProvider).forLanguage(language));
    state = language;
  }
}

final languageProvider = NotifierProvider<LanguageController, String>(
  LanguageController.new,
);

/// The string catalogue for the current language.
final l10nProvider = Provider<L10n>((ref) {
  final language = ref.watch(languageProvider);
  return ref.watch(catalogCacheProvider).forLanguage(language);
});

// --------------------------------------------------------------------------- //
// Colour theme
// --------------------------------------------------------------------------- //
class ColorThemeController extends Notifier<String> {
  @override
  String build() => ref.watch(prefsProvider).colorTheme;

  Future<void> set(String slug) async {
    final normalized = normalizeThemeSlug(slug);
    await ref.read(prefsProvider).setColorTheme(normalized);
    state = normalized;
  }
}

/// The selected accent, by slug. Changing it re-themes the whole app.
final colorThemeProvider = NotifierProvider<ColorThemeController, String>(
  ColorThemeController.new,
);

/// The full palette behind the selected accent.
final paletteProvider = Provider<ColorTheme>((ref) {
  return themeBySlug(ref.watch(colorThemeProvider));
});

// --------------------------------------------------------------------------- //
// The catalogue query
// --------------------------------------------------------------------------- //
class CatalogQuery {
  const CatalogQuery({
    this.search = '',
    this.statusId,
    this.locationId,
    this.authorId,
    this.publisherId,
    this.loaned = false,
    this.saga = '',
    this.readStatus,
    this.sort = 'recent',
    this.direction,
  });

  final String search;
  final int? statusId;
  final int? locationId;
  final int? authorId;
  final int? publisherId;
  final bool loaned;
  final String saga;
  final String? readStatus;
  final String sort;
  final String? direction;

  /// True when anything but the default ordering is in effect.
  bool get hasFilters =>
      search.isNotEmpty ||
      statusId != null ||
      locationId != null ||
      authorId != null ||
      publisherId != null ||
      loaned ||
      saga.isNotEmpty ||
      readStatus != null;

  int get filterCount => [
    search.isNotEmpty,
    statusId != null,
    locationId != null,
    authorId != null,
    publisherId != null,
    loaned,
    saga.isNotEmpty,
    readStatus != null,
  ].where((active) => active).length;

  CatalogQuery copyWith({
    String? search,
    int? statusId,
    int? locationId,
    int? authorId,
    int? publisherId,
    bool? loaned,
    String? saga,
    String? readStatus,
    String? sort,
    String? direction,
    bool clearStatus = false,
    bool clearLocation = false,
    bool clearAuthor = false,
    bool clearPublisher = false,
    bool clearReadStatus = false,
    bool clearDirection = false,
  }) {
    return CatalogQuery(
      search: search ?? this.search,
      statusId: clearStatus ? null : (statusId ?? this.statusId),
      locationId: clearLocation ? null : (locationId ?? this.locationId),
      authorId: clearAuthor ? null : (authorId ?? this.authorId),
      publisherId: clearPublisher ? null : (publisherId ?? this.publisherId),
      loaned: loaned ?? this.loaned,
      saga: saga ?? this.saga,
      readStatus: clearReadStatus ? null : (readStatus ?? this.readStatus),
      sort: sort ?? this.sort,
      direction: clearDirection ? null : (direction ?? this.direction),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CatalogQuery &&
      other.search == search &&
      other.statusId == statusId &&
      other.locationId == locationId &&
      other.authorId == authorId &&
      other.publisherId == publisherId &&
      other.loaned == loaned &&
      other.saga == saga &&
      other.readStatus == readStatus &&
      other.sort == sort &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(
    search,
    statusId,
    locationId,
    authorId,
    publisherId,
    loaned,
    saga,
    readStatus,
    sort,
    direction,
  );
}

class CatalogQueryController extends Notifier<CatalogQuery> {
  @override
  CatalogQuery build() {
    final prefs = ref.watch(prefsProvider);
    return CatalogQuery(sort: prefs.sort, direction: prefs.direction);
  }

  void update(CatalogQuery Function(CatalogQuery current) change) {
    state = change(state);
  }

  void setSort(String sort, {String? direction}) {
    if (direction != null) {
      state = state.copyWith(sort: sort, direction: direction);
      ref.read(prefsProvider).setSort(sort, direction);
      return;
    }
    final nextDirection = _nextDirection(sort);
    state = state.copyWith(sort: sort, direction: nextDirection);
    ref.read(prefsProvider).setSort(sort, nextDirection);
  }

  /// Tapping the active column flips the direction, like the web headers.
  String _nextDirection(String sort) {
    final defaultDesc = sort == 'recent' || sort == 'year';
    if (state.sort == sort) {
      final current = state.direction ?? (defaultDesc ? 'desc' : 'asc');
      return current == 'desc' ? 'asc' : 'desc';
    }
    return defaultDesc ? 'desc' : 'asc';
  }

  void reset() => state = CatalogQuery(sort: state.sort, direction: state.direction);
}

final catalogQueryProvider =
    NotifierProvider<CatalogQueryController, CatalogQuery>(CatalogQueryController.new);

// --------------------------------------------------------------------------- //
// Cached server data
// --------------------------------------------------------------------------- //
final booksProvider = FutureProvider<List<Book>>((ref) {
  ref.watch(sessionKeyProvider);
  final query = ref.watch(catalogQueryProvider);
  final api = ref.watch(repoProvider);
  return api.listBooks(
    search: query.search.isEmpty ? null : query.search,
    statusId: query.statusId,
    locationId: query.locationId,
    authorId: query.authorId,
    publisherId: query.publisherId,
    loaned: query.loaned ? 'loaned' : null,
    saga: query.saga.isEmpty ? null : query.saga,
    readStatus: query.readStatus,
    sort: query.sort,
    direction: query.direction,
  );
}, retry: _noRetry, isAutoDispose: true);

final bookProvider = FutureProvider.family<Book, int>((ref, id) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).getBook(id);
}, retry: _noRetry, isAutoDispose: true);

final bookLoansProvider = FutureProvider.family<List<Loan>, int>((ref, bookId) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).bookLoans(bookId);
}, retry: _noRetry, isAutoDispose: true);

final locationsProvider = FutureProvider<List<Location>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).listLocations();
}, retry: _noRetry, isAutoDispose: true);

final statusesProvider = FutureProvider<List<Status>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).listStatuses();
}, retry: _noRetry, isAutoDispose: true);

final sagasProvider = FutureProvider<List<String>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).listSagas();
}, retry: _noRetry, isAutoDispose: true);

final authorsProvider = FutureProvider<List<RefItem>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).listAuthors();
}, retry: _noRetry, isAutoDispose: true);

final publishersProvider = FutureProvider<List<RefItem>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).listPublishers();
}, retry: _noRetry, isAutoDispose: true);

final dashboardProvider = FutureProvider<DashboardData>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).dashboard();
}, retry: _noRetry, isAutoDispose: true);

// --------------------------------------------------------------------------- //
// Lookups (kept alive so results survive a scroll/tab change)
// --------------------------------------------------------------------------- //
final isbnLookupProvider = FutureProvider.family<SearchResult?, String>((ref, isbn) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).lookupIsbn(isbn);
}, retry: _noRetry, isAutoDispose: true);

final onlineSearchProvider = FutureProvider.family<List<SearchResult>, String>((ref, query) {
  ref.watch(sessionKeyProvider);
  return ref.watch(repoProvider).searchBooks(query);
}, retry: _noRetry, isAutoDispose: true);

// --------------------------------------------------------------------------- //
// Invalidation helpers
// --------------------------------------------------------------------------- //
/// Drop every cached book list/aggregate (after any write to a book).
void invalidateBooks(WidgetRef ref) {
  ref.invalidate(booksProvider);
  ref.invalidate(bookProvider);
  ref.invalidate(dashboardProvider);
  ref.invalidate(sagasProvider);
  ref.invalidate(authorsProvider);
  ref.invalidate(publishersProvider);
}

/// Drop cached locations (and the book lists that embed them).
void invalidateLocations(WidgetRef ref) {
  ref.invalidate(locationsProvider);
  invalidateBooks(ref);
}

/// Drop cached statuses (and the book lists that embed them).
void invalidateStatuses(WidgetRef ref) {
  ref.invalidate(statusesProvider);
  invalidateBooks(ref);
}

/// The toolbar's "sync" button: forget everything and let the visible screens
/// fetch it again.
void refreshEverything(WidgetRef ref) {
  invalidateBooks(ref);
  ref.invalidate(locationsProvider);
  ref.invalidate(statusesProvider);
}
