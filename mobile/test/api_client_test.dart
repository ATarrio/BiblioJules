import 'dart:convert';
import 'dart:typed_data';

import 'package:bibliojules_mobile/src/core/api_client.dart';
import 'package:bibliojules_mobile/src/core/api_exception.dart';
import 'package:bibliojules_mobile/src/core/models/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the network: every request gets a canned reply, and the test
/// can look at exactly what the client sent.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options, Object? body)
  handler;

  RequestOptions? request;
  Object? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final bytes = chunks.expand((chunk) => chunk).toList();
      final text = utf8.decode(bytes, allowMalformed: true);
      final contentType = options.contentType ?? '';
      body = contentType.contains('json') && text.isNotEmpty
          ? json.decode(text)
          : bytes;
    } else {
      body = null;
    }
    return handler(options, body);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? data, int statusCode) => ResponseBody.fromString(
  json.encode(data),
  statusCode,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

(ApiClient, _FakeAdapter) _client(
  Future<ResponseBody> Function(RequestOptions options, Object? body) handler, {
  String baseUrl = 'https://library.example.com',
  String? token,
}) {
  final adapter = _FakeAdapter(handler);
  final dio = Dio()..httpClientAdapter = adapter;
  return (ApiClient(baseUrl: baseUrl, token: token, dio: dio), adapter);
}

void main() {
  group('normalizeBaseUrl', () {
    test('leaves a complete URL alone', () {
      expect(
        normalizeBaseUrl('https://library.example.com'),
        'https://library.example.com',
      );
      expect(
        normalizeBaseUrl('https://library.example.com/'),
        'https://library.example.com',
      );
      expect(
        normalizeBaseUrl('  https://library.example.com/library/// '),
        'https://library.example.com/library',
      );
    });

    test('assumes https for a public host and http for a private one', () {
      expect(
        normalizeBaseUrl('library.example.com'),
        'https://library.example.com',
      );
      expect(normalizeBaseUrl('localhost:8000'), 'http://localhost:8000');
      expect(normalizeBaseUrl('127.0.0.1:8000'), 'http://127.0.0.1:8000');
      expect(normalizeBaseUrl('10.0.2.2:8000'), 'http://10.0.2.2:8000');
      expect(normalizeBaseUrl('192.168.1.20:8000'), 'http://192.168.1.20:8000');
      expect(normalizeBaseUrl('172.16.5.5'), 'http://172.16.5.5');
      expect(normalizeBaseUrl('nas'), 'http://nas');
    });
  });

  group('isValidBaseUrl', () {
    test('accepts real addresses and rejects empty input', () {
      expect(isValidBaseUrl('https://library.example.com'), isTrue);
      expect(isValidBaseUrl('10.0.2.2:8000'), isTrue);
      expect(isValidBaseUrl(''), isFalse);
      expect(isValidBaseUrl('   '), isFalse);
    });
  });

  group('login', () {
    test('posts the credentials and reads the token back', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(
          _json({
            'token': 'bj_abc',
            'expires_at': '2026-01-01T00:00:00+00:00',
            'user': {
              'id': 1,
              'username': 'ana',
              'role': 'admin',
              'is_admin': true,
            },
          }, 200),
        ),
      );
      final result = await api.login(
        username: 'ana',
        password: 'secret',
        label: 'Test',
      );
      expect(result.token, 'bj_abc');
      expect(result.user.username, 'ana');
      expect(result.user.isAdmin, isTrue);
      expect(adapter.request?.path, '/api/auth/login');
      expect(adapter.body, {
        'username': 'ana',
        'password': 'secret',
        'label': 'Test',
      });
    });

    test('turns a 401 into ApiAuthException with the server message', () async {
      final (api, _) = _client(
        (options, body) => Future.value(
          _json({'detail': 'Incorrect username or password.'}, 401),
        ),
      );
      await expectLater(
        api.login(username: 'ana', password: 'nope'),
        throwsA(
          isA<ApiAuthException>().having(
            (error) => error.message,
            'message',
            'Incorrect username or password.',
          ),
        ),
      );
    });
  });

  group('tokens and headers', () {
    test('sends the bearer token once it has one', () async {
      final (api, adapter) = _client(
        (options, body) =>
            Future.value(_json({'id': 1, 'username': 'ana'}, 200)),
        token: 'bj_abc',
      );
      await api.me();
      expect(adapter.request?.headers['Authorization'], 'Bearer bj_abc');
    });

    test('does not send an Authorization header without a token', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(_json([], 200)),
      );
      api.setToken('');
      expect(api.hasToken, isFalse);
      await api.listStatuses();
      expect(adapter.request?.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('error mapping', () {
    test('422 joins the validation problems', () async {
      final (api, _) = _client(
        (options, body) => Future.value(
          _json({
            'detail': [
              {
                'loc': ['body', 'title'],
                'msg': 'field required',
              },
            ],
          }, 422),
        ),
      );
      await expectLater(
        api.createBook({'title': null}),
        throwsA(
          isA<ApiValidationException>().having(
            (error) => error.message,
            'message',
            'title: field required',
          ),
        ),
      );
    });

    test('404 becomes ApiNotFoundException', () async {
      final (api, _) = _client(
        (options, body) => Future.value(_json({'detail': 'Not found.'}, 404)),
      );
      await expectLater(api.getBook(999), throwsA(isA<ApiNotFoundException>()));
    });

    test('lookups treat 404 as "no such book"', () async {
      final (api, _) = _client(
        (options, body) => Future.value(_json({'detail': 'Not found.'}, 404)),
      );
      expect(await api.findByIsbn('9780441013593'), isNull);
    });

    test('an unreachable server becomes ApiConnectionException', () async {
      final (api, _) = _client(
        (options, body) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'connection refused',
        ),
      );
      await expectLater(
        api.listBooks(),
        throwsA(isA<ApiConnectionException>()),
      );
    });

    test('a timeout becomes ApiConnectionException', () async {
      final (api, _) = _client(
        (options, body) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        ),
      );
      await expectLater(
        api.dashboard(),
        throwsA(isA<ApiConnectionException>()),
      );
    });
  });

  group('books', () {
    test('listBooks sends the filters and reads items', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(
          _json({
            'items': [
              {
                'id': 1,
                'title': 'Dune',
                'authors': ['Frank Herbert'],
              },
              {
                'id': 2,
                'title': 'Dune Messiah',
                'authors': ['Frank Herbert'],
              },
            ],
          }, 200),
        ),
      );
      final books = await api.listBooks(
        search: 'dune',
        readStatus: 'read',
        locationId: 3,
        saga: 'Dune',
        sort: 'title',
        direction: 'asc',
      );
      expect(books.map((book) => book.id), [1, 2]);
      expect(adapter.request?.path, '/api/books');
      expect(adapter.request?.queryParameters, {
        'search': 'dune',
        'read_status': 'read',
        'location': 3,
        'saga': 'Dune',
        'sort': 'title',
        'dir': 'asc',
        'limit': 500,
        'offset': 0,
      });
    });

    test('leaves out the filters that are not set', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(_json({'items': []}, 200)),
      );
      await api.listBooks(sort: 'recent');
      expect(adapter.request?.queryParameters, {
        'sort': 'recent',
        'limit': 500,
        'offset': 0,
      });
    });

    test('listBooks walks every page a paginated server returns', () async {
      var calls = 0;
      final (api, _) = _client((options, body) {
        calls += 1;
        final offset = options.queryParameters['offset'] as int;
        return Future.value(
          _json({
            'count': 2,
            'items': [
              {
                'id': offset + 1,
                'title': offset == 0 ? 'Dune' : 'Dune Messiah',
                'authors': ['Frank Herbert'],
              },
            ],
          }, 200),
        );
      });
      final books = await api.listBooks();
      expect(books.map((book) => book.id), [1, 2]);
      expect(calls, 2);
    });

    test('createBook posts the payload', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(
          _json({
            'id': 5,
            'title': 'Dune',
            'authors': ['Frank Herbert'],
          }, 201),
        ),
      );
      final book = await api.createBook({'title': 'Dune', 'score': 4.5});
      expect(book.id, 5);
      expect(adapter.request?.method, 'POST');
      expect(adapter.body, {'title': 'Dune', 'score': 4.5});
    });

    test('updateBook puts to the book', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(_json({'id': 5, 'title': 'Dune'}, 200)),
      );
      await api.updateBook(5, {'read_status': 'read'});
      expect(adapter.request?.method, 'PUT');
      expect(adapter.request?.path, '/api/books/5');
    });

    test('deleteBook tolerates an empty 204', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(ResponseBody.fromString('', 204)),
      );
      expect(await api.deleteBook(5), isTrue);
      expect(adapter.request?.method, 'DELETE');
    });

    test('lendBook sends the borrower and the fulfilment flags', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(
          _json({
            'id': 3,
            'book_id': 5,
            'borrower_name': 'Ana',
            'lent_at': '2024-05-01',
            'is_active': true,
          }, 201),
        ),
      );
      final loan = await api.lendBook(
        5,
        borrowerName: 'Ana',
        lentAt: '2024-05-01',
        markStatus: false,
      );
      expect(loan.borrowerName, 'Ana');
      expect(adapter.body, {
        'borrower_name': 'Ana',
        'borrower_contact': null,
        'lent_at': '2024-05-01',
        'due_at': null,
        'notes': null,
        'mark_status': false,
      });
    });

    test('findByIsbn escapes the ISBN in the path', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(_json({'id': 5, 'title': 'Dune'}, 200)),
      );
      await api.findByIsbn('978 0441 013593');
      expect(adapter.request?.path, '/api/books/by-isbn/978%200441%20013593');
    });
  });

  group('reference data', () {
    test('sagas come back as plain strings', () async {
      final (api, _) = _client(
        (options, body) => Future.value(_json(['Dune', 'Foundation'], 200)),
      );
      expect(await api.listSagas(), ['Dune', 'Foundation']);
    });

    test('authors are id/name pairs', () async {
      final (api, _) = _client(
        (options, body) => Future.value(
          _json([
            {'id': 1, 'name': 'Frank Herbert'},
          ], 200),
        ),
      );
      final authors = await api.listAuthors();
      expect(authors.single.id, 1);
      expect(authors.single.name, 'Frank Herbert');
    });

    test('deleting a status posts to its delete route', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(ResponseBody.fromString('', 204)),
      );
      expect(await api.deleteStatus(4), isTrue);
      expect(adapter.request?.method, 'POST');
      expect(adapter.request?.path, '/api/statuses/4/delete');
    });

    test('deleting a location posts to its delete route', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(ResponseBody.fromString('', 204)),
      );
      expect(await api.deleteLocation(4), isTrue);
      expect(adapter.request?.method, 'POST');
      expect(adapter.request?.path, '/api/locations/4/delete');
    });
  });

  group('lookups', () {
    test('an ISBN lookup that finds nothing returns null', () async {
      final (api, _) = _client(
        (options, body) =>
            Future.value(_json({'detail': 'No book found.'}, 404)),
      );
      expect(await api.lookupIsbn('123'), isNull);
    });

    test('online search passes the query and limit', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(
          _json([
            {
              'title': 'Dune',
              'authors': ['Frank Herbert'],
            },
          ], 200),
        ),
      );
      final results = await api.searchBooks('dune', limit: 5);
      expect(results.single.title, 'Dune');
      expect(adapter.request?.queryParameters, {'q': 'dune', 'limit': 5});
    });
  });

  group('reading data', () {
    test('reads and writes goals', () async {
      final (api, adapter) = _client((options, body) {
        if (options.method == 'POST') {
          return Future.value(_json({'ok': true}, 200));
        }
        return Future.value(
          _json([
            {
              'year': 2026,
              'target_books': 12,
              'target_pages': 3000,
              'books_done': 2,
              'pages_done': 500,
            },
          ], 200),
        );
      });

      final goals = await api.readingGoals();
      expect(goals.length, 1);
      expect(goals.first.year, 2026);
      expect(goals.first.targetBooks, 12);
      await api.saveReadingGoals(
        const ReadingGoals(year: 2027, targetBooks: 20, targetPages: 5000),
      );
      expect(adapter.request?.path, '/api/goals');
      expect(adapter.request?.method, 'POST');
      expect(adapter.body, {
        'year': 2027,
        'target_books': 20,
        'target_pages': 5000,
        'books_done': 0,
        'pages_done': 0,
      });

      await api.removeReadingGoal(2026);
      expect(adapter.request?.path, '/api/goals/2026');
      expect(adapter.request?.method, 'DELETE');
    });

    test('reads and changes the want list', () async {
      final (api, adapter) = _client((options, body) {
        if (options.method == 'GET') {
          return Future.value(
            _json([
              {'id': 'want-1', 'title': 'Ubik', 'authors': 'Philip K. Dick'},
            ], 200),
          );
        }
        return Future.value(_json({'ok': true}, 200));
      });

      final entries = await api.wantList();
      expect(entries.single.title, 'Ubik');
      await api.addWant(const WantEntry(id: 'want-2', title: 'Dune'));
      expect(adapter.request?.path, '/api/wantlist');
      expect(adapter.body, containsPair('title', 'Dune'));
      await api.removeWant('want-2');
      expect(adapter.request?.path, '/api/wantlist/want-2');
      expect(adapter.request?.method, 'DELETE');
    });

    test('makes server cover URLs absolute', () async {
      final (api, _) = _client(
        (options, body) => Future.value(
          _json({
            'items': [
              {'id': 1, 'title': 'Dune', 'cover_url': '/covers/dune.png'},
            ],
            'count': 1,
          }, 200),
        ),
      );
      final books = await api.listBooks();
      expect(
        books.single.coverUrl,
        'https://library.example.com/covers/dune.png',
      );
    });

    test('uploads a cover as multipart and reads the updated book', () async {
      final (api, adapter) = _client(
        (options, body) => Future.value(
          _json({
            'id': 1,
            'title': 'Dune',
            'cover_url': '/covers/dune.png',
          }, 200),
        ),
      );
      final book = await api.uploadCover(
        1,
        filename: 'cover.png',
        bytes: [0x89, 0x50, 0x4E, 0x47],
      );
      expect(adapter.request?.path, '/api/books/1/cover');
      expect(adapter.request?.method, 'POST');
      expect(adapter.request?.contentType, contains('multipart/form-data'));
      expect(book.coverUrl, 'https://library.example.com/covers/dune.png');
    });
  });
}
