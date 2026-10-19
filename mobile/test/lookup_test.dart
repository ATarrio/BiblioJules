/// The metadata lookup local mode does for itself.
///
/// A phone with no server still has to be able to scan a barcode or search by
/// title, so the app calls Open Library and Google Books directly. These tests
/// pin down the port of ``app/services/isbn_lookup.py``: the order of the
/// providers, what wins in a merge, and what happens when one of them is down.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:bibliojules_mobile/src/local/lookup.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _openLibraryBooks = '/api/books';
const _openLibrarySearch = '/search.json';
const _googleVolumes = '/books/v1/volumes';

/// Stands in for the two upstream APIs.
///
/// A response is keyed by path; give an ``int`` instead of a body to make that
/// path fail with that status, and leave a path out to have it answer `{}`.
class _FakeApis implements HttpClientAdapter {
  _FakeApis(this.responses);

  final Map<String, Object?> responses;
  final List<Uri> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final body = responses[options.uri.path];
    if (body is int) {
      return ResponseBody.fromString(
        json.encode({'error': 'boom'}),
        body,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      json.encode(body ?? <String, Object?>{}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The real Open Library answer for a book it knows.
const _dune = {
  'ISBN:9780441013593': {
    'title': 'Dune',
    'subtitle': 'Book One',
    'authors': [
      {'name': 'Frank Herbert', 'url': 'https://openlibrary.org/authors/OL1A'},
    ],
    'publishers': [
      {'name': 'Ace'},
    ],
    'publish_date': '1965',
    'number_of_pages': 412,
    'cover': {
      'small': 'https://covers.openlibrary.org/b/id/9-S.jpg',
      'large': 'https://covers.openlibrary.org/b/id/9-L.jpg',
    },
  },
};

/// The Google Books answer for the same book, with the bits Open Library is
/// missing (a description, a precise date).
const _googleDune = {
  'items': [
    {
      'volumeInfo': {
        'title': 'Dune',
        'subtitle': 'Book One',
        'authors': ['Frank Herbert'],
        'publisher': 'Ace',
        'publishedDate': '1965-08-01',
        'description': 'Spice must flow.',
        'pageCount': 412,
        'language': 'en',
        // Google hands out http:// thumbnails, which Android refuses to load.
        'imageLinks': {'thumbnail': 'http://books.google.com/dune.jpg'},
        'industryIdentifiers': [
          {'type': 'ISBN_10', 'identifier': '0441013597'},
          {'type': 'ISBN_13', 'identifier': '9780441013593'},
        ],
      },
    },
  ],
};

const _olSearch = {
  'numFound': 2,
  'docs': [
    {
      'key': '/works/OL1W',
      'title': 'Dune',
      'author_name': ['Frank Herbert'],
      'first_publish_year': 1965,
      'isbn': ['0441013597', '9780441013593'],
      'publisher': ['Ace'],
      'cover_i': 9,
      'language': ['eng'],
      'number_of_pages_median': 412,
    },
  ],
};

const _olSearchRich = {
  'numFound': 3,
  'docs': [
    {
      'key': '/works/OL1W',
      'title': 'Dune',
      'author_name': ['Frank Herbert'],
      'first_publish_year': 1965,
      'isbn': ['0441013597', '9780441013593'],
      'publisher': ['Ace'],
      'cover_i': 9,
      'language': ['eng'],
      'number_of_pages_median': 412,
    },
    {
      'key': '/works/OL2W',
      'title': 'Dune Messiah',
      'author_name': ['Frank Herbert'],
      'first_publish_year': 1969,
    },
    {
      'key': '/works/OL3W',
      'title': 'Children of Dune',
      'author_name': ['Frank Herbert'],
      'first_publish_year': 1976,
    },
  ],
};

const _googleSearch = {
  'items': [
    {
      'volumeInfo': {
        'title': 'Dune Messiah',
        'authors': ['Frank Herbert'],
        'publishedDate': '1969',
        'pageCount': 256,
        'industryIdentifiers': [
          {'type': 'ISBN_13', 'identifier': '9780441013594'},
        ],
      },
    },
    {
      // The same book Open Library already gave us: it must not double up.
      'volumeInfo': {
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'publishedDate': '1965',
      },
    },
  ],
};

OnlineLookup _lookup(Map<String, Object?> responses) {
  final dio = Dio()..httpClientAdapter = _FakeApis(responses);
  return OnlineLookup(client: dio);
}

void main() {
  group('one ISBN', () {
    test('is normalised before it is asked about', () async {
      final adapter = _FakeApis({_openLibraryBooks: _dune});
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);

      final found = await lookup.lookupIsbn('978-0-441-01359-3');

      expect(found!.title, 'Dune');
      expect(found.isbn, '9780441013593');
      // The server asks every provider for an ISBN and merges the answers, which
      // is exactly what happens here.
      expect(
        adapter.requests.first.queryParameters['bibkeys'],
        'ISBN:9780441013593',
      );
    });

    test('is merged across the providers, Open Library winning', () async {
      final adapter = _FakeApis({
        _openLibraryBooks: _dune,
        _googleVolumes: _googleDune,
      });
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);

      final found = await lookup.lookupIsbn('9780441013593');

      expect(found!.title, 'Dune');
      expect(found.authors, ['Frank Herbert']);
      expect(found.publisher, 'Ace');
      expect(found.publishedDate, '1965');
      expect(found.pageCount, 412);
      expect(found.coverUrl, 'https://covers.openlibrary.org/b/id/9-L.jpg');
      // The description only Google had is picked up, but the record keeps
      // saying where it came from.
      expect(found.description, 'Spice must flow.');
      expect(found.source, 'openlibrary');
      expect(adapter.requests, hasLength(2));
    });

    test('lets Google fill in what Open Library left out', () async {
      // An Open Library record with no description and no language.
      final sparse = {
        'ISBN:9780441013593': {
          'title': 'Dune',
          'authors': [
            {'name': 'Frank Herbert'},
          ],
          'publish_date': '1965',
        },
      };
      final lookup = _lookup({_openLibraryBooks: sparse, _googleVolumes: _googleDune});

      final found = await lookup.lookupIsbn('9780441013593');

      expect(found!.description, 'Spice must flow.');
      expect(found.language, 'en');
      // The earlier provider still owns the record and the values it had.
      expect(found.source, 'openlibrary');
      expect(found.publishedDate, '1965');
    });

    test('falls through to Google when Open Library has never heard of it',
        () async {
      final adapter = _FakeApis({_googleVolumes: _googleDune});
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);

      final found = await lookup.lookupIsbn('9780441013593');

      expect(found!.title, 'Dune');
      expect(found.source, 'googlebooks');
      expect(found.publishedDate, '1965-08-01');
      // Google's thumbnail is upgraded, or the cover would never load.
      expect(found.coverUrl, 'https://books.google.com/dune.jpg');
      expect(adapter.requests, hasLength(2));
    });

    test('survives one provider being down', () async {
      final lookup = _lookup({
        _openLibraryBooks: 503,
        _googleVolumes: _googleDune,
      });
      expect((await lookup.lookupIsbn('9780441013593'))!.title, 'Dune');
    });

    test('is nothing at all when neither provider knows it', () async {
      expect(await _lookup({}).lookupIsbn('9780441013593'), isNull);
    });

    test('is not even asked about when the input is empty', () async {
      final adapter = _FakeApis({_openLibraryBooks: _dune});
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);
      expect(await lookup.lookupIsbn('   '), isNull);
      expect(adapter.requests, isEmpty);
    });
  });

