/// Online book metadata, fetched straight from the phone.
///
/// In server mode these two calls go through the hosted app. Local mode has no
/// server to ask, so the same free, key-less services are called directly:
///
/// * `Open Library <https://openlibrary.org/developers/api>`_ — primary source.
/// * `Google Books <https://developers.google.com/books>`_ — gap filler.
///
/// This is a port of ``app/services/isbn_lookup.py`` and behaves like it: the
/// providers run in the same order, a provider that fails is skipped rather
/// than failing the whole request, and the merge keeps the earlier record's
/// values while the later one fills in the blanks.
library;

import 'package:dio/dio.dart';

import '../core/book_fields.dart';
import '../core/models/models.dart';

const String _openLibraryBooksUrl = 'https://openlibrary.org/api/books';
const String _openLibrarySearchUrl = 'https://openlibrary.org/search.json';
const String _googleBooksUrl = 'https://www.googleapis.com/books/v1/volumes';
const String _coversBase = 'https://covers.openlibrary.org/b/id';

/// Sent with every request, so the operators can tell who is calling.
const String _userAgent = 'BiblioJules/0.1 (home library catalog; Android app)';

/// The ISBN fields asked of Open Library when searching, spelled out so the
/// response stays small. Identical to the server's list.
const String _searchFields =
    'key,title,subtitle,author_name,first_publish_year,isbn,publisher,'
    'cover_i,language,number_of_pages_median';

class OnlineLookup {
  OnlineLookup({Dio? client}) : _dio = client;

  Dio? _dio;

