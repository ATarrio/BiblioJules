/// Reading stats, goals, want-list and CSV import on the on-device store.
library;

import 'dart:io';

import 'package:bibliojules_mobile/src/core/api_exception.dart';
import 'package:bibliojules_mobile/src/core/csv_import.dart';
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
    dir = await Directory.systemTemp.createTemp('bibliojules_reading');
    repo = await _open(dir);
  });

  tearDown(() async {
    await repo.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('personal stats mirror the server aggregation', () async {
    await repo.createBook({
      'title': 'Dune',
      'read_status': 'read',
      'page_count': 412,
      'score': 4.5,
    });
    await repo.createBook({
      'title': 'Ubik',
      'read_status': 'read',
      'page_count': 224,
      'score': 5,
    });
    await repo.createBook({
      'title': 'Reading now',
      'read_status': 'currently_reading',
    });
    await repo.createBook({'title': 'Abandoned', 'read_status': 'dnf'});

    final stats = await repo.personalStats();
    expect(stats.booksRead, 2);
    expect(stats.pagesRead, 636);
    expect(stats.avgRating, 4.8);
    expect(stats.currentlyReading, 1);
    expect(stats.breakdown('dnf'), 1);
    expect(stats.totalBooks, 4);
  });

  test('goals survive closing and reopening the library', () async {
    await repo.saveReadingGoals(
      const ReadingGoals(year: 2026, targetBooks: 12, targetPages: 3000),
    );
    expect((await repo.readingGoals()).targetBooks, 12);

    await repo.close();
    repo = await _open(dir);
    final goals = await repo.readingGoals();
    expect(goals.year, 2026);
    expect(goals.targetBooks, 12);
    expect(goals.targetPages, 3000);
  });

  test('the want list deduplicates, removes and persists entries', () async {
    await repo.addWant(const WantEntry(id: 'a', title: 'Ubik'));
    await repo.addWant(const WantEntry(id: 'b', title: 'ubik'));
    await repo.addWant(
      const WantEntry(id: 'c', title: 'Dune', isbn: '9780441013593'),
    );
    await repo.addWant(
      const WantEntry(id: 'd', title: 'Dune again', isbn: '9780441013593'),
    );

    var entries = await repo.wantList();
    // The newer entry replaces the older duplicate, as on the server.
    expect(entries.map((entry) => entry.id), ['b', 'd']);

    await repo.removeWant('b');
    entries = await repo.wantList();
    expect(entries.single.title, 'Dune again');

    await repo.close();
    repo = await _open(dir);
    expect((await repo.wantList()).single.id, 'd');
  });

  test('a locally uploaded cover is saved, shown and replaced', () async {
    final book = await repo.createBook({'title': 'With cover'});
    final png = <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      ...List.filled(32, 1),
    ];
    final updated = await repo.uploadCover(
      book.id,
      filename: 'cover.png',
      bytes: png,
    );
    expect(updated.coverUrl, startsWith('file://'));
    final first = File.fromUri(Uri.parse(updated.coverUrl!));
    expect(await first.exists(), isTrue);

    final second = await repo.uploadCover(
      book.id,
      filename: 'cover.png',
      bytes: png,
    );
    final secondFile = File.fromUri(Uri.parse(second.coverUrl!));
    expect(await secondFile.exists(), isTrue);
    expect(second.coverUrl, isNot(updated.coverUrl));
    expect(await first.exists(), isFalse, reason: 'old cover was not removed');

    await expectLater(
      repo.uploadCover(book.id, filename: 'x.svg', bytes: '<svg>'.codeUnits),
      throwsA(isA<ApiValidationException>()),
    );
  });

  test('the CSV parser normalises Goodreads-style headers', () {
    final rows = parseImportCsv(
      'Title,Author,ISBN,Exclusive Shelf,My Rating,Number of Pages,'
      'Publication Year,Publisher\n'
      '"Dune, Book One",Frank Herbert,978-0-441-01359-3,read,5,412,1965,Ace\n'
      'Wanted Book,Someone,,,,,,\n',
    );
    expect(rows, hasLength(2));
    expect(rows.first.title, 'Dune, Book One');
    expect(rows.first.authors, 'Frank Herbert');
    expect(rows.first.isbn, '9780441013593');
    expect(rows.first.data['read_status'], 'read');
    expect(rows.first.data['score'], 5.0);
    expect(rows.first.data['page_count'], 412);
    expect(rows.first.data['published_year'], '1965');
    expect(rows.last.isbn, isNull);
  });

  test(
    'importing creates books and sends rows without ISBN to the want list',
    () async {
      final rows = parseImportCsv(
        'Title,Author,ISBN,Exclusive Shelf\n'
        'Dune,Frank Herbert,9780441013593,read\n'
        'Wanted,Someone,,\n',
      );
      final outcome = await importRows(repo, rows);
      expect(outcome.imported, 1);
      expect(outcome.addedToWantList, 1);
      expect(outcome.errors, isEmpty);
      expect((await repo.findByIsbn('9780441013593'))?.title, 'Dune');
      expect((await repo.wantList()).single.title, 'Wanted');

      // A second import of the same file changes nothing.
      final again = await importRows(
        repo,
        parseImportCsv(
          'Title,Author,ISBN,Exclusive Shelf\n'
          'Dune,Frank Herbert,9780441013593,read\n'
          'Wanted,Someone,,\n',
        ),
      );
      expect(again.imported, 0);
      expect(again.addedToWantList, 0);
      expect(again.skipped, 2);
    },
  );
}