  group('a free-text search', () {
    test('uses Open Library alone when it answers well', () async {
      final adapter = _FakeApis({
        _openLibrarySearch: _olSearchRich,
        _googleVolumes: _googleSearch,
      });
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);

      final results = await lookup.searchBooks('dune');

      // Three hits is enough; Google is left alone.
      expect(adapter.requests.single.path, _openLibrarySearch);
      expect(results, hasLength(3));
      // Open Library carries both ISBNs; the thirteen-digit one wins.
      expect(results.first.isbn, '9780441013593');
      expect(results.first.authors, ['Frank Herbert']);
      expect(results.first.publishedDate, isNull);
      expect(results.first.coverUrl, 'https://covers.openlibrary.org/b/id/9-M.jpg');
      expect(results.first.pageCount, 412);
      expect(results.first.language, 'eng');
      // A document with no ISBN or cover simply has neither.
      expect(results.last.isbn, isNull);
      expect(results.last.coverUrl, isNull);
      expect(results.last.publishedDate, isNull);
    });

    test('brings in Google when Open Library is thin, without repeating titles',
        () async {
      final adapter = _FakeApis({
        _openLibrarySearch: _olSearch,
        _googleVolumes: _googleSearch,
      });
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);

      // One Open Library hit is below the threshold, so Google is asked too.
      final results = await lookup.searchBooks('dune', limit: 10);

      expect(adapter.requests.map((uri) => uri.path), [
        _openLibrarySearch,
        _googleVolumes,
      ]);
      // "Dune Messiah" is new; the second "Dune" is a duplicate and is dropped.
      expect(results.map((result) => result.title), ['Dune', 'Dune Messiah']);
      // The API adds this for clients that cannot handle a list; the app can,
      // so it reads the list and ignores the join.
      expect(results.last.authors, ['Frank Herbert']);
      expect(results.last.isbn, '9780441013594');
      expect(results.last.publishedDate, '1969');
    });

    test('keeps Open Library results when Google is the one that is down',
        () async {
      final lookup = _lookup({_openLibrarySearch: _olSearch, _googleVolumes: 500});
      final results = await lookup.searchBooks('dune');
      expect(results.map((result) => result.title), ['Dune']);
    });

    test('honours the limit', () async {
      final lookup = _lookup({_openLibrarySearch: _olSearch});
      expect(await lookup.searchBooks('dune', limit: 1), hasLength(1));
    });

    test('asks nobody about a blank query', () async {
      final adapter = _FakeApis({_openLibrarySearch: _olSearch});
      final lookup = OnlineLookup(client: Dio()..httpClientAdapter = adapter);
      expect(await lookup.searchBooks('  '), isEmpty);
      expect(adapter.requests, isEmpty);
    });
  });
}
