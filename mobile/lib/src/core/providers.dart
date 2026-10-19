/// Application-wide state: the session, the current catalogue query and every
/// cached piece of server data.
///
/// Provider values that come from start-up (preferences, the loaded string
/// catalogue, the HTTP client, the restored session) are declared here and
/// overridden in ``main()``, which keeps lookups synchronous everywhere else.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'api_exception.dart';
import 'l10n.dart';
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

  bool get signedIn => token != null && token!.isNotEmpty;

  /// True once a server address has been entered, signed in or not.
  bool get configured => baseUrl.isNotEmpty;

  SessionState copyWith({
    String? baseUrl,
    String? token,
    User? user,
    bool? busy,
    String? error,
    String? notice,
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
    );
  }
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => ref.watch(bootSessionProvider);

  ApiClient get _api => ref.read(apiClientProvider);
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
    state = SessionState(baseUrl: state.baseUrl);
  }

  /// The server rejected our token mid-session: drop it and say so.
  Future<void> handleRejectedToken([String? message]) async {
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
    if (!state.signedIn) return;
    try {
      final user = await _api.me();
      state = state.copyWith(user: user);
    } on ApiAuthException {
      await handleRejectedToken();
    } on ApiException {
      // Offline: keep what we had.
    }
  }

  void clearNotice() => state = state.copyWith(clearNotice: true);
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);

/// Changes whenever the identity or the server changes, so cached data is
/// dropped on sign-in/sign-out and when the app is pointed elsewhere.
final sessionKeyProvider = Provider<String>((ref) {
  final session = ref.watch(sessionProvider);
  return '${session.baseUrl}|${session.token ?? ''}';
});

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
  final api = ref.watch(apiClientProvider);
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
  return ref.watch(apiClientProvider).getBook(id);
}, retry: _noRetry, isAutoDispose: true);

final bookLoansProvider = FutureProvider.family<List<Loan>, int>((ref, bookId) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).bookLoans(bookId);
}, retry: _noRetry, isAutoDispose: true);

final locationsProvider = FutureProvider<List<Location>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).listLocations();
}, retry: _noRetry, isAutoDispose: true);

final statusesProvider = FutureProvider<List<Status>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).listStatuses();
}, retry: _noRetry, isAutoDispose: true);

final sagasProvider = FutureProvider<List<String>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).listSagas();
}, retry: _noRetry, isAutoDispose: true);

final authorsProvider = FutureProvider<List<RefItem>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).listAuthors();
}, retry: _noRetry, isAutoDispose: true);

final publishersProvider = FutureProvider<List<RefItem>>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).listPublishers();
}, retry: _noRetry, isAutoDispose: true);

final dashboardProvider = FutureProvider<DashboardData>((ref) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).dashboard();
}, retry: _noRetry, isAutoDispose: true);

// --------------------------------------------------------------------------- //
// Lookups (kept alive so results survive a scroll/tab change)
// --------------------------------------------------------------------------- //
final isbnLookupProvider = FutureProvider.family<SearchResult?, String>((ref, isbn) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).lookupIsbn(isbn);
}, retry: _noRetry, isAutoDispose: true);

final onlineSearchProvider = FutureProvider.family<List<SearchResult>, String>((ref, query) {
  ref.watch(sessionKeyProvider);
  return ref.watch(apiClientProvider).searchBooks(query);
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