  Dio get _client => _dio ??= Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'Accept': 'application/json', 'User-Agent': _userAgent},
    ),
  );

  /// Release the connection pool. A later call builds a fresh client.
  void close() {
    _dio?.close(force: true);
    _dio = null;
  }

  // ------------------------------------------------------------------------- //
  // Public API
  // ------------------------------------------------------------------------- //

  /// One ISBN across every provider, or ``null`` when none of them knows it.
  Future<SearchResult?> lookupIsbn(String rawIsbn) async {
    final isbn = normalizeIsbn(rawIsbn);
    if (isbn.isEmpty) return null;

    final records = <Map<String, dynamic>?>[];
    for (final provider in <Future<Map<String, dynamic>?> Function(String)>[
      _openLibraryByIsbn,
      _googleBooksByIsbn,
    ]) {
      try {
        records.add(await provider(isbn));
      } on Object {
        // A provider being down (or rate-limiting) must never break a scan.
        records.add(null);
      }
    }

    final merged = _merge(records);
    if (merged != null) merged['isbn'] = isbn;
    return merged == null ? null : SearchResult.fromJson(merged);
  }

  /// Free-text search, for adding a book without an ISBN in hand.
  Future<List<SearchResult>> searchBooks(String query, {int limit = 12}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <SearchResult>[];

    var results = <Map<String, dynamic>>[];
    try {
      results = await _openLibrarySearch(trimmed, limit);
    } on Object {
      // Fall through to Google Books.
    }

    // Only reach for the second provider when the first came back thin, which
    // is exactly the server's heuristic.
    if (results.length < 3) {
      try {
        final google = await _googleSearch(trimmed, limit);
        final seen = results
            .map((item) => '${item['title'] ?? ''}'.toLowerCase())
            .toSet();
        results.addAll(
          google.where(
            (item) => !seen.contains('${item['title'] ?? ''}'.toLowerCase()),
          ),
        );
      } on Object {
        // Keep whatever Open Library gave us.
      }
    }

    final capped = results.take(limit).toList();
    for (final item in capped) {
      // The API adds this join for clients that cannot handle a list.
      final authors = item['authors'];
      item['authors_str'] = authors is List ? authors.join(', ') : authors;
    }
    return capped.map(SearchResult.fromJson).toList();
  }

  // ------------------------------------------------------------------------- //
  // Providers
  // ------------------------------------------------------------------------- //

  Future<Map<String, dynamic>?> _openLibraryByIsbn(String isbn) async {
    final response = await _client.get<dynamic>(
      _openLibraryBooksUrl,
      queryParameters: <String, dynamic>{
        'bibkeys': 'ISBN:$isbn',
        'format': 'json',
        'jscmd': 'data',
      },
    );
    final payload = _asMap(response.data);
    final entry = _asMap(payload?['ISBN:$isbn']);
    if (entry == null) return null;

    final cover = _asMap(entry['cover']) ?? const <String, dynamic>{};
    return <String, dynamic>{
      'isbn': isbn,
      'title': entry['title'],
      'subtitle': entry['subtitle'],
      'authors': <String>[
        for (final author in _asList(entry['authors']))
          if (_asMap(author)?['name'] != null) '${_asMap(author)!['name']}',
      ],
      'publisher': _firstNamed(entry['publishers']),
      'published_date': entry['publish_date'],
      'published_year': extractYear(entry['publish_date']),
      'description': null,
      'page_count': entry['number_of_pages'],
      'language': null,
      'cover_url': cover['large'] ?? cover['medium'] ?? cover['small'],
      'source': 'openlibrary',
    };
  }

  Future<Map<String, dynamic>?> _googleBooksByIsbn(String isbn) async {
    final response = await _client.get<dynamic>(
      _googleBooksUrl,
      queryParameters: <String, dynamic>{'q': 'isbn:$isbn'},
    );
    final items = _asList(_asMap(response.data)?['items']);
    if (items.isEmpty) return null;

    final info = _asMap(items.first)?['volumeInfo'];
    final infoMap = _asMap(info) ?? const <String, dynamic>{};
    final images = _asMap(infoMap['imageLinks']) ?? const <String, dynamic>{};
    return <String, dynamic>{
      'isbn': isbn,
      'title': infoMap['title'],
      'subtitle': infoMap['subtitle'],
      'authors': _asStringList(infoMap['authors']),
      'publisher': infoMap['publisher'],
      'published_date': infoMap['publishedDate'],
      'published_year': extractYear(infoMap['publishedDate']),
      'description': infoMap['description'],
      'page_count': infoMap['pageCount'],
      'language': infoMap['language'],
      'cover_url': _httpsCover(
        images['large'] ?? images['medium'] ?? images['thumbnail'],
      ),
      'source': 'googlebooks',
    };
  }

  Future<List<Map<String, dynamic>>> _openLibrarySearch(
    String query,
    int limit,
  ) async {
    final response = await _client.get<dynamic>(
      _openLibrarySearchUrl,
      queryParameters: <String, dynamic>{
        'q': query,
        'limit': limit,
        'fields': _searchFields,
      },
    );
    final docs = _asList(_asMap(response.data)?['docs']);

    return <Map<String, dynamic>>[
      for (final raw in docs)
        if (_asMap(raw) != null) _openLibraryDoc(_asMap(raw)!),
    ];
  }

  Map<String, dynamic> _openLibraryDoc(Map<String, dynamic> doc) {
    final isbns = _asStringList(doc['isbn']);
    // Prefer an ISBN-13 when the record carries both.
    String? isbn;
    for (final value in isbns) {
      if (value.length == 13) {
        isbn = value;
        break;
      }
    }
    isbn ??= isbns.isEmpty ? null : isbns.first;
    final publishers = _asStringList(doc['publisher']);
    final languages = _asStringList(doc['language']);
    final coverId = doc['cover_i'];
    return <String, dynamic>{
      'isbn': isbn,
      'title': doc['title'],
      'subtitle': doc['subtitle'],
      'authors': _asStringList(doc['author_name']),
      'publisher': publishers.isEmpty ? null : publishers.first,
      'published_date': null,
      'published_year': doc['first_publish_year'],
      'description': null,
      'page_count': doc['number_of_pages_median'],
      'language': languages.isEmpty ? null : languages.first,
      'cover_url': coverId == null ? null : '$_coversBase/$coverId-M.jpg',
      'source': 'openlibrary',
    };
  }

  Future<List<Map<String, dynamic>>> _googleSearch(
    String query,
    int limit,
  ) async {
    final response = await _client.get<dynamic>(
      _googleBooksUrl,
      queryParameters: <String, dynamic>{'q': query, 'maxResults': limit},
    );
    final items = _asList(_asMap(response.data)?['items']);

    final results = <Map<String, dynamic>>[];
    for (final raw in items) {
      final info = _asMap(_asMap(raw)?['volumeInfo']);
      if (info == null) continue;
      final identifiers = _asList(info['industryIdentifiers'])
          .map(_asMap)
          .whereType<Map<String, dynamic>>()
          .toList();
      String? isbn;
      for (final identifier in identifiers) {
        if (identifier['type'] == 'ISBN_13') {
          isbn = '${identifier['identifier']}';
          break;
        }
      }
      isbn ??= identifiers.isEmpty ? null : '${identifiers.first['identifier']}';

      final images = _asMap(info['imageLinks']) ?? const <String, dynamic>{};
      results.add(<String, dynamic>{
        'isbn': isbn,
        'title': info['title'],
        'subtitle': info['subtitle'],
        'authors': _asStringList(info['authors']),
        'publisher': info['publisher'],
        'published_date': info['publishedDate'],
        'published_year': extractYear(info['publishedDate']),
        'description': info['description'],
        'page_count': info['pageCount'],
        'language': info['language'],
        'cover_url': _httpsCover(
          images['thumbnail'] ?? images['smallThumbnail'],
        ),
        'source': 'googlebooks',
      });
    }
    return results;
  }

  // ------------------------------------------------------------------------- //
  // Helpers
  // ------------------------------------------------------------------------- //

  /// Earlier records win; later ones only fill in what is still missing.
  Map<String, dynamic>? _merge(List<Map<String, dynamic>?> records) {
    final present = records.whereType<Map<String, dynamic>>().toList();
    if (present.isEmpty) return null;
    final merged = Map<String, dynamic>.of(present.first);
    for (final record in present.skip(1)) {
      for (final entry in record.entries) {
        if (entry.key == 'source') continue;
        final existing = merged[entry.key];
        final empty =
            existing == null ||
            existing == '' ||
            (existing is List && existing.isEmpty);
        if (empty) merged[entry.key] = entry.value;
      }
    }
    return merged;
  }

  /// ``publishers`` / ``author_name`` style entries are ``[{'name': …}]`` on
  /// Open Library's book API, so pull the first usable name out.
  String? _firstNamed(Object? value) {
    for (final entry in _asList(value)) {
      final name = _asMap(entry)?['name'];
      if (name != null) return '$name';
    }
    return null;
  }

  /// Google Books hands out ``http://`` thumbnails, which Android blocks.
  String? _httpsCover(Object? value) =>
      value == null ? null : '$value'.replaceFirst('http://', 'https://');

  Map<String, dynamic>? _asMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  List<Object?> _asList(Object? value) =>
      value is List ? value : const <Object?>[];

  List<String> _asStringList(Object? value) => <String>[
    for (final item in _asList(value)) '$item',
  ];
}
