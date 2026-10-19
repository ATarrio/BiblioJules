/// Talks to a real BiblioJules server.
///
/// The app's data layer is the only thing that can break silently when the
/// server's JSON changes, so this test boots the actual FastAPI app (from the
/// repository this package sits in) against a throwaway SQLite database and
/// drives it through [ApiClient] exactly as the app would.
///
/// It skips itself when the repository's virtualenv is not present.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/core/api_client.dart';
import 'package:bibliojules_mobile/src/core/api_exception.dart';
import 'package:bibliojules_mobile/src/core/models/models.dart';
import 'package:bibliojules_mobile/src/core/util.dart';
import 'package:flutter_test/flutter_test.dart';

const _password = 'test-password-123';

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<bool> _waitForHealth(String baseUrl, {Duration timeout = const Duration(seconds: 60)}) async {
  final deadline = DateTime.now().add(timeout);
  final client = HttpClient();
  while (DateTime.now().isBefore(deadline)) {
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl/health'));
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode == 200) {
        client.close();
        return true;
      }
    } on Object {
      // Not up yet.
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  client.close();
  return false;
}

void main() {
  final repoRoot = Directory.current.parent;
  final python = File('${repoRoot.path}/.venv/bin/python');

  if (!python.existsSync()) {
    // ``skip`` still marks the whole file as skipped rather than passing.
    test('server integration', () {}, skip: 'no .venv in ${repoRoot.path}');
    return;
  }

  late Directory temp;
  late Process server;
  late int port;
  late ApiClient api;
  late String baseUrl;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('bibliojules-mobile-test');
    port = await _freePort();
    baseUrl = 'http://127.0.0.1:$port';
    final databaseUrl = 'sqlite:///${temp.path}/library.db';
    final environment = {
      ...Platform.environment,
      'DATABASE_URL': databaseUrl,
      'ENABLE_DOCS': 'false',
      'PYTHONUNBUFFERED': '1',
    };

    // Seed the database and the first administrator the same way an operator
    // would, using the shared CLI.
    final seed = await Process.run(
      python.path,
      ['-m', 'app.cli', 'create-admin', 'tester', '--password', _password],
      workingDirectory: repoRoot.path,
      environment: environment,
    );
    expect(
      seed.exitCode,
      0,
      reason: 'create-admin failed: ${seed.stdout}\n${seed.stderr}',
    );

    server = await Process.start(
      python.path,
      [
        '-m',
        'uvicorn',
        'app.main:app',
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        '--log-level',
        'warning',
      ],
      workingDirectory: repoRoot.path,
      environment: environment,
    );
    // Keep the pipes drained so the child never blocks on a full buffer.
    server.stdout.listen((_) {});
    server.stderr.listen((_) {});

    final healthy = await _waitForHealth(baseUrl);
    expect(healthy, isTrue, reason: 'the test server never became healthy');

    api = ApiClient(baseUrl: baseUrl);
  });

  tearDownAll(() async {
    api.setToken(null);
    server.kill(ProcessSignal.sigterm);
    await server.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        server.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('authentication', () {
    test('a wrong password is refused', () async {
      await expectLater(
        api.login(username: 'tester', password: 'nope'),
        throwsA(isA<ApiAuthException>()),
      );
    });

    test('the right password yields a token and an account', () async {
      final result = await api.login(
        username: 'tester',
        password: _password,
        label: 'Flutter integration test',
      );
      expect(result.token, startsWith('bj_'));
      expect(result.user.username, 'tester');
      expect(result.user.isAdmin, isTrue);
      expect(result.expiresAt, isNotNull);
      api.setToken(result.token);

      final me = await api.me();
      expect(me.id, result.user.id);
      expect(me.isActive, isTrue);
    });

    test('the API needs the token', () async {
      final anonymous = ApiClient(baseUrl: baseUrl);
      await expectLater(anonymous.listBooks(), throwsA(isA<ApiAuthException>()));
    });
  });

  group('locations', () {
    late int officeId;
    late int shelfId;

    test('create a root and a child', () async {
      final office = await api.createLocation(
        name: 'Office',
        kind: 'Room',
        description: 'The quiet one',
      );
      expect(office.name, 'Office');
      officeId = office.id;

      final shelf = await api.createLocation(
        name: 'Shelf A',
        parentId: officeId,
        kind: 'Shelf',
      );
      expect(shelf.parentId, officeId);
      shelfId = shelf.id;

      final all = await api.listLocations();
      expect(all.map((location) => location.name), containsAll(['Office', 'Shelf A']));
      expect(
        all.firstWhere((location) => location.id == officeId).fullPath,
        contains('Office'),
      );
    });

    test('renaming keeps the tree intact', () async {
      final updated = await api.updateLocation(
        shelfId,
        name: 'Shelf B',
        parentId: officeId,
        kind: 'Shelf',
      );
      expect(updated.name, 'Shelf B');
      expect(updated.parentId, officeId);
    });

    test('unknown locations are a 404', () async {
      await expectLater(
        api.updateLocation(9999, name: 'Ghost'),
        throwsA(isA<ApiNotFoundException>()),
      );
    });
  });

  group('statuses', () {
    late int statusId;

    test('the library starts with seeded shelves', () async {
      final statuses = await api.listStatuses();
      expect(statuses, isNotEmpty);
      expect(Status.defaultOf(statuses), isNotNull);
    });

    test('create, rename and delete one', () async {
      final created = await api.createStatus(
        name: 'Signed',
        color: '#f59e0b',
        description: 'Author signed',
      );
      statusId = created.id;
      expect(created.name, 'Signed');

      final updated = await api.updateStatus(
        statusId,
        name: 'Signed copies',
        color: '#f59e0b',
        description: 'Author signed',
      );
      expect(updated.name, 'Signed copies');

      expect(await api.deleteStatus(statusId), isTrue);
      final after = await api.listStatuses();
      expect(after.any((status) => status.id == statusId), isFalse);
    });
  });

  group('the catalogue', () {
    late int bookId;
    late int statusId;

    setUpAll(() async {
      final statuses = await api.listStatuses();
      statusId = Status.defaultOf(statuses)!.id;
    });

    test('starts empty', () async {
      expect(await api.listBooks(), isEmpty);
    });

    test('adding a book stores every field', () async {
      final locations = await api.listLocations();
      final book = await api.createBook({
        'title': 'Dune',
        'subtitle': 'Book One',
        'authors': 'Frank Herbert',
        'isbn': '9780441013593',
        'publisher': 'Ace',
        'published_date': '1965-08',
        'page_count': 412,
        'language': 'eng',
        'cover_type': 'paperback',
        'read_status': 'currently_reading',
        'score': 4.5,
        'saga': 'Dune',
        'saga_number': 1,
        'location_id': locations.first.id,
        'status_id': statusId,
        'notes': 'First printing',
      });
      bookId = book.id;
      expect(book.title, 'Dune');
      expect(book.authors, ['Frank Herbert']);
      expect(book.publishedDate, '1965-08');
      expect(book.publishedYear, 1965);
      expect(book.score, 4.5);
      expect(book.saga, 'Dune');
      expect(book.sagaNumber, 1);
      expect(book.coverType, 'paperback');
      expect(book.readStatus, 'currently_reading');
      expect(book.location?.id, locations.first.id);
      expect(book.status?.id, statusId);
    });

    test('reading it back matches', () async {
      final book = await api.getBook(bookId);
      expect(book.isbn, '9780441013593');
      expect(book.publisher, 'Ace');
      expect(book.pageCount, 412);
      expect(book.notes, 'First printing');
      expect(book.isLoaned, isFalse);
    });

    test('ISBN lookup finds it, and misses return null', () async {
      final found = await api.findByIsbn('9780441013593');
      expect(found?.id, bookId);
      expect(await api.findByIsbn('9999999999999'), isNull);
    });

    test('updating sends only what changed', () async {
      final updated = await api.updateBook(bookId, {
        'read_status': 'read',
        'score': 5.0,
        'saga_number': 2,
      });
      expect(updated.readStatus, 'read');
      expect(updated.score, 5);
      expect(updated.sagaNumber, 2);
      // Untouched fields survive.
      expect(updated.title, 'Dune');
      expect(updated.publisher, 'Ace');
    });

    test('clearing a field sends null', () async {
      final cleared = await api.updateBook(bookId, {'saga_number': null, 'notes': null});
      expect(cleared.sagaNumber, isNull);
      expect(cleared.notes, isNull);
      expect(cleared.saga, 'Dune');
    });

    test('the filters the app sends work', () async {
      await api.createBook({'title': 'Foundation', 'authors': 'Isaac Asimov', 'read_status': 'unread'});

      expect((await api.listBooks(readStatus: 'read')).map((book) => book.title), ['Dune']);
      expect(
        (await api.listBooks(readStatus: 'unread')).map((book) => book.title),
        ['Foundation'],
      );
      expect((await api.listBooks(saga: 'Dune')).map((book) => book.title), ['Dune']);
      expect((await api.listBooks(search: 'asimov')).map((book) => book.title), ['Foundation']);
      expect(
        (await api.listBooks(sort: 'title', direction: 'asc')).map((book) => book.title),
        ['Dune', 'Foundation'],
      );
      expect(
        (await api.listBooks(sort: 'saga', direction: 'asc')).map((book) => book.title),
        ['Dune', 'Foundation'],
      );
    });

    test('the sidebar vocabularies are populated', () async {
      expect(await api.listSagas(), contains('Dune'));
      expect((await api.listAuthors()).map((author) => author.name), contains('Frank Herbert'));
      expect((await api.listPublishers()).map((pub) => pub.name), contains('Ace'));
    });
  });

  group('loans', () {
    late int bookId;

    setUpAll(() async {
      final books = await api.listBooks(search: 'Dune');
      bookId = books.first.id;
    });

    test('lending marks the book as out', () async {
      final loan = await api.lendBook(
        bookId,
        borrowerName: 'Ana',
        borrowerContact: 'ana@example.test',
        lentAt: '2024-05-01',
        dueAt: '2024-05-20',
        notes: 'Please return',
      );
      expect(loan.borrowerName, 'Ana');
      expect(loan.isActive, isTrue);

      final book = await api.getBook(bookId);
      expect(book.isLoaned, isTrue);
      expect(book.activeLoan?.borrowerName, 'Ana');

      expect(await api.bookLoans(bookId), hasLength(1));
      expect((await api.listBooks(loaned: 'loaned')).map((book) => book.id), [bookId]);
      expect((await api.listBooks(loaned: 'available')).any((book) => book.id == bookId), isFalse);
    });

    test('the dashboard shows the loan', () async {
      final data = await api.dashboard();
      expect(data.stats.total, greaterThanOrEqualTo(2));
      expect(data.stats.loans, 1);
      expect(data.activeLoans.map((entry) => entry.bookTitle), contains('Dune'));
      expect(data.recent, isNotEmpty);
      expect(data.statusCounts, isNotEmpty);
    });

    test('returning it puts the book back', () async {
      await api.returnBook(bookId);
      final book = await api.getBook(bookId);
      expect(book.isLoaned, isFalse);
      final loans = await api.bookLoans(bookId);
      expect(loans.single.isActive, isFalse);
      expect(loans.single.returnedAt, isNotNull);
      expect((await api.listBooks(loaned: 'loaned')), isEmpty);
    });
  });

  group('cleanup and sign-out', () {
    test('deleting a book removes it', () async {
      for (final book in await api.listBooks()) {
        expect(await api.deleteBook(book.id), isTrue);
      }
      expect(await api.listBooks(), isEmpty);
      await expectLater(api.getBook(999999), throwsA(isA<ApiNotFoundException>()));
    });

    test('deleting the locations leaves none behind', () async {
      // Deleting a parent takes its children with it, so unwind deepest-first.
      final ordered = orderedLocations(await api.listLocations()).reversed;
      for (final (location, _) in ordered) {
        expect(await api.deleteLocation(location.id), isTrue);
      }
      expect(await api.listLocations(), isEmpty);
    });

    test('signing out revokes the token', () async {
      await api.logout();
      await expectLater(api.me(), throwsA(isA<ApiAuthException>()));
    });
  });
}
