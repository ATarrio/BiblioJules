/// Exercises the on-device store against a real SQLite database.
///
/// This runs on the desktop with `sqflite_common_ffi`, so the SQL is genuine —
/// constraints, cascades and all — while the Android plugin is not involved.
/// The behaviour it pins down is the behaviour of ``app/services/library.py``,
/// so a difference between phone and server shows up here.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/core/api_exception.dart';
import 'package:bibliojules_mobile/src/core/models/models.dart';
import 'package:bibliojules_mobile/src/local/local_repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<LocalRepo> _open(Directory dir, [String name = 'My library']) async {
  final repo = LocalRepo(documentsDirectory: () async => dir);
  await repo.open(name);
  return repo;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late LocalRepo repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bibliojules_local');
    repo = await _open(dir);
  });

  tearDown(() async {
    await repo.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('opening a library', () {
    test('a new library is seeded with the six system statuses', () async {
      final statuses = await repo.listStatuses();
      expect(statuses.map((s) => s.slug), [
        'available',
        'reading',
        'lent',
        'wishlist',
        'lost',
        'donated',
      ]);
      expect(statuses.every((s) => s.isSystem), isTrue);
      expect(Status.defaultOf(statuses)?.slug, 'available');
    });

    test('reopening the same library keeps what was in it', () async {
      await repo.createBook({'title': 'Dune', 'authors': ['Frank Herbert']});
      await repo.close();

      final reopened = await _open(dir);
      addTearDown(reopened.dispose);
      final books = await reopened.listBooks();
      expect(books.single.title, 'Dune');
      expect(books.single.authors, ['Frank Herbert']);
    });

    test('a library name becomes a file name', () async {
      await repo.close();
      repo = await _open(dir, 'Mi biblioteca');
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toList();
      expect(files, contains('mi-biblioteca.sqlite'));
    });
  });

  group('creating books', () {
    test('a bare title still gets a title, a default status and timestamps',
        () async {
      final book = await repo.createBook({});
      expect(book.title, 'Untitled');
      expect(book.status?.slug, 'available');
      expect(book.createdAt, isNotEmpty);
      expect(book.updatedAt, isNotEmpty);
    });

    test('every field survives the round trip', () async {
      final created = await repo.createBook({
        'title': 'Dune',
        'subtitle': 'Book One',
        'isbn': '978-0-441-01359-3',
        'authors': 'Frank Herbert, Kevin J. Anderson',
        'publisher': 'Ace',
        'published_date': '1965',
        'description': 'Spice.',
        'page_count': 412,
        'language': 'eng',
        'cover_url': 'https://example.org/dune.jpg',
        'cover_type': 'paperback',
        'read_status': 'read',
        'score': 4.5,
        'saga': 'Dune',
        'saga_number': 1,
        'notes': 'signed',
        'source': 'openlibrary',
      });

      final book = await repo.getBook(created.id);
      expect(book.isbn, '9780441013593');
      expect(book.authors, ['Frank Herbert', 'Kevin J. Anderson']);
      expect(book.publisher, 'Ace');
      expect(book.publishedDate, '1965');
      expect(book.publishedYear, 1965);
      expect(book.description, 'Spice.');
      expect(book.pageCount, 412);
      expect(book.language, 'eng');
      expect(book.coverUrl, 'https://example.org/dune.jpg');
      expect(book.coverType, 'paperback');
      expect(book.readStatus, 'read');
      expect(book.score, 4.5);
      expect(book.saga, 'Dune');
      expect(book.sagaNumber, 1);
      expect(book.notes, 'signed');
      expect(book.source, 'openlibrary');
    });

    test('unknown vocabulary is dropped rather than stored', () async {
      final book = await repo.createBook({
        'title': 'Weird',
        'cover_type': 'scroll',
        'read_status': 'half-read',
        'score': 0,
        'saga': '   ',
        'page_count': 'many',
      });
      expect(book.coverType, isNull);
      expect(book.readStatus, isNull);
      expect(book.score, isNull);
      expect(book.saga, isNull);
      expect(book.pageCount, isNull);
    });

    test('a score is snapped to half stars and clamped', () async {
      final low = await repo.createBook({'title': 'Low', 'score': 0.4});
      expect(low.score, 1.0);
      final high = await repo.createBook({'title': 'High', 'score': 9});
      expect(high.score, 5.0);
      // Python rounds halves to even, and so do we.
      final quarter = await repo.createBook({'title': 'Quarter', 'score': 4.25});
      expect(quarter.score, 4.0);
      final comma = await repo.createBook({'title': 'Comma', 'score': '3,5'});
      expect(comma.score, 3.5);
    });

    test('a year-only published_year fills in the date field', () async {
      final book = await repo.createBook({
        'title': 'Yearly',
        'published_year': 2019,
      });
      expect(book.publishedDate, '2019');
      expect(book.publishedYear, 2019);
    });

    test('an unreadable date keeps the supplied year', () async {
      final book = await repo.createBook({
        'title': 'Roman',
        'published_date': 'MMV',
        'published_year': 2005,
      });
      expect(book.publishedDate, 'MMV');
      expect(book.publishedYear, 2005);
    });
  });

  group('editing books', () {
    test('only the fields sent are touched', () async {
      final created = await repo.createBook({
        'title': 'Dune',
        'notes': 'keep me',
        'score': 4.0,
      });
      final updated = await repo.updateBook(created.id, {'title': 'Dune!'});
      expect(updated.title, 'Dune!');
      expect(updated.notes, 'keep me');
      expect(updated.score, 4.0);
    });

    test('an explicit null clears a value', () async {
      final created = await repo.createBook({'title': 'Dune', 'notes': 'x'});
      final updated = await repo.updateBook(created.id, {'notes': null});
      expect(updated.notes, isNull);
    });

    test('replacing authors strands the old ones', () async {
      final created = await repo.createBook({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
      });
      await repo.updateBook(created.id, {
        'authors': ['Kevin J. Anderson'],
      });
      expect((await repo.listAuthors()).map((a) => a.name), [
        'Kevin J. Anderson',
      ]);
    });

    test('the same author name is not duplicated', () async {
      await repo.createBook({'title': 'A', 'authors': ['Frank Herbert']});
      await repo.createBook({'title': 'B', 'authors': ['frank herbert']});
      expect(await repo.listAuthors(), hasLength(1));
    });

    test('deleting a book removes it and its orphans', () async {
      final created = await repo.createBook({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'publisher': 'Ace',
      });
      await repo.deleteBook(created.id);
      expect(await repo.listBooks(), isEmpty);
      expect(await repo.listAuthors(), isEmpty);
      expect(await repo.listPublishers(), isEmpty);
    });

    test('a missing book raises a not-found error', () async {
      expect(
        () => repo.getBook(4242),
        throwsA(isA<ApiNotFoundException>()),
      );
    });
  });

  group('searching, filtering and sorting', () {
    setUp(() async {
      await repo.createBook({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'publisher': 'Ace',
        'published_date': '1965',
        'read_status': 'read',
      });
      await repo.createBook({
        'title': 'Neuromancer',
        'authors': ['William Gibson'],
        'publisher': 'Ace',
        'published_date': '1984',
        'read_status': 'unread',
      });
      await repo.createBook({
        'title': 'The Hobbit',
        'authors': ['J. R. R. Tolkien'],
        'isbn': '9780261102217',
      });
    });

    test('search covers title, author, publisher and ISBN', () async {
      expect((await repo.listBooks(search: 'dune')).single.title, 'Dune');
      expect((await repo.listBooks(search: 'gibson')).single.title, 'Neuromancer');
      expect(await repo.listBooks(search: 'ace'), hasLength(2));
      expect(
        (await repo.listBooks(search: '9780261102217')).single.title,
        'The Hobbit',
      );
      expect(await repo.listBooks(search: 'nothing here'), isEmpty);
    });

    test('a book matching twice is returned once', () async {
      // The title and the author both contain "herbert".
      await repo.updateBook(
        (await repo.listBooks(search: 'dune')).single.id,
        {'title': 'Herbert: a life'},
      );
      expect(await repo.listBooks(search: 'herbert'), hasLength(1));
    });

    test('read status filters', () async {
      expect(await repo.listBooks(readStatus: 'read'), hasLength(1));
      expect(await repo.listBooks(readStatus: 'unread'), hasLength(1));
      // An unknown slug is ignored rather than returning nothing.
      expect(await repo.listBooks(readStatus: 'nonsense'), hasLength(3));
    });

    test('author and publisher filters', () async {
      final gibson = (await repo.listAuthors())
          .firstWhere((a) => a.name == 'William Gibson');
      expect(
        (await repo.listBooks(authorId: gibson.id)).single.title,
        'Neuromancer',
      );
      final ace = (await repo.listPublishers()).firstWhere((p) => p.name == 'Ace');
      expect(await repo.listBooks(publisherId: ace.id), hasLength(2));
    });

    test('title sort is case-insensitive', () async {
      final titles = (await repo.listBooks(sort: 'title'))
          .map((b) => b.title)
          .toList();
      expect(titles, ['Dune', 'Neuromancer', 'The Hobbit']);
    });

    test('year sort puts newest first and unknown years last', () async {
      final titles = (await repo.listBooks(sort: 'year'))
          .map((b) => b.title)
          .toList();
      expect(titles, ['Neuromancer', 'Dune', 'The Hobbit']);
    });

    test('author sort uses the first author name', () async {
      final authors = (await repo.listBooks(sort: 'author'))
          .map((b) => b.authors.first)
          .toList();
      expect(authors, ['Frank Herbert', 'J. R. R. Tolkien', 'William Gibson']);
    });

    test('saga sort orders by name then number', () async {
      await repo.createBook({
        'title': 'Dune Messiah',
        'saga': 'Dune',
        'saga_number': 2,
      });
      await repo.createBook({
        'title': 'Dune: House Atreides',
        'saga': 'Dune',
        'saga_number': 1,
      });
      await repo.createBook({'title': 'Ubik'});
      final titles = (await repo.listBooks(sort: 'saga'))
          .map((b) => b.title)
          .toList();
      // The saga's books come first, in reading order; books with no saga last.
      expect(titles.take(2), ['Dune: House Atreides', 'Dune Messiah']);
      expect(titles.last, 'Ubik');
      expect(await repo.listSagas(), ['Dune']);
    });

    test('an explicit direction overrides the natural one', () async {
      final titles = (await repo.listBooks(sort: 'title', direction: 'desc'))
          .map((b) => b.title)
          .toList();
      expect(titles, ['The Hobbit', 'Neuromancer', 'Dune']);
    });
  });

  group('loans', () {
    test('lending marks the book and returning restores it', () async {
      final book = await repo.createBook({'title': 'Dune'});
      final loan = await repo.lendBook(
        book.id,
        borrowerName: 'Ana',
        borrowerContact: 'ana@example.org',
        dueAt: '2999-01-01',
        notes: 'careful',
      );
      expect(loan.isActive, isTrue);
      expect(loan.isOverdue, isFalse);
      expect(loan.lentAt, isNotEmpty);

      final lent = await repo.getBook(book.id);
      expect(lent.status?.slug, 'lent');
      expect(lent.activeLoan?.borrowerName, 'Ana');
      expect(lent.isLoaned, isTrue);

      await repo.returnBook(book.id);
      final returned = await repo.getBook(book.id);
      expect(returned.status?.slug, 'available');
      expect(returned.activeLoan, isNull);
      expect(await repo.bookLoans(book.id), hasLength(1));
      expect((await repo.bookLoans(book.id)).single.returnedAt, isNotEmpty);
    });

    test('an overdue loan is flagged', () async {
      final book = await repo.createBook({'title': 'Dune'});
      final loan = await repo.lendBook(
        book.id,
        borrowerName: 'Ana',
        dueAt: '2000-01-01',
      );
      expect(loan.isOverdue, isTrue);
    });

    test('loaned and available filters', () async {
      final dune = await repo.createBook({'title': 'Dune'});
      await repo.createBook({'title': 'Ubik'});
      await repo.lendBook(dune.id, borrowerName: 'Ana');

      expect((await repo.listBooks(loaned: 'loaned')).single.title, 'Dune');
      expect((await repo.listBooks(loaned: 'available')).single.title, 'Ubik');
    });

    test('lending can leave the status alone', () async {
      final book = await repo.createBook({'title': 'Dune', 'status_id': null});
      await repo.lendBook(book.id, borrowerName: 'Ana', markStatus: false);
      expect((await repo.getBook(book.id)).status?.slug, 'available');
    });
  });

  group('locations', () {
    test('a tree is stored, flattened with paths, and cascades on delete',
        () async {
      final room = await repo.createLocation(name: 'Living room');
      final shelf = await repo.createLocation(
        name: 'Shelf B',
        parentId: room.id,
      );
      final box = await repo.createLocation(name: 'Box 1', parentId: shelf.id);
      final book = await repo.createBook({'title': 'Dune'});
      await repo.updateBook(book.id, {'location_id': box.id});

      final locations = await repo.listLocations();
      expect(locations.map((l) => l.fullPath), [
        'Living room',
        'Living room / Shelf B',
        'Living room / Shelf B / Box 1',
      ]);

      // Filtering by an ancestor finds books on its descendants.
      expect(await repo.listBooks(locationId: room.id), hasLength(1));
      expect(await repo.listBooks(locationId: box.id), hasLength(1));

      // Deleting a shelf takes its children with it and unshelves the book.
      await repo.deleteLocation(shelf.id);
      expect(await repo.listLocations(), hasLength(1));
      expect((await repo.getBook(book.id)).locationId, isNull);
    });

    test('a location cannot be moved inside itself', () async {
      final room = await repo.createLocation(name: 'Living room');
      final shelf = await repo.createLocation(name: 'Shelf B', parentId: room.id);
      expect(
        () => repo.updateLocation(room.id, name: 'Living room', parentId: shelf.id),
        throwsA(isA<ApiValidationException>()),
      );
    });

    test('renaming without a kind keeps the old kind', () async {
      final shelf = await repo.createLocation(name: 'Shelf', kind: 'shelf');
      final renamed = await repo.updateLocation(shelf.id, name: 'Shelf A');
      expect(renamed.name, 'Shelf A');
      expect(renamed.kind, 'shelf');
    });

    test('a missing location raises a not-found error', () async {
      expect(
        () => repo.deleteLocation(7),
        throwsA(isA<ApiNotFoundException>()),
      );
    });
  });

  group('statuses', () {
    test('a new status gets a unique slug and the next sort order', () async {
      final first = await repo.createStatus(name: 'Signed', color: '#ff0000');
      expect(first.slug, 'signed');
      expect(first.isSystem, isFalse);
      expect(first.sortOrder, 70);

      // A different name can still slugify to something taken.
      final second = await repo.createStatus(name: 'Signed!');
      expect(second.slug, 'signed-2');
    });

    test('a duplicate name is refused, whatever the case', () async {
      await repo.createStatus(name: 'Signed');
      expect(
        () => repo.createStatus(name: 'signed'),
        throwsA(isA<ApiValidationException>()),
      );
    });

    test('a blank name is refused', () async {
      expect(
        () => repo.createStatus(name: '   '),
        throwsA(isA<ApiValidationException>()),
      );
    });

    test('system statuses cannot be deleted', () async {
      final available = (await repo.listStatuses()).first;
      expect(
        () => repo.deleteStatus(available.id),
        throwsA(isA<ApiValidationException>()),
      );
    });

    test('deleting a status rehomes its books', () async {
      final signed = await repo.createStatus(name: 'Signed');
      final book = await repo.createBook({'title': 'Dune', 'status_id': signed.id});
      expect(book.status?.name, 'Signed');

      await repo.deleteStatus(signed.id);
      expect((await repo.getBook(book.id)).status?.slug, 'available');
    });

    test('renaming a system status keeps its slug', () async {
      final available = (await repo.listStatuses()).first;
      final renamed = await repo.updateStatus(
        available.id,
        name: 'On the shelf',
        color: available.color ?? '#64748b',
      );
      expect(renamed.name, 'On the shelf');
      expect(renamed.slug, 'available');
      // Which means the lend/return pair still works.
      final book = await repo.createBook({'title': 'Dune'});
      await repo.lendBook(book.id, borrowerName: 'Ana');
      await repo.returnBook(book.id);
      expect((await repo.getBook(book.id)).status?.name, 'On the shelf');
    });
  });

  group('aggregates', () {
    test('stats and the dashboard count what is in the library', () async {
      final dune = await repo.createBook({
        'title': 'Dune',
        'authors': ['Frank Herbert'],
        'publisher': 'Ace',
      });
      await repo.lendBook(dune.id, borrowerName: 'Ana');
      await repo.createBook({'title': 'Ubik'});
      final wishlist = (await repo.listStatuses())
          .firstWhere((s) => s.slug == 'wishlist');
      await repo.createBook({'title': 'Solaris', 'status_id': wishlist.id});

      final stats = await repo.stats();
      expect(stats.total, 3);
      expect(stats.authors, 1);
      expect(stats.publishers, 1);
      expect(stats.loans, 1);
      expect(stats.wishlist, 1);

      final dashboard = await repo.dashboard();
      expect(dashboard.stats.total, 3);
      expect(dashboard.recent, hasLength(3));
      expect(dashboard.activeLoans.single.bookTitle, 'Dune');
      expect(
        dashboard.statusCounts.firstWhere((c) => c.status.slug == 'wishlist').count,
        1,
      );
    });

    test('the dashboard ships at most six recent books', () async {
      for (var index = 0; index < 8; index++) {
        await repo.createBook({'title': 'Book $index'});
      }
      expect((await repo.dashboard()).recent, hasLength(6));
    });
  });

  group('finding by ISBN', () {
    test('the ISBN is normalised on both sides', () async {
      await repo.createBook({'title': 'Dune', 'isbn': '978-0-441-01359-3'});
      expect((await repo.findByIsbn('9780441013593'))?.title, 'Dune');
      expect((await repo.findByIsbn('978 0 441 01359 3'))?.title, 'Dune');
      expect(await repo.findByIsbn(''), isNull);
      expect(await repo.findByIsbn('0000000000'), isNull);
    });
  });
}
