/// The HTTP client for a hosted BiblioJules library.
///
/// A single instance is created at start-up and its base URL and bearer token
/// are mutated as the user signs in/out or points the app at another server, so
/// every screen can share one connection pool.
library;

import 'dart:io' show Platform;

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'library_repo.dart';
import 'models/models.dart';

/// Add a scheme to a bare host and drop any trailing slash.
///
/// Users type things like ``10.0.2.2:8000`` (the Android emulator's view of the
/// developer machine) or ``library.example.com``; private/loopback addresses
/// and single-label hostnames default to plain HTTP, everything else to HTTPS.
String normalizeBaseUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (!value.contains('://')) {
    final hostPort = value.split('/').first;
    final host = hostPort.startsWith('[')
        ? hostPort.substring(0, hostPort.indexOf(']') + 1)
        : hostPort.split(':').first;
    final localhost = host.startsWith('[')
        ? host == '[::1]'
        : host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2';
    final private =
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host);
    final looksLocal = localhost || private || !host.contains('.');
    value = '${looksLocal ? 'http' : 'https'}://$value';
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// True when [raw] looks like something we can actually connect to.
bool isValidBaseUrl(String raw) {
  final url = normalizeBaseUrl(raw);
  if (url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  return uri != null && uri.host.isNotEmpty;
}

/// A short description of this device, stored with the token so the web admin
/// page can tell sessions apart.
String deviceLabel() {
  try {
    return 'Android app · ${Platform.operatingSystemVersion}';
  } catch (_) {
    return 'Android app';
  }
}

/// The catalogue half of the client (see [LibraryRepo]); the session half
/// (sign in, tokens, server address) is specific to talking to a server.
class ApiClient implements LibraryRepo {
  ApiClient({String baseUrl = '', String? token, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'Accept': 'application/json'},
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _token;
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          // The server writes its own error messages in this language.
          final language = _language;
          if (language != null) {
            options.headers['Accept-Language'] = language;
          }
          handler.next(options);
        },
      ),
    );
    setToken(token);
    setBaseUrl(baseUrl);
  }

  final Dio _dio;
  String? _token;
  String? _language;

  String get baseUrl => _dio.options.baseUrl;

  void setBaseUrl(String url) => _dio.options.baseUrl = normalizeBaseUrl(url);

  void setToken(String? token) =>
      _token = (token == null || token.isEmpty) ? null : token;

  bool get hasToken => _token != null;

  /// Tell the server which language its own messages should be written in.
  void setLanguage(String? language) =>
      _language = (language == null || language.isEmpty) ? null : language;

  // --- internals ---------------------------------------------------------- //
  Never _mapError(DioException error) {
    final response = error.response;
    final detail = _detail(response?.data);
    switch (error.type) {
      case DioExceptionType.badResponse:
        final code = response?.statusCode ?? 0;
        if (code == 401) return throw ApiAuthException(detail ?? 'Your session has expired.');
        if (code == 403) return throw ApiForbiddenException(detail ?? 'You are not allowed to do that.');
        if (code == 404) return throw ApiNotFoundException(detail ?? 'Not found.');
        if (code == 400 || code == 422) {
          return throw ApiValidationException(
            detail ?? 'The server rejected that data.',
            statusCode: code,
          );
        }
        return throw ApiException(
          detail ?? 'The server could not complete that request.',
          statusCode: code,
        );
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return throw ApiConnectionException(
          'The library server took too long to answer. Check the server address.',
        );
      case DioExceptionType.badCertificate:
        return throw ApiConnectionException(
          'The server\'s certificate could not be verified.',
        );
      case DioExceptionType.cancel:
        return throw ApiException('The request was cancelled.');
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return throw ApiConnectionException(
          detail ?? 'Could not reach the library server. Check the address and your network.',
        );
    }
  }

  /// Pull a message out of a FastAPI error body (``{"detail": …}``, a
  /// validation-error list, or plain text).
  String? _detail(dynamic data) {
    if (data is Map) {
      final detail = data['detail'];
      if (detail is String) return detail;
      if (detail is List) {
        final parts = detail
            .map((item) {
              if (item is Map) {
                final loc = (item['loc'] as List?)?.skip(1).join('.');
                final msg = item['msg'] ?? 'invalid';
                return loc == null || loc.isEmpty ? '$msg' : '$loc: $msg';
              }
              return '$item';
            })
            .where((text) => text.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.join('; ');
      }
      return null;
    }
    if (data is String && data.trim().isNotEmpty && data.length < 300) {
      return data.trim();
    }
    return null;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (error) {
      throw _mapError(error);
    }
  }

  Future<Response<dynamic>> _get(String path, {Map<String, dynamic>? query}) =>
      _guard(() => _dio.get<dynamic>(path, queryParameters: query));

  Future<Response<dynamic>> _send(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) => _guard(
    () => _dio.request<dynamic>(path, data: body, queryParameters: query, options: Options(method: method)),
  );

  // --- authentication ----------------------------------------------------- //
  Future<LoginResult> login({
    required String username,
    required String password,
    String? label,
  }) async {
    final response = await _send(
      'POST',
      '/api/auth/login',
      body: {'username': username, 'password': password, 'label': label ?? deviceLabel()},
    );
    return LoginResult.fromJson(response.data as Map<String, dynamic>);
  }

  Future<User> me() async {
    final response = await _get('/api/auth/me');
    return User.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    await _send('POST', '/api/auth/logout');
  }

  // --- books -------------------------------------------------------------- //
  @override
  Future<List<Book>> listBooks({
    String? search,
    int? statusId,
    int? locationId,
    int? authorId,
    int? publisherId,
    String? loaned,
    String? saga,
    String? readStatus,
    String sort = 'recent',
    String? direction,
  }) async {
    final response = await _get(
      '/api/books',
      query: {
        if (search != null && search.isNotEmpty) 'search': search,
        'status': ?statusId,
        'location': ?locationId,
        'author': ?authorId,
        'publisher': ?publisherId,
        if (loaned != null && loaned.isNotEmpty) 'loaned': loaned,
        if (saga != null && saga.isNotEmpty) 'saga': saga,
        if (readStatus != null && readStatus.isNotEmpty) 'read_status': readStatus,
        'sort': sort,
        if (direction != null && direction.isNotEmpty) 'dir': direction,
      },
    );
    final data = response.data as Map<String, dynamic>;
    return (data['items'] as List)
        .map((item) => Book.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Book> getBook(int id) async {
    final response = await _get('/api/books/$id');
    return Book.fromJson(response.data as Map<String, dynamic>);
  }

  /// ``null`` when no book carries [isbn] (used to spot duplicates).
  @override
  Future<Book?> findByIsbn(String isbn) async {
    try {
      final response = await _get('/api/books/by-isbn/${Uri.encodeComponent(isbn)}');
      return Book.fromJson(response.data as Map<String, dynamic>);
    } on ApiNotFoundException {
      return null;
    }
  }

  @override
  Future<List<Loan>> bookLoans(int bookId) async {
    final response = await _get('/api/books/$bookId/loans');
    return (response.data as List)
        .map((item) => Loan.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Book> createBook(Map<String, dynamic> payload) async {
    final response = await _send('POST', '/api/books', body: payload);
    return Book.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<Book> updateBook(int id, Map<String, dynamic> payload) async {
    final response = await _send('PUT', '/api/books/$id', body: payload);
    return Book.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<bool> deleteBook(int id) async {
    await _send('DELETE', '/api/books/$id');
    return true;
  }

  @override
  Future<Loan> lendBook(
    int bookId, {
    required String borrowerName,
    String? borrowerContact,
    String? lentAt,
    String? dueAt,
    String? notes,
    bool markStatus = true,
  }) async {
    final response = await _send(
      'POST',
      '/api/books/$bookId/lend',
      body: {
        'borrower_name': borrowerName,
        'borrower_contact': borrowerContact,
        'lent_at': lentAt,
        'due_at': dueAt,
        'notes': notes,
        'mark_status': markStatus,
      },
    );
    return Loan.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> returnBook(
    int bookId, {
    String? returnedAt,
    bool restoreStatus = true,
  }) => _send(
    'POST',
    '/api/books/$bookId/return',
    body: {'returned_at': returnedAt, 'restore_status': restoreStatus},
  );

  // --- locations ---------------------------------------------------------- //
  @override
  Future<List<Location>> listLocations() async {
    final response = await _get('/api/locations');
    return (response.data as List)
        .map((item) => Location.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Location> createLocation({
    required String name,
    int? parentId,
    String? kind,
    String? description,
  }) async {
    final response = await _send(
      'POST',
      '/api/locations',
      body: {'name': name, 'parent_id': parentId, 'kind': kind, 'description': description},
    );
    return Location.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<Location> updateLocation(
    int id, {
    required String name,
    int? parentId,
    String? kind,
    String? description,
  }) async {
    final response = await _send(
      'PUT',
      '/api/locations/$id',
      body: {'name': name, 'parent_id': parentId, 'kind': kind, 'description': description},
    );
    return Location.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<bool> deleteLocation(int id) async {
    await _send('POST', '/api/locations/$id/delete');
    return true;
  }

  // --- statuses ----------------------------------------------------------- //
  @override
  Future<List<Status>> listStatuses() async {
    final response = await _get('/api/statuses');
    return (response.data as List)
        .map((item) => Status.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Status> createStatus({
    required String name,
    String color = '#64748b',
    String? icon,
    String? description,
  }) async {
    final response = await _send(
      'POST',
      '/api/statuses',
      body: {'name': name, 'color': color, 'icon': icon, 'description': description},
    );
    return Status.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<Status> updateStatus(
    int id, {
    required String name,
    String color = '#64748b',
    String? icon,
    String? description,
  }) async {
    final response = await _send(
      'PUT',
      '/api/statuses/$id',
      body: {'name': name, 'color': color, 'icon': icon, 'description': description},
    );
    return Status.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<bool> deleteStatus(int id) async {
    await _send('POST', '/api/statuses/$id/delete');
    return true;
  }

  // --- reference data ----------------------------------------------------- //
  @override
  Future<List<RefItem>> listAuthors() async {
    final response = await _get('/api/authors');
    return (response.data as List)
        .map((item) => RefItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<RefItem>> listPublishers() async {
    final response = await _get('/api/publishers');
    return (response.data as List)
        .map((item) => RefItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<String>> listSagas() async {
    final response = await _get('/api/sagas');
    return (response.data as List).map((item) => '$item').toList();
  }

  // --- aggregates & lookup ------------------------------------------------ //
  @override
  Future<DashboardData> dashboard() async {
    final response = await _get('/api/dashboard');
    return DashboardData.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<Stats> stats() async {
    final response = await _get('/api/stats');
    return Stats.fromJson(response.data as Map<String, dynamic>);
  }

  /// Online metadata for one ISBN (Open Library / Google Books).
  @override
  Future<SearchResult?> lookupIsbn(String isbn) async {
    try {
      final response = await _get('/api/lookup/isbn/${Uri.encodeComponent(isbn)}');
      return SearchResult.fromJson(response.data as Map<String, dynamic>);
    } on ApiNotFoundException {
      return null;
    }
  }

  @override
  Future<List<SearchResult>> searchBooks(String query, {int limit = 12}) async {
    final response = await _get('/api/search', query: {'q': query, 'limit': limit});
    return (response.data as List)
        .map((item) => SearchResult.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
